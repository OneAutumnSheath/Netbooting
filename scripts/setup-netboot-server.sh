#!/bin/bash
# =============================================================================
# setup-netboot-server.sh – NetBoot-Server einrichten (DHCP + TFTP + NFS)
# =============================================================================
# Dieses Script richtet den NetBoot-Server ein:
# - Installiert benötigte Pakete
# - Erstellt TFTP-Verzeichnisstruktur
# - Kopiert PXE-Bootloader (pxelinux)
# - Deployed Config-Dateien (dnsmasq, NFS, PXE-Menü)
# - Startet und aktiviert alle Services
#
# Ausführen auf: netboot-server (10.0.0.2)
# Als: root
#
# Voraussetzung: build-rootfs.sh muss zuerst gelaufen sein!
# =============================================================================

set -euo pipefail

# --- Konfiguration ---
TFTP_ROOT="/srv/netboot/tftp"
ROOTFS="/srv/netboot/rootfs"
CONFIG_DIR="$(cd "$(dirname "$0")/../configs" && pwd)"

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# --- Prüfungen ---
[[ $EUID -ne 0 ]] && err "Dieses Script muss als root ausgeführt werden!"

if [[ ! -d "${ROOTFS}/etc" ]]; then
    err "Root-FS nicht gefunden unter ${ROOTFS}! Zuerst build-rootfs.sh ausführen!"
fi

if [[ ! -d "${CONFIG_DIR}" ]]; then
    err "Config-Verzeichnis nicht gefunden: ${CONFIG_DIR}"
fi

# =============================================================================
# Schritt 1: Pakete installieren
# =============================================================================
log "Schritt 1: Benötigte Pakete installieren"

apt-get update
apt-get install -y \
    dnsmasq \
    pxelinux \
    syslinux-common \
    syslinux-efi \
    nfs-kernel-server \
    debootstrap \
    tftpd-hpa

# tftpd-hpa deaktivieren – dnsmasq übernimmt TFTP
systemctl stop tftpd-hpa 2>/dev/null || true
systemctl disable tftpd-hpa 2>/dev/null || true
log "tftpd-hpa deaktiviert (dnsmasq macht TFTP)"

# =============================================================================
# Schritt 2: TFTP-Verzeichnisstruktur erstellen
# =============================================================================
log "Schritt 2: TFTP-Verzeichnisstruktur erstellen"

mkdir -p "${TFTP_ROOT}/pxelinux.cfg"
mkdir -p "${TFTP_ROOT}/debian12"
mkdir -p "${TFTP_ROOT}/bios"

# --- PXE-Bootloader kopieren ---
log "Kopiere pxelinux Bootloader..."

# pxelinux.0 (Legacy BIOS Bootloader)
cp /usr/lib/PXELINUX/pxelinux.0 "${TFTP_ROOT}/"

# ldlinux.c32 (wird von pxelinux.0 benötigt)
cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "${TFTP_ROOT}/"

# Menü-Module
for module in menu.c32 libutil.c32 vesamenu.c32 libcom32.c32; do
    if [[ -f "/usr/lib/syslinux/modules/bios/${module}" ]]; then
        cp "/usr/lib/syslinux/modules/bios/${module}" "${TFTP_ROOT}/bios/"
        # Auch ins Root für einfacheren Zugriff
        cp "/usr/lib/syslinux/modules/bios/${module}" "${TFTP_ROOT}/"
    fi
done

log "PXE-Bootloader kopiert"

# --- Prüfen ob Kernel + Initrd vorhanden ---
if [[ ! -f "${TFTP_ROOT}/debian12/vmlinuz" ]]; then
    warn "vmlinuz nicht gefunden in ${TFTP_ROOT}/debian12/"
    warn "Stelle sicher, dass build-rootfs.sh zuerst gelaufen ist!"
fi

if [[ ! -f "${TFTP_ROOT}/debian12/initrd.img" ]]; then
    warn "initrd.img nicht gefunden in ${TFTP_ROOT}/debian12/"
    warn "Stelle sicher, dass build-rootfs.sh zuerst gelaufen ist!"
fi

# =============================================================================
# Schritt 3: Configs deployen
# =============================================================================
log "Schritt 3: Config-Dateien deployen"

# --- dnsmasq ---
log "Deploye dnsmasq.conf..."
# Originale Config sichern
if [[ -f /etc/dnsmasq.conf ]] && [[ ! -f /etc/dnsmasq.conf.bak ]]; then
    cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak
    log "Original dnsmasq.conf gesichert als dnsmasq.conf.bak"
fi
cp "${CONFIG_DIR}/dnsmasq/dnsmasq.conf" /etc/dnsmasq.conf

# --- NFS Exports ---
log "Deploye NFS exports..."
if [[ -f /etc/exports ]] && [[ ! -f /etc/exports.bak ]]; then
    cp /etc/exports /etc/exports.bak
    log "Original exports gesichert als exports.bak"
fi
cp "${CONFIG_DIR}/nfs/exports" /etc/exports

# --- PXE Boot-Menü ---
log "Deploye PXE Boot-Menü..."
cp "${CONFIG_DIR}/pxelinux/default" "${TFTP_ROOT}/pxelinux.cfg/default"

# =============================================================================
# Schritt 4: Berechtigungen setzen
# =============================================================================
log "Schritt 4: Berechtigungen setzen"

# TFTP-Root muss für dnsmasq (als nobody) lesbar sein
chmod -R 755 "${TFTP_ROOT}"
chown -R root:root "${TFTP_ROOT}"

# NFS Root-FS
chown -R root:root "${ROOTFS}"

# =============================================================================
# Schritt 5: Services starten
# =============================================================================
log "Schritt 5: Services konfigurieren und starten"

# --- dnsmasq ---
systemctl stop dnsmasq 2>/dev/null || true
# Config-Test
dnsmasq --test 2>&1 && log "dnsmasq Config-Test: OK" || err "dnsmasq Config-Test fehlgeschlagen!"
systemctl enable dnsmasq
systemctl start dnsmasq
log "dnsmasq gestartet"

# --- NFS ---
exportfs -ra
systemctl enable nfs-kernel-server
systemctl restart nfs-kernel-server
log "NFS-Server gestartet"

# Export verifizieren
log "Aktive NFS-Exports:"
exportfs -v

# =============================================================================
# Schritt 6: Firewall-Regeln (falls nftables/iptables aktiv)
# =============================================================================
log "Schritt 6: Prüfe Firewall..."

if command -v nft &>/dev/null && nft list ruleset 2>/dev/null | grep -q "table"; then
    warn "nftables ist aktiv – stelle sicher, dass folgende Ports offen sind:"
    echo "  - UDP 67,68  (DHCP)"
    echo "  - UDP 69     (TFTP)"
    echo "  - TCP 111    (RPC/Portmapper)"
    echo "  - TCP 2049   (NFS)"
    echo "  - TCP/UDP 20048 (mountd)"
elif command -v iptables &>/dev/null && iptables -L 2>/dev/null | grep -q "DROP\|REJECT"; then
    warn "iptables hat Regeln – stelle sicher, dass DHCP/TFTP/NFS-Ports offen sind!"
else
    log "Keine aktive Firewall erkannt (gut für Lab)"
fi

# =============================================================================
# Verifizierung
# =============================================================================
echo ""
echo "============================================================================="
echo -e "${GREEN} NetBoot-Server Setup abgeschlossen!${NC}"
echo "============================================================================="
echo ""
echo "  Services:"
echo "  ├── dnsmasq (DHCP+TFTP): $(systemctl is-active dnsmasq)"
echo "  └── NFS-Server:          $(systemctl is-active nfs-kernel-server)"
echo ""
echo "  TFTP-Root: ${TFTP_ROOT}"
echo "  ├── pxelinux.0"
echo "  ├── pxelinux.cfg/default"
echo "  └── debian12/"
echo "      ├── vmlinuz"
echo "      └── initrd.img"
echo ""
echo "  NFS-Export: ${ROOTFS} → 10.0.0.0/24"
echo ""
echo "  DHCP-Range: 10.0.0.100 – 10.0.0.200"
echo ""
echo "============================================================================="
echo "  NÄCHSTER SCHRITT:"
echo "  → Test-Client VM (210) starten und PXE-Boot beobachten!"
echo ""
echo "  Debugging:"
echo "    journalctl -fu dnsmasq         # DHCP/TFTP Logs"
echo "    tail -f /var/log/dnsmasq.log   # dnsmasq Detail-Log"
echo "    journalctl -fu nfs-kernel-server  # NFS Logs"
echo "============================================================================="
