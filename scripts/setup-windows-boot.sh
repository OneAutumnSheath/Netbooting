#!/bin/bash
# =============================================================================
# setup-windows-boot.sh – Support-Tools Server einrichten
# =============================================================================
# Richtet die komplette Boot-Infrastruktur ein:
#   - Kerberos (krb5-user) fuer AD-Authentifizierung
#   - PHP-FPM + Composer + Laravel (Dashboard + Auth + Session-API)
#   - nginx (Laravel + statische Boot-Files)
#   - Samba (Win11 Setup-Share)
#   - tgt (iSCSI-Targets)
#   - iPXE-Scripts
#   - Kiosk-Linux Deployment
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
HBCD_DIR="${TFTP_ROOT}/hbcd"
WIN11_DIR="/srv/netboot/win11"
ISCSI_DIR="/srv/netboot/iscsi"
KIOSK_DIR="/srv/netboot/kiosk-linux"
WEB_DIR="/opt/nabe-web"
AUTH_DIR="/opt/netboot-auth"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$(cd "${SCRIPT_DIR}/../configs" && pwd)"
WEB_SRC="$(cd "${SCRIPT_DIR}/../web" && pwd)"
WIMBOOT_URL="https://github.com/ipxe/wimboot/releases/latest/download/wimboot"

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

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
echo -e "${GREEN} Support-Tools – Server Setup${NC}"
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
    php-fpm \
    php-cli \
    php-sqlite3 \
    php-xml \
    php-mbstring \
    php-curl \
    krb5-user \
    ldap-utils \
    libsasl2-modules-gssapi-mit \
    unzip \
    curl

log "Pakete installiert (PHP, Kerberos, nginx, Samba, tgt)"

# =============================================================================
# Schritt 2: Composer installieren (falls nicht vorhanden)
# =============================================================================
log "Schritt 2: Composer installieren"

if ! command -v composer &>/dev/null; then
    EXPECTED_CHECKSUM="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");')"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

    if [[ "${EXPECTED_CHECKSUM}" != "${ACTUAL_CHECKSUM}" ]]; then
        rm composer-setup.php
        err "Composer Installer Checksum ungueltig!"
    fi

    php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm composer-setup.php
    log "Composer installiert"
else
    warn "Composer bereits vorhanden"
fi

# =============================================================================
# Schritt 3: Verzeichnisstruktur erstellen
# =============================================================================
log "Schritt 3: Verzeichnisstruktur erstellen"

mkdir -p "${WINPE_DIR}"
mkdir -p "${HBCD_DIR}"
mkdir -p "${WIN11_DIR}"
mkdir -p "${ISCSI_DIR}"
mkdir -p "${KIOSK_DIR}"
mkdir -p "${AUTH_DIR}"
mkdir -p "${WEB_DIR}"
mkdir -p /etc/tgt/conf.d

log "Verzeichnisse erstellt:"
echo "  ├── ${WINPE_DIR}    (WinPE Boot-Files)"
echo "  ├── ${HBCD_DIR}     (HBCD Boot-Files)"
echo "  ├── ${WIN11_DIR}       (Win11 Installationsdateien)"
echo "  ├── ${ISCSI_DIR}      (iSCSI Disk-Images, per User)"
echo "  ├── ${KIOSK_DIR} (Kiosk-Linux Kernel + Initramfs)"
echo "  ├── ${WEB_DIR}       (Laravel Web-App)"
echo "  └── ${AUTH_DIR}    (iSCSI-Verwaltung)"

# =============================================================================
# Schritt 4: Kerberos konfigurieren
# =============================================================================
log "Schritt 4: Kerberos konfigurieren"

cp "${CONFIG_DIR}/krb5/krb5.conf" /etc/krb5.conf

log "krb5.conf deployed – Realm: LAB.LOCAL, KDC: 10.10.0.3"

# =============================================================================
# Schritt 5: wimboot herunterladen
# =============================================================================
log "Schritt 5: wimboot herunterladen"

if [[ -f "${WINPE_DIR}/wimboot" ]]; then
    warn "wimboot bereits vorhanden, ueberspringe Download"
else
    curl -L -o "${WINPE_DIR}/wimboot" "${WIMBOOT_URL}" || err "wimboot Download fehlgeschlagen!"
    log "wimboot heruntergeladen"
fi

# Auch fuer HBCD kopieren
if [[ ! -f "${HBCD_DIR}/wimboot" ]]; then
    cp "${WINPE_DIR}/wimboot" "${HBCD_DIR}/wimboot"
    log "wimboot nach HBCD-Verzeichnis kopiert"
fi

# =============================================================================
# Schritt 6: Laravel Web-App deployen
# =============================================================================
log "Schritt 6: Laravel Web-App deployen"

# Web-Dateien kopieren
cp -r "${WEB_SRC}/." "${WEB_DIR}/"

# .env erstellen falls nicht vorhanden
if [[ ! -f "${WEB_DIR}/.env" ]]; then
    cp "${WEB_DIR}/.env.example" "${WEB_DIR}/.env"
    log ".env aus .env.example erstellt"
fi

# Composer Dependencies installieren
cd "${WEB_DIR}"
composer install --no-dev --optimize-autoloader --no-interaction 2>&1 | tail -5

# App-Key generieren falls noetig
if ! grep -q "^APP_KEY=base64:" "${WEB_DIR}/.env" 2>/dev/null; then
    php artisan key:generate --force
    log "APP_KEY generiert"
fi

# SQLite-Datenbank erstellen und migrieren
DB_PATH="${WEB_DIR}/database/nabe.sqlite"
if [[ ! -f "${DB_PATH}" ]]; then
    touch "${DB_PATH}"
fi
php artisan migrate --force
log "SQLite-Datenbank migriert"

cd - >/dev/null

log "Laravel Web-App deployed nach ${WEB_DIR}"

# =============================================================================
# Schritt 7: iSCSI-Verwaltung deployen
# =============================================================================
log "Schritt 7: iSCSI-Verwaltung deployen"

cp "${SCRIPT_DIR}/auth-backend/iscsi-manage.sh" "${AUTH_DIR}/iscsi-manage.sh"
chmod +x "${AUTH_DIR}/iscsi-manage.sh"

log "iscsi-manage.sh deployed nach ${AUTH_DIR}"

# =============================================================================
# Schritt 8: sudo-Rechte fuer iSCSI-Verwaltung
# =============================================================================
log "Schritt 8: sudo-Rechte fuer iSCSI-Verwaltung konfigurieren"

cat > /etc/sudoers.d/netboot-iscsi <<EOF
# Support-Tools: www-data darf iSCSI-Targets verwalten
www-data ALL=(root) NOPASSWD: ${AUTH_DIR}/iscsi-manage.sh
EOF
chmod 440 /etc/sudoers.d/netboot-iscsi

log "sudoers-Regel erstellt"

# =============================================================================
# Schritt 9: iSCSI-Target-Daemon (tgt) konfigurieren
# =============================================================================
log "Schritt 9: iSCSI-Target-Daemon konfigurieren"

if ! grep -q "include /etc/tgt/conf.d" /etc/tgt/targets.conf 2>/dev/null; then
    echo "include /etc/tgt/conf.d/*.conf" >> /etc/tgt/targets.conf
    log "conf.d Include zu targets.conf hinzugefuegt"
fi

systemctl enable tgt
systemctl restart tgt
log "tgt (iSCSI Target) gestartet"

# =============================================================================
# Schritt 10: nginx konfigurieren
# =============================================================================
log "Schritt 10: nginx konfigurieren"

rm -f /etc/nginx/sites-enabled/default
cp "${CONFIG_DIR}/nginx/netboot.conf" /etc/nginx/sites-available/netboot
ln -sf /etc/nginx/sites-available/netboot /etc/nginx/sites-enabled/netboot

nginx -t 2>&1 && log "nginx Config-Test: OK" || err "nginx Config-Test fehlgeschlagen!"

# =============================================================================
# Schritt 11: Samba konfigurieren
# =============================================================================
log "Schritt 11: Samba konfigurieren"

if [[ -f /etc/samba/smb.conf ]] && [[ ! -f /etc/samba/smb.conf.bak ]]; then
    cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
    log "Original smb.conf gesichert als smb.conf.bak"
fi
cp "${CONFIG_DIR}/samba/smb.conf" /etc/samba/smb.conf

testparm -s 2>&1 | tail -1 && log "Samba Config-Test: OK" || warn "Samba Config-Test Warnung"

# =============================================================================
# Schritt 12: iPXE-Scripts deployen
# =============================================================================
log "Schritt 12: iPXE-Scripts deployen"

cp "${CONFIG_DIR}/ipxe/boot.ipxe" "${TFTP_ROOT}/boot.ipxe"
cp "${CONFIG_DIR}/ipxe/win-install.ipxe" "${TFTP_ROOT}/win-install.ipxe"

log "iPXE-Scripts deployed"

# =============================================================================
# Schritt 13: Autounattend + Domain-Join deployen
# =============================================================================
log "Schritt 13: Autounattend + Domain-Join Script deployen"

cp "${CONFIG_DIR}/autounattend/autounattend.xml" "${WIN11_DIR}/autounattend.xml"

mkdir -p "${WIN11_DIR}/\$OEM\$/\$1/NABE"
cp "${CONFIG_DIR}/autounattend/domain-join.ps1" "${WIN11_DIR}/\$OEM\$/\$1/NABE/domain-join.ps1"

log "autounattend.xml + domain-join.ps1 deployed"

# =============================================================================
# Schritt 14: dnsmasq-Config aktualisieren
# =============================================================================
log "Schritt 14: dnsmasq-Config aktualisieren"

cp "${CONFIG_DIR}/dnsmasq/dnsmasq.conf" /etc/dnsmasq.conf
dnsmasq --test 2>&1 && log "dnsmasq Config-Test: OK" || err "dnsmasq Config-Test fehlgeschlagen!"

# =============================================================================
# Schritt 15: Berechtigungen setzen
# =============================================================================
log "Schritt 15: Berechtigungen setzen"

# TFTP-Root (inkl. WinPE + HBCD)
chmod -R 755 "${TFTP_ROOT}"
chown -R dnsmasq:nogroup "${TFTP_ROOT}"

# Win11-Share
chown -R nobody:nogroup "${WIN11_DIR}"
chmod -R 755 "${WIN11_DIR}"

# iSCSI-Verzeichnis
chown root:root "${ISCSI_DIR}"
chmod 755 "${ISCSI_DIR}"

# Kiosk-Linux (lesbar fuer nginx)
chmod -R 755 "${KIOSK_DIR}"

# Laravel Web-App
chown -R www-data:www-data "${WEB_DIR}"
chmod -R 755 "${WEB_DIR}"
chmod -R 775 "${WEB_DIR}/storage"
chmod -R 775 "${WEB_DIR}/bootstrap/cache" 2>/dev/null || true

# iSCSI-Verwaltung
chown -R www-data:www-data "${AUTH_DIR}"
chmod 755 "${AUTH_DIR}/iscsi-manage.sh"

log "Berechtigungen gesetzt"

# =============================================================================
# Schritt 16: Alte Flask-Services deaktivieren (falls vorhanden)
# =============================================================================
if systemctl is-active netboot-auth &>/dev/null; then
    log "Schritt 16: Altes Flask-Backend deaktivieren"
    systemctl stop netboot-auth
    systemctl disable netboot-auth
    log "netboot-auth (Flask) deaktiviert – ersetzt durch Laravel/PHP-FPM"
else
    log "Schritt 16: Kein altes Flask-Backend gefunden (OK)"
fi

# =============================================================================
# Schritt 17: Services starten
# =============================================================================
log "Schritt 17: Services starten"

systemctl enable php*-fpm 2>/dev/null || systemctl enable php-fpm
systemctl restart php*-fpm 2>/dev/null || systemctl restart php-fpm
log "PHP-FPM gestartet"

systemctl enable nginx
systemctl restart nginx
log "nginx gestartet"

systemctl enable smbd
systemctl restart smbd
log "smbd gestartet"

systemctl restart dnsmasq
log "dnsmasq neu gestartet"

# =============================================================================
# Schritt 18: Firewall-Hinweise
# =============================================================================
log "Schritt 18: Pruefe Firewall..."

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
echo -e "${GREEN} Support-Tools Server Setup abgeschlossen!${NC}"
echo "============================================================================="
echo ""
echo "  Services:"
echo "  ├── PHP-FPM:            $(systemctl is-active php*-fpm 2>/dev/null || echo 'unbekannt')"
echo "  ├── nginx:              $(systemctl is-active nginx 2>/dev/null || echo 'unbekannt')"
echo "  ├── smbd (Samba):       $(systemctl is-active smbd 2>/dev/null || echo 'unbekannt')"
echo "  ├── tgt (iSCSI):        $(systemctl is-active tgt 2>/dev/null || echo 'unbekannt')"
echo "  ├── dnsmasq (DHCP+TFTP):$(systemctl is-active dnsmasq 2>/dev/null || echo 'unbekannt')"
echo "  └── NFS-Server:         $(systemctl is-active nfs-kernel-server 2>/dev/null || echo 'unbekannt')"
echo ""
echo "  Architektur (NEU):"
echo "  ├── PXE → iPXE → Session-Check → Kiosk-Linux (Dashboard)"
echo "  ├── Dashboard: http://10.10.0.2/dashboard"
echo "  ├── Auth: Kerberos (kinit + ldapsearch -Y GSSAPI)"
echo "  └── Boot: Session-basiert (SQLite, 5 Min Timeout)"
echo ""
echo "  Boot-Optionen:"
echo "  ├── HBCD:     Hiren's Boot CD PE (WinPE)"
echo "  ├── Win11:    Neuinstallation (WinPE → Samba-Share)"
echo "  ├── Admin:    iSCSI-Boot (persoenliche Netzwerk-Disk)"
echo "  └── Lokal:    Von lokaler Festplatte"
echo ""
echo "  Verzeichnisse:"
echo "  ├── ${WEB_DIR}/             (Laravel Dashboard)"
echo "  ├── ${WINPE_DIR}/ (WinPE Boot-Files)"
echo "  │   └── wimboot $(test -f ${WINPE_DIR}/wimboot && echo 'vorhanden' || echo 'FEHLT')"
echo "  ├── ${HBCD_DIR}/  (HBCD Boot-Files)"
echo "  │   └── wimboot $(test -f ${HBCD_DIR}/wimboot && echo 'vorhanden' || echo 'FEHLT')"
echo "  ├── ${KIOSK_DIR}/"
echo "  │   ├── vmlinuz     $(test -f ${KIOSK_DIR}/vmlinuz && echo 'vorhanden' || echo 'FEHLT – build-kiosk-linux.sh ausfuehren!')"
echo "  │   └── initramfs.img $(test -f ${KIOSK_DIR}/initramfs.img && echo 'vorhanden' || echo 'FEHLT – build-kiosk-linux.sh ausfuehren!')"
echo "  └── ${ISCSI_DIR}/    (Admin-Disk-Images)"
echo ""
echo "============================================================================="
echo "  NAECHSTE SCHRITTE:"
echo "  1. Kerberos testen: kinit Administrator@LAB.LOCAL"
echo "  2. LDAP testen: ldapsearch -Y GSSAPI -Q -H ldap://10.10.0.3 -b DC=lab,DC=local"
echo "  3. Kiosk-Linux bauen: bash scripts/build-kiosk-linux.sh"
echo "  4. WinPE-Files hochladen nach ${WINPE_DIR}/"
echo "  5. HBCD-Files hochladen nach ${HBCD_DIR}/"
echo "  6. Win11 ISO-Inhalt kopieren nach ${WIN11_DIR}/"
echo "  7. Dashboard testen: curl http://localhost/dashboard?mac=00:00:00:00:00:00"
echo "  8. PXE-Boot testen"
echo ""
echo "  Debugging:"
echo "    journalctl -fu nginx            # nginx Logs"
echo "    journalctl -fu php*-fpm         # PHP-FPM Logs"
echo "    tail -f ${WEB_DIR}/storage/logs/laravel.log  # Laravel Logs"
echo "    journalctl -fu tgt              # iSCSI-Target Logs"
echo "    journalctl -fu smbd             # Samba Logs"
echo "    journalctl -fu dnsmasq          # DHCP/TFTP Logs"
echo "============================================================================="
