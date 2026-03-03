#!/bin/bash
# =============================================================================
# setup-windows-boot.sh – Windows NetBoot mit AD-Auth + iSCSI einrichten
# =============================================================================
# Dieses Script richtet die Windows-NetBoot-Infrastruktur ein:
# - Installiert nginx, samba, tgt, python3-flask, python3-ldap3
# - Laedt wimboot von ipxe.org herunter
# - Erstellt Verzeichnisstruktur (inkl. iSCSI-Image-Verzeichnis)
# - Deployed Configs (nginx, samba, iPXE-Scripts, Auth-Backend)
# - Richtet iSCSI-Target-Daemon (tgt) ein
# - Konfiguriert sudo-Rechte fuer iSCSI-Verwaltung
# - Startet und aktiviert alle Services
#
# Ausfuehren auf: netboot-server (10.10.0.2)
# Als: root
#
# Voraussetzung: setup-netboot-server.sh muss zuerst gelaufen sein!
# =============================================================================

set -euo pipefail

# --- Konfiguration ---
TFTP_ROOT="/srv/netboot/tftp"
WINPE_DIR="${TFTP_ROOT}/winpe"
WIN11_DIR="/srv/netboot/win11"
ISCSI_DIR="/srv/netboot/iscsi"
AUTH_DIR="/opt/netboot-auth"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$(cd "${SCRIPT_DIR}/../configs" && pwd)"
WIMBOOT_URL="https://github.com/ipxe/wimboot/releases/latest/download/wimboot"

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# --- Pruefungen ---
[[ $EUID -ne 0 ]] && err "Dieses Script muss als root ausgefuehrt werden!"

if [[ ! -d "${TFTP_ROOT}" ]]; then
    err "TFTP-Root nicht gefunden unter ${TFTP_ROOT}! Zuerst setup-netboot-server.sh ausfuehren!"
fi

if [[ ! -d "${CONFIG_DIR}" ]]; then
    err "Config-Verzeichnis nicht gefunden: ${CONFIG_DIR}"
fi

echo ""
echo "============================================================================="
echo -e "${GREEN} NABE – Windows NetBoot + iSCSI Setup${NC}"
echo "============================================================================="
echo ""

# =============================================================================
# Schritt 1: Pakete installieren
# =============================================================================
log "Schritt 1: Benoetigte Pakete installieren"

apt-get update
apt-get install -y \
    nginx \
    samba \
    tgt \
    python3-flask \
    python3-ldap3

log "Pakete installiert"

# =============================================================================
# Schritt 2: Verzeichnisstruktur erstellen
# =============================================================================
log "Schritt 2: Verzeichnisstruktur erstellen"

mkdir -p "${WINPE_DIR}"
mkdir -p "${WIN11_DIR}"
mkdir -p "${ISCSI_DIR}"
mkdir -p "${AUTH_DIR}"
mkdir -p /etc/tgt/conf.d

log "Verzeichnisse erstellt:"
echo "  ├── ${WINPE_DIR}    (WinPE Boot-Files)"
echo "  ├── ${WIN11_DIR}       (Win11 Installationsdateien)"
echo "  ├── ${ISCSI_DIR}      (iSCSI Disk-Images, per User)"
echo "  └── ${AUTH_DIR}    (Auth-Backend)"

# =============================================================================
# Schritt 3: wimboot herunterladen
# =============================================================================
log "Schritt 3: wimboot herunterladen"

if [[ -f "${WINPE_DIR}/wimboot" ]]; then
    warn "wimboot bereits vorhanden, ueberspringe Download"
else
    if command -v curl &>/dev/null; then
        curl -L -o "${WINPE_DIR}/wimboot" "${WIMBOOT_URL}" || err "wimboot Download fehlgeschlagen!"
    elif command -v wget &>/dev/null; then
        wget -O "${WINPE_DIR}/wimboot" "${WIMBOOT_URL}" || err "wimboot Download fehlgeschlagen!"
    else
        err "Weder curl noch wget verfuegbar!"
    fi
    log "wimboot heruntergeladen"
fi

# =============================================================================
# Schritt 4: Auth-Backend deployen
# =============================================================================
log "Schritt 4: Auth-Backend deployen"

cp "${SCRIPT_DIR}/auth-backend/app.py" "${AUTH_DIR}/app.py"
cp "${SCRIPT_DIR}/auth-backend/requirements.txt" "${AUTH_DIR}/requirements.txt"
cp "${SCRIPT_DIR}/auth-backend/iscsi-manage.sh" "${AUTH_DIR}/iscsi-manage.sh"
chmod +x "${AUTH_DIR}/iscsi-manage.sh"

# Systemd-Service installieren
cp "${SCRIPT_DIR}/auth-backend/netboot-auth.service" /etc/systemd/system/netboot-auth.service
systemctl daemon-reload

log "Auth-Backend deployed nach ${AUTH_DIR}"

# =============================================================================
# Schritt 5: sudo-Rechte fuer iSCSI-Verwaltung
# =============================================================================
log "Schritt 5: sudo-Rechte fuer iSCSI-Verwaltung konfigurieren"

cat > /etc/sudoers.d/netboot-iscsi <<EOF
# NetBoot Auth-Backend darf iSCSI-Targets verwalten
www-data ALL=(root) NOPASSWD: ${AUTH_DIR}/iscsi-manage.sh
EOF
chmod 440 /etc/sudoers.d/netboot-iscsi

log "sudoers-Regel erstellt: www-data darf iscsi-manage.sh als root ausfuehren"

# =============================================================================
# Schritt 6: iSCSI-Target-Daemon (tgt) konfigurieren
# =============================================================================
log "Schritt 6: iSCSI-Target-Daemon konfigurieren"

# Sicherstellen dass tgt conf.d eingebunden ist
if ! grep -q "include /etc/tgt/conf.d" /etc/tgt/targets.conf 2>/dev/null; then
    echo "include /etc/tgt/conf.d/*.conf" >> /etc/tgt/targets.conf
    log "conf.d Include zu targets.conf hinzugefuegt"
fi

systemctl enable tgt
systemctl restart tgt
log "tgt (iSCSI Target) gestartet"

# =============================================================================
# Schritt 7: nginx konfigurieren
# =============================================================================
log "Schritt 7: nginx konfigurieren"

rm -f /etc/nginx/sites-enabled/default
cp "${CONFIG_DIR}/nginx/netboot.conf" /etc/nginx/sites-available/netboot
ln -sf /etc/nginx/sites-available/netboot /etc/nginx/sites-enabled/netboot

nginx -t 2>&1 && log "nginx Config-Test: OK" || err "nginx Config-Test fehlgeschlagen!"

# =============================================================================
# Schritt 8: Samba konfigurieren
# =============================================================================
log "Schritt 8: Samba konfigurieren"

if [[ -f /etc/samba/smb.conf ]] && [[ ! -f /etc/samba/smb.conf.bak ]]; then
    cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
    log "Original smb.conf gesichert als smb.conf.bak"
fi
cp "${CONFIG_DIR}/samba/smb.conf" /etc/samba/smb.conf

testparm -s 2>&1 | tail -1 && log "Samba Config-Test: OK" || warn "Samba Config-Test Warnung"

# =============================================================================
# Schritt 9: iPXE-Scripts deployen
# =============================================================================
log "Schritt 9: iPXE-Scripts deployen"

cp "${CONFIG_DIR}/ipxe/boot.ipxe" "${TFTP_ROOT}/boot.ipxe"
cp "${CONFIG_DIR}/ipxe/win-install.ipxe" "${TFTP_ROOT}/win-install.ipxe"

log "iPXE-Scripts deployed (Admin-Scripts werden dynamisch vom Backend generiert)"

# =============================================================================
# Schritt 9b: Autounattend + Domain-Join deployen
# =============================================================================
log "Schritt 9b: Autounattend + Domain-Join Script deployen"

# autounattend.xml in den Samba-Share (wird von setup.exe automatisch erkannt)
cp "${CONFIG_DIR}/autounattend/autounattend.xml" "${WIN11_DIR}/autounattend.xml"

# domain-join.ps1 via $OEM$-Distribution (wird automatisch nach C:\NABE\ kopiert)
mkdir -p "${WIN11_DIR}/\$OEM\$/\$1/NABE"
cp "${CONFIG_DIR}/autounattend/domain-join.ps1" "${WIN11_DIR}/\$OEM\$/\$1/NABE/domain-join.ps1"

log "autounattend.xml + domain-join.ps1 deployed"
log "  → ${WIN11_DIR}/autounattend.xml"
log "  → ${WIN11_DIR}/\$OEM\$/\$1/NABE/domain-join.ps1 → C:\\NABE\\domain-join.ps1"

# =============================================================================
# Schritt 10: dnsmasq-Config aktualisieren (DNS auf AD-Server)
# =============================================================================
log "Schritt 10: dnsmasq-Config aktualisieren"

cp "${CONFIG_DIR}/dnsmasq/dnsmasq.conf" /etc/dnsmasq.conf
dnsmasq --test 2>&1 && log "dnsmasq Config-Test: OK" || err "dnsmasq Config-Test fehlgeschlagen!"

# =============================================================================
# Schritt 11: Berechtigungen setzen
# =============================================================================
log "Schritt 11: Berechtigungen setzen"

# TFTP-Root (inkl. WinPE-Dateien)
chmod -R 755 "${TFTP_ROOT}"
chown -R dnsmasq:nogroup "${TFTP_ROOT}"

# Win11-Share
chown -R nobody:nogroup "${WIN11_DIR}"
chmod -R 755 "${WIN11_DIR}"

# iSCSI-Verzeichnis (root, da tgt als root laeuft)
chown root:root "${ISCSI_DIR}"
chmod 755 "${ISCSI_DIR}"

# Auth-Backend
chown -R www-data:www-data "${AUTH_DIR}"
chmod 644 "${AUTH_DIR}/app.py"
chmod 755 "${AUTH_DIR}/iscsi-manage.sh"

log "Berechtigungen gesetzt"

# =============================================================================
# Schritt 12: Services starten
# =============================================================================
log "Schritt 12: Services starten"

systemctl enable netboot-auth
systemctl restart netboot-auth
log "netboot-auth gestartet"

systemctl enable nginx
systemctl restart nginx
log "nginx gestartet"

systemctl enable smbd
systemctl restart smbd
log "smbd gestartet"

systemctl restart dnsmasq
log "dnsmasq neu gestartet"

# tgt wurde bereits in Schritt 6 gestartet

# =============================================================================
# Schritt 13: Firewall-Hinweise
# =============================================================================
log "Schritt 13: Pruefe Firewall..."

if command -v nft &>/dev/null && nft list ruleset 2>/dev/null | grep -q "table"; then
    warn "nftables ist aktiv – zusaetzliche Ports benoetigt:"
    echo "  - TCP 80     (HTTP/nginx)"
    echo "  - TCP 445    (SMB/Samba)"
    echo "  - TCP 139    (NetBIOS/Samba)"
    echo "  - TCP 3260   (iSCSI)"
elif command -v iptables &>/dev/null && iptables -L 2>/dev/null | grep -q "DROP\|REJECT"; then
    warn "iptables hat Regeln – stelle sicher, dass HTTP + SMB + iSCSI Ports offen sind!"
else
    log "Keine aktive Firewall erkannt (gut fuer Lab)"
fi

# =============================================================================
# Verifizierung
# =============================================================================
echo ""
echo "============================================================================="
echo -e "${GREEN} Windows NetBoot + iSCSI Setup abgeschlossen!${NC}"
echo "============================================================================="
echo ""
echo "  Services:"
echo "  ├── netboot-auth (Flask): $(systemctl is-active netboot-auth 2>/dev/null || echo 'unbekannt')"
echo "  ├── nginx:                $(systemctl is-active nginx 2>/dev/null || echo 'unbekannt')"
echo "  ├── smbd (Samba):         $(systemctl is-active smbd 2>/dev/null || echo 'unbekannt')"
echo "  ├── tgt (iSCSI):          $(systemctl is-active tgt 2>/dev/null || echo 'unbekannt')"
echo "  ├── dnsmasq (DHCP+TFTP):  $(systemctl is-active dnsmasq 2>/dev/null || echo 'unbekannt')"
echo "  └── NFS-Server:           $(systemctl is-active nfs-kernel-server 2>/dev/null || echo 'unbekannt')"
echo ""
echo "  Verzeichnisse:"
echo "  ├── ${WINPE_DIR}/"
echo "  │   └── wimboot $(test -f ${WINPE_DIR}/wimboot && echo '✓' || echo '✗ FEHLT')"
echo "  ├── WinPE-Files (manuell hochladen!):"
echo "  │   ├── bcd              $(test -f ${WINPE_DIR}/bcd && echo '✓' || echo '✗ fehlt noch')"
echo "  │   ├── boot.sdi         $(test -f ${WINPE_DIR}/boot.sdi && echo '✓' || echo '✗ fehlt noch')"
echo "  │   └── install-boot.wim $(test -f ${WINPE_DIR}/install-boot.wim && echo '✓' || echo '✗ fehlt noch')"
echo "  ├── ${WIN11_DIR}/ $(ls ${WIN11_DIR}/ 2>/dev/null | head -1 >/dev/null && echo '(Dateien vorhanden)' || echo '(leer – ISO-Inhalt hierhin kopieren)')"
echo "  └── ${ISCSI_DIR}/ (Admin-Disk-Images, werden automatisch erstellt)"
echo ""
echo "  Architektur:"
echo "  ├── Install-Pfad: WinPE → Win11-Setup auf lokale Platte (via Samba + autounattend)"
echo "  └── Admin-Pfad:   iSCSI-Disk pro Admin (60 GB sparse)"
echo "                    Kein Image → WinPE installiert auf iSCSI-Disk"
echo "                    Image da  → Direkter iSCSI-Boot (sanboot)"
echo ""
echo "============================================================================="
echo "  NAECHSTE SCHRITTE:"
echo "  1. Windows Server VM (10.10.0.3) mit AD DS aufsetzen"
echo "     → siehe docs/phase-3-windows-netboot.md"
echo "  2. WinPE-Image auf Windows-Rechner bauen (nur install-boot.wim noetig!)"
echo "     → siehe docs/winpe-build-anleitung.md"
echo "  3. WinPE-Files hochladen nach ${WINPE_DIR}/"
echo "  4. Win11 ISO-Inhalt kopieren nach ${WIN11_DIR}/"
echo "  5. Test: curl -u user:pass http://localhost:5000/boot/auth/validate"
echo ""
echo "  Debugging:"
echo "    journalctl -fu netboot-auth     # Auth-Backend Logs"
echo "    journalctl -fu nginx            # nginx Logs"
echo "    journalctl -fu tgt              # iSCSI-Target Logs"
echo "    journalctl -fu smbd             # Samba Logs"
echo "    journalctl -fu dnsmasq          # DHCP/TFTP Logs"
echo "    tgtadm --lld iscsi --op show --mode target  # iSCSI-Targets anzeigen"
echo "============================================================================="
