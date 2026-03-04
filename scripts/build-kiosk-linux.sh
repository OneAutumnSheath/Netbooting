#!/bin/bash
# =============================================================================
# build-kiosk-linux.sh – Mini-Linux mit X11 + Firefox Kiosk bauen
# =============================================================================
# Erstellt ein minimales Debian 12 System mit:
#   - X11 (xserver-xorg-core + fbdev/vesa)
#   - Firefox ESR im Kiosk-Modus
#   - systemd-networkd (DHCP)
#   - nabe-agent (lokaler kexec/reboot HTTP-Server)
#   - kexec-tools
#
# Das Ergebnis ist ein Kernel + Initramfs, das via iPXE geladen wird.
# Firefox oeffnet automatisch das Laravel-Dashboard.
#
# Ausfuehren auf: netboot-server (10.10.0.2)
# Als: root
# =============================================================================

set -euo pipefail

# --- Konfiguration ---
KIOSK_ROOT="/srv/netboot/kiosk-linux/rootfs"
KIOSK_OUT="/srv/netboot/kiosk-linux"
DEBIAN_RELEASE="bookworm"
DEBIAN_MIRROR="http://deb.debian.org/debian"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$(cd "${SCRIPT_DIR}/../configs" && pwd)"
KIOSK_CONFIG="${CONFIG_DIR}/kiosk-linux"

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
command -v debootstrap &>/dev/null || err "debootstrap nicht installiert! -> apt install debootstrap"

echo ""
echo "============================================================================="
echo -e "${GREEN} Support-Tools – Kiosk-Linux Build${NC}"
echo "============================================================================="
echo ""

# =============================================================================
# Schritt 1: Debootstrap – Minimales Basis-System
# =============================================================================
log "Schritt 1: Debian ${DEBIAN_RELEASE} Minimal-System installieren"

if [[ -d "${KIOSK_ROOT}/etc" ]]; then
    warn "Kiosk-Root existiert bereits in ${KIOSK_ROOT}"
    read -p "Loeschen und neu bauen? (j/N) " -r
    if [[ $REPLY =~ ^[Jj]$ ]]; then
        log "Loesche bestehendes Kiosk-Root..."
        rm -rf "${KIOSK_ROOT}"
    else
        warn "Ueberspringe debootstrap, nutze bestehendes System"
    fi
fi

if [[ ! -d "${KIOSK_ROOT}/etc" ]]; then
    mkdir -p "${KIOSK_ROOT}"
    debootstrap --variant=minbase --arch=amd64 \
        "${DEBIAN_RELEASE}" "${KIOSK_ROOT}" "${DEBIAN_MIRROR}"
    log "Debootstrap abgeschlossen"
fi

# =============================================================================
# Schritt 2: APT-Quellen + Pakete installieren
# =============================================================================
log "Schritt 2: Pakete installieren"

cat > "${KIOSK_ROOT}/etc/apt/sources.list" << EOF
deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE} main contrib non-free non-free-firmware
deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE}-updates main contrib non-free non-free-firmware
EOF

# Chroot-Mounts
mount --bind /proc "${KIOSK_ROOT}/proc" 2>/dev/null || true
mount --bind /sys  "${KIOSK_ROOT}/sys"  2>/dev/null || true
mount --bind /dev  "${KIOSK_ROOT}/dev"  2>/dev/null || true

cleanup() {
    log "Chroot-Mounts aufraeumen..."
    umount "${KIOSK_ROOT}/proc" 2>/dev/null || true
    umount "${KIOSK_ROOT}/sys"  2>/dev/null || true
    umount "${KIOSK_ROOT}/dev"  2>/dev/null || true
}
trap cleanup EXIT

chroot "${KIOSK_ROOT}" /bin/bash -c "
    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y --no-install-recommends \
        linux-image-amd64 \
        systemd \
        systemd-sysv \
        dbus \
        kexec-tools \
        xserver-xorg-core \
        xserver-xorg-video-fbdev \
        xserver-xorg-video-vesa \
        xserver-xorg-input-libinput \
        xinit \
        x11-xserver-utils \
        firefox-esr \
        iproute2 \
        iputils-ping \
        python3 \
        kbd \
        ca-certificates \
        dbus-x11 \
        systemd-resolved
"

log "Pakete installiert"

# =============================================================================
# Schritt 3: Netzwerk (systemd-networkd + DHCP)
# =============================================================================
log "Schritt 3: Netzwerk konfigurieren"

mkdir -p "${KIOSK_ROOT}/etc/systemd/network"
cp "${KIOSK_CONFIG}/20-dhcp.network" "${KIOSK_ROOT}/etc/systemd/network/20-dhcp.network"

chroot "${KIOSK_ROOT}" /bin/bash -c "
    systemctl enable systemd-networkd
    systemctl enable systemd-resolved
"

ln -sf /run/systemd/resolve/resolv.conf "${KIOSK_ROOT}/etc/resolv.conf"

log "systemd-networkd mit DHCP auf eth0 konfiguriert"

# =============================================================================
# Schritt 4: Kiosk-Benutzer erstellen
# =============================================================================
log "Schritt 4: Kiosk-Benutzer erstellen"

chroot "${KIOSK_ROOT}" /bin/bash -c "
    useradd -m -s /bin/bash kiosk 2>/dev/null || true
    # kiosk darf X11 starten (Zugriff auf /dev/tty*, /dev/input/*)
    usermod -aG video,input,tty kiosk 2>/dev/null || true
"

log "Benutzer 'kiosk' erstellt (video, input, tty Gruppen)"

# =============================================================================
# Schritt 5: NABE Kiosk-Service + Agent deployen
# =============================================================================
log "Schritt 5: NABE Services deployen"

# Kiosk-Script
cp "${KIOSK_CONFIG}/nabe-kiosk.sh" "${KIOSK_ROOT}/usr/local/bin/nabe-kiosk.sh"
chmod +x "${KIOSK_ROOT}/usr/local/bin/nabe-kiosk.sh"

# Agent-Script
cp "${KIOSK_CONFIG}/nabe-agent.py" "${KIOSK_ROOT}/usr/local/bin/nabe-agent.py"
chmod +x "${KIOSK_ROOT}/usr/local/bin/nabe-agent.py"

# xinitrc (Fallback)
cp "${KIOSK_CONFIG}/xinitrc" "${KIOSK_ROOT}/home/kiosk/.xinitrc"
chmod +x "${KIOSK_ROOT}/home/kiosk/.xinitrc"
chroot "${KIOSK_ROOT}" chown kiosk:kiosk /home/kiosk/.xinitrc

# Systemd-Services
cp "${KIOSK_CONFIG}/nabe-kiosk.service" "${KIOSK_ROOT}/etc/systemd/system/nabe-kiosk.service"
cp "${KIOSK_CONFIG}/nabe-agent.service" "${KIOSK_ROOT}/etc/systemd/system/nabe-agent.service"

chroot "${KIOSK_ROOT}" /bin/bash -c "
    systemctl enable nabe-kiosk.service
    systemctl enable nabe-agent.service
"

# X11: Erlaube Kiosk-User ohne Root
mkdir -p "${KIOSK_ROOT}/etc/X11"
cat > "${KIOSK_ROOT}/etc/X11/Xwrapper.config" << EOF
allowed_users=anybody
needs_root_rights=yes
EOF

log "nabe-kiosk.service + nabe-agent.service installiert und aktiviert"

# =============================================================================
# Schritt 6: Firefox-Profil vorkonfigurieren (kein First-Run)
# =============================================================================
log "Schritt 6: Firefox-Profil konfigurieren"

mkdir -p "${KIOSK_ROOT}/usr/lib/firefox-esr/distribution"
cat > "${KIOSK_ROOT}/usr/lib/firefox-esr/distribution/policies.json" << 'EOF'
{
    "policies": {
        "DisableProfileImportWizard": true,
        "DontCheckDefaultBrowser": true,
        "DisableTelemetry": true,
        "DisableFirefoxStudies": true,
        "DisablePocket": true,
        "DisableFirefoxAccounts": true,
        "DisableFormHistory": true,
        "DisablePasswordReveal": true,
        "OverrideFirstRunPage": "",
        "OverridePostUpdatePage": "",
        "Preferences": {
            "browser.shell.checkDefaultBrowser": false,
            "datareporting.policy.dataSubmissionEnabled": false,
            "browser.newtabpage.activity-stream.feeds.topsites": false,
            "browser.newtabpage.activity-stream.showSponsoredTopSites": false
        }
    }
}
EOF

log "Firefox First-Run-Wizard deaktiviert"

# =============================================================================
# Schritt 7: Hostname + Tastatur
# =============================================================================
log "Schritt 7: System-Konfiguration"

echo "nabe-kiosk" > "${KIOSK_ROOT}/etc/hostname"

cat > "${KIOSK_ROOT}/etc/default/keyboard" << EOF
XKBMODEL="pc105"
XKBLAYOUT="de"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF

# Autologin-TTY deaktivieren (nur Kiosk-Service)
chroot "${KIOSK_ROOT}" /bin/bash -c "
    systemctl mask getty@tty1.service 2>/dev/null || true
"

# =============================================================================
# Schritt 8: Kernel + Initramfs extrahieren
# =============================================================================
log "Schritt 8: Kernel + Initramfs extrahieren"

mkdir -p "${KIOSK_OUT}"

# Neuesten Kernel finden
KERNEL_VERSION=$(ls "${KIOSK_ROOT}/boot/vmlinuz-"* | sort -V | tail -1 | sed 's|.*/vmlinuz-||')
log "Kernel-Version: ${KERNEL_VERSION}"

cp "${KIOSK_ROOT}/boot/vmlinuz-${KERNEL_VERSION}" "${KIOSK_OUT}/vmlinuz"

# Initramfs mit dem vollen Rootfs bauen
# Wir nutzen eine andere Methode: Das gesamte Rootfs wird als initramfs gepackt
log "Packe Rootfs als Initramfs (das dauert etwas)..."

# Aufraemen: unnoetige Dateien entfernen um Groesse zu reduzieren
chroot "${KIOSK_ROOT}" /bin/bash -c "
    apt-get clean
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /var/tmp/*
    rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*
    rm -rf /usr/share/locale/!(de|en|locale.alias)
    rm -rf /var/log/*
"

# Initramfs aus dem Rootfs erstellen (cpio + gzip)
cd "${KIOSK_ROOT}"
find . -print0 | cpio --null -o --format=newc 2>/dev/null | gzip -1 > "${KIOSK_OUT}/initramfs.img"
cd - >/dev/null

INITRAMFS_SIZE=$(du -sh "${KIOSK_OUT}/initramfs.img" | cut -f1)
KERNEL_SIZE=$(du -sh "${KIOSK_OUT}/vmlinuz" | cut -f1)

log "Kernel: ${KIOSK_OUT}/vmlinuz (${KERNEL_SIZE})"
log "Initramfs: ${KIOSK_OUT}/initramfs.img (${INITRAMFS_SIZE})"

# =============================================================================
# Schritt 9: Berechtigungen
# =============================================================================
log "Schritt 9: Berechtigungen setzen"

chmod 644 "${KIOSK_OUT}/vmlinuz"
chmod 644 "${KIOSK_OUT}/initramfs.img"

# =============================================================================
# Fertig!
# =============================================================================
echo ""
echo "============================================================================="
echo -e "${GREEN} Support-Tools Kiosk-Linux erfolgreich gebaut!${NC}"
echo "============================================================================="
echo ""
echo "  Kernel:     ${KIOSK_OUT}/vmlinuz (${KERNEL_SIZE})"
echo "  Initramfs:  ${KIOSK_OUT}/initramfs.img (${INITRAMFS_SIZE})"
echo "  Rootfs:     ${KIOSK_ROOT} (kann nach erfolgreichem Test geloescht werden)"
echo ""
echo "  Boot-Parameter fuer iPXE:"
echo "    kernel http://10.10.0.2/boot/kiosk-linux/vmlinuz quiet rdinit=/sbin/init net.ifnames=0 video=1024x768"
echo "    initrd http://10.10.0.2/boot/kiosk-linux/initramfs.img"
echo ""
echo "  Was passiert beim Boot:"
echo "    1. Kernel + Initramfs werden via HTTP geladen (~200-300 MB)"
echo "    2. systemd startet, DHCP auf eth0"
echo "    3. nabe-agent lauscht auf localhost:8080"
echo "    4. X11 + Firefox oeffnet http://10.10.0.2/dashboard?mac=XX:XX:XX"
echo ""
echo "  Test (auf dem Server):"
echo "    ls -lh ${KIOSK_OUT}/vmlinuz ${KIOSK_OUT}/initramfs.img"
echo "============================================================================="
