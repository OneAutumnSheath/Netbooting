#!/usr/bin/env python3
"""
NetBoot Auth-Backend – Flask-App fuer AD-Authentifizierung + iSCSI-Management.

Flow:
  1. iPXE sendet HTTP Basic-Auth an /boot/auth/validate
  2. Backend prueft Credentials gegen AD (LDAP)
  3. Backend prueft Gruppenzugehoerigkeit:
     - NetBoot-Install → iPXE-Script fuer Win11-Installation (lokale Platte)
     - NetBoot-Admin   → iPXE-Script fuer iSCSI-Boot (Netzwerk-Disk)
       - Image vorhanden → sanboot direkt von iSCSI
       - Kein Image      → Image erstellen, sanhook + WinPE-Install auf iSCSI
     - Beide Gruppen   → Inline-Menue mit beiden Optionen

iSCSI-Targets werden per-User verwaltet:
  - Disk-Image: /srv/netboot/iscsi/{username}.img (sparse, 60 GB)
  - iSCSI-Target: iqn.2024-01.local.lab.netboot:{username}
  - Verwaltung via iscsi-manage.sh (laeuft als root via sudo)

Konfiguration via Umgebungsvariablen:
    AD_SERVER       - LDAP-Server IP (default: 10.10.0.3)
    AD_DOMAIN       - AD-Domain (default: lab.local)
    AD_BASE_DN      - LDAP Base-DN (default: DC=lab,DC=local)
    GROUP_INSTALL   - AD-Gruppe fuer Installation (default: NetBoot-Install)
    GROUP_ADMIN     - AD-Gruppe fuer Admin-Umgebung (default: NetBoot-Admin)
    NETBOOT_SERVER  - IP des NetBoot-Servers (default: 10.10.0.2)
    ISCSI_IQN_PREFIX - iSCSI IQN Prefix (default: iqn.2024-01.local.lab.netboot)
"""

import os
import subprocess
from flask import Flask, request, Response
from ldap3 import Server, Connection, ALL, SUBTREE

app = Flask(__name__)

# --- Konfiguration ---
AD_SERVER = os.environ.get("AD_SERVER", "10.10.0.3")
AD_DOMAIN = os.environ.get("AD_DOMAIN", "lab.local")
AD_BASE_DN = os.environ.get("AD_BASE_DN", "DC=lab,DC=local")
GROUP_INSTALL = os.environ.get("GROUP_INSTALL", "NetBoot-Install")
GROUP_ADMIN = os.environ.get("GROUP_ADMIN", "NetBoot-Admin")
NETBOOT_SERVER = os.environ.get("NETBOOT_SERVER", "10.10.0.2")
ISCSI_IQN_PREFIX = os.environ.get("ISCSI_IQN_PREFIX",
                                   "iqn.2024-01.local.lab.netboot")
ISCSI_MANAGE = os.environ.get("ISCSI_MANAGE",
                               "/opt/netboot-auth/iscsi-manage.sh")


# =============================================================================
# LDAP-Authentifizierung
# =============================================================================

def ldap_authenticate(username, password):
    """Authentifiziert Benutzer gegen AD und gibt Gruppenliste zurueck."""
    user_dn = f"{username}@{AD_DOMAIN}"
    server = Server(AD_SERVER, get_info=ALL, connect_timeout=5)

    try:
        conn = Connection(server, user=user_dn, password=password,
                          auto_bind=True, read_only=True,
                          receive_timeout=10)
    except Exception as e:
        app.logger.warning("LDAP-Bind fehlgeschlagen fuer %s: %s", username, e)
        return None

    conn.search(
        search_base=AD_BASE_DN,
        search_filter=f"(sAMAccountName={username})",
        search_scope=SUBTREE,
        attributes=["memberOf"]
    )

    if not conn.entries:
        conn.unbind()
        return []

    groups = []
    member_of = (conn.entries[0].memberOf.values
                 if conn.entries[0].memberOf else [])
    for dn in member_of:
        for part in dn.split(","):
            if part.strip().upper().startswith("CN="):
                groups.append(part.strip()[3:])
                break

    conn.unbind()
    return groups


# =============================================================================
# iSCSI-Verwaltung
# =============================================================================

def iscsi_image_exists(username):
    """Prueft ob ein iSCSI-Disk-Image fuer den Benutzer existiert."""
    result = subprocess.run(
        ["sudo", ISCSI_MANAGE, "exists", username],
        capture_output=True, text=True, timeout=10
    )
    return result.stdout.strip() == "true"


def iscsi_create_target(username):
    """Erstellt ein neues iSCSI-Target fuer den Benutzer."""
    result = subprocess.run(
        ["sudo", ISCSI_MANAGE, "create", username],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode != 0:
        app.logger.error("iSCSI-Target Erstellung fehlgeschlagen fuer %s: %s",
                         username, result.stderr)
        return False
    app.logger.info("iSCSI-Target erstellt fuer %s", username)
    return True


# =============================================================================
# iPXE-Script Generierung
# =============================================================================

def ipxe_response(script_content, status=200):
    """Gibt eine iPXE-Script-Antwort zurueck."""
    return Response(script_content, status=status,
                    mimetype="text/plain",
                    headers={"Content-Type": "text/plain; charset=utf-8"})


def ipxe_error(message):
    """Gibt ein iPXE-Fehler-Script zurueck."""
    return ipxe_response(
        f"#!ipxe\necho FEHLER: {message}\n"
        "echo Druecke eine Taste...\nprompt\n", 403
    )


def ipxe_install_script():
    """iPXE-Script fuer Windows-Installation auf lokale Platte."""
    return f"#!ipxe\nchain tftp://{NETBOOT_SERVER}/win-install.ipxe\n"


def ipxe_admin_boot_script(username):
    """iPXE-Script fuer iSCSI-Boot (Image existiert bereits)."""
    target_iqn = f"{ISCSI_IQN_PREFIX}:{username}"
    return (
        f"#!ipxe\n"
        f"echo\n"
        f"echo Starte Admin-Umgebung fuer {username}...\n"
        f"echo Verbinde mit iSCSI-Target...\n"
        f"set initiator-iqn iqn.2024-01.local.lab:{username}\n"
        f"sanboot iscsi:{NETBOOT_SERVER}::::{target_iqn} || goto fail\n"
        f"\n"
        f":fail\n"
        f"echo FEHLER: iSCSI-Boot fehlgeschlagen!\n"
        f"echo Druecke eine Taste...\n"
        f"prompt\n"
    )


def ipxe_admin_install_script(username):
    """iPXE-Script fuer Erstinstallation auf iSCSI-Disk."""
    target_iqn = f"{ISCSI_IQN_PREFIX}:{username}"
    return (
        f"#!ipxe\n"
        f"echo\n"
        f"echo ============================================\n"
        f"echo   Neue Admin-Umgebung fuer {username}\n"
        f"echo ============================================\n"
        f"echo\n"
        f"echo Verbinde iSCSI-Disk (Netzwerk-Festplatte)...\n"
        f"set initiator-iqn iqn.2024-01.local.lab:{username}\n"
        f"sanhook iscsi:{NETBOOT_SERVER}::::{target_iqn} || goto fail\n"
        f"echo iSCSI-Disk verbunden.\n"
        f"echo\n"
        f"echo Lade WinPE fuer Windows-Installation...\n"
        f"echo Die iSCSI-Disk erscheint als lokale Festplatte.\n"
        f"echo Bitte Windows darauf installieren!\n"
        f"echo\n"
        f"kernel http://{NETBOOT_SERVER}/boot/wimboot || goto fail\n"
        f"initrd --name bcd http://{NETBOOT_SERVER}/boot/bcd"
        f" bcd || goto fail\n"
        f"initrd --name boot.sdi http://{NETBOOT_SERVER}/boot/boot.sdi"
        f" boot.sdi || goto fail\n"
        f"initrd --name boot.wim http://{NETBOOT_SERVER}/boot/install-boot.wim"
        f" boot.wim || goto fail\n"
        f"boot || goto fail\n"
        f"\n"
        f":fail\n"
        f"echo FEHLER: Admin-Umgebung konnte nicht gestartet werden!\n"
        f"echo Druecke eine Taste...\n"
        f"prompt\n"
    )


def ipxe_menu_script(username, has_image):
    """iPXE-Menue fuer Benutzer mit Install + Admin Rechten."""
    admin_label = ("Admin-Umgebung starten (iSCSI)" if has_image
                   else "Admin-Umgebung erstellen (Erstinstallation)")
    admin_script = (ipxe_admin_boot_script(username) if has_image
                    else ipxe_admin_install_script(username))

    # Inline-Menue: Install-Option chainloaded, Admin-Option inline
    return (
        f"#!ipxe\n"
        f"menu ========= NABE - Boot-Auswahl ({username}) =========\n"
        f"item --gap --             ----------------------------\n"
        f"item --key 1 install      1. Windows 11 Installation (lokale Platte)\n"
        f"item --key 2 admin        2. {admin_label}\n"
        f"item --gap --             ----------------------------\n"
        f"item --key 0 back         0. Zurueck zum Hauptmenue\n"
        f"choose --timeout 15000 --default admin target "
        f"&& goto ${{target}} || goto back\n"
        f"\n"
        f":install\n"
        f"chain tftp://{NETBOOT_SERVER}/win-install.ipxe\n"
        f"\n"
        f":admin\n"
        # Admin-Script inline (ohne #!ipxe Header)
        + "\n".join(admin_script.split("\n")[1:])
        + f"\n:back\n"
        f"chain tftp://{NETBOOT_SERVER}/boot.ipxe\n"
    )


# =============================================================================
# HTTP-Endpunkte
# =============================================================================

@app.route("/boot/auth/validate")
def validate():
    """Authentifiziert Benutzer und gibt iPXE-Boot-Script zurueck."""
    auth = request.authorization
    if not auth or not auth.username or not auth.password:
        return ipxe_response(
            "#!ipxe\necho FEHLER: Keine Anmeldedaten uebermittelt.\n"
            "echo Druecke eine Taste...\nprompt\n", 401
        )

    username = auth.username
    groups = ldap_authenticate(username, auth.password)

    if groups is None:
        return ipxe_error("Anmeldung fehlgeschlagen. "
                          "Benutzername oder Passwort falsch.")

    is_install = GROUP_INSTALL in groups
    is_admin = GROUP_ADMIN in groups

    if not is_install and not is_admin:
        return ipxe_error(
            f"Benutzer '{username}' ist in keiner NetBoot-Gruppe.")

    # Admin-Pfad: iSCSI-Image pruefen/erstellen
    has_image = False
    if is_admin:
        has_image = iscsi_image_exists(username)
        if not has_image:
            # Neues Image + Target erstellen
            if not iscsi_create_target(username):
                return ipxe_error("iSCSI-Target konnte nicht erstellt werden.")
            app.logger.info("Neues iSCSI-Target fuer %s erstellt", username)

    # iPXE-Script zurueckgeben
    if is_install and is_admin:
        return ipxe_response(ipxe_menu_script(username, has_image))
    elif is_install:
        return ipxe_response(ipxe_install_script())
    else:
        # Nur Admin
        if has_image:
            return ipxe_response(ipxe_admin_boot_script(username))
        else:
            return ipxe_response(ipxe_admin_install_script(username))


@app.route("/health")
def health():
    """Health-Check Endpoint."""
    return {"status": "ok", "ad_server": AD_SERVER, "domain": AD_DOMAIN}


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=True)
