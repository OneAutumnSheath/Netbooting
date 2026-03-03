#!/bin/bash
# =============================================================================
# build-rootfs.sh – Debian 12 NFS Root-Filesystem bauen
# =============================================================================
# Dieses Script erstellt ein vollständiges Debian 12 Root-Filesystem
# per debootstrap und konfiguriert es für Diskless-Boot via NFS.
#
# Ausführen auf: netboot-server (10.0.0.2)
# Als: root
# =============================================================================

set -euo pipefail

# --- Konfiguration ---
ROOTFS="/srv/netboot/rootfs"
DEBIAN_RELEASE="bookworm"
DEBIAN_MIRROR="http://deb.debian.org/debian"
HOSTNAME="nabe-client"
DOMAIN="lab.local"
ROOT_PASSWORD="netboot"  # NUR FÜR LAB! In Produktion ändern!
NFS_SERVER="10.0.0.2"

# Farben für Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# --- Prüfungen ---
[[ $EUID -ne 0 ]] && err "Dieses Script muss als root ausgeführt werden!"
command -v debootstrap &>/dev/null || err "debootstrap nicht installiert! → apt install debootstrap"

# =============================================================================
# Schritt 1: Debootstrap – Basis-System installieren
# =============================================================================
log "Schritt 1: Debian ${DEBIAN_RELEASE} Basis-System installieren nach ${ROOTFS}"

if [[ -d "${ROOTFS}/etc" ]]; then
    warn "Root-FS existiert bereits in ${ROOTFS}"
    read -p "Löschen und neu bauen? (j/N) " -r
    if [[ $REPLY =~ ^[Jj]$ ]]; then
        log "Lösche bestehendes Root-FS..."
        rm -rf "${ROOTFS}"
    else
        warn "Überspringe debootstrap, nutze bestehendes Root-FS"
    fi
fi

if [[ ! -d "${ROOTFS}/etc" ]]; then
    mkdir -p "${ROOTFS}"
    debootstrap --arch=amd64 "${DEBIAN_RELEASE}" "${ROOTFS}" "${DEBIAN_MIRROR}"
    log "Debootstrap abgeschlossen"
fi

# =============================================================================
# Schritt 2: APT-Quellen konfigurieren
# =============================================================================
log "Schritt 2: APT-Quellen konfigurieren"

cat > "${ROOTFS}/etc/apt/sources.list" << EOF
deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE} main contrib non-free non-free-firmware
deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${DEBIAN_RELEASE}-security main contrib non-free non-free-firmware
EOF

# =============================================================================
# Schritt 3: Chroot-Umgebung vorbereiten und Pakete installieren
# =============================================================================
log "Schritt 3: Chroot-Umgebung vorbereiten"

# Proc/Sys/Dev mounten für chroot
mount --bind /proc "${ROOTFS}/proc" 2>/dev/null || true
mount --bind /sys  "${ROOTFS}/sys"  2>/dev/null || true
mount --bind /dev  "${ROOTFS}/dev"  2>/dev/null || true

# Cleanup-Funktion für sauberes Beenden
cleanup() {
    log "Chroot-Mounts aufräumen..."
    umount "${ROOTFS}/proc" 2>/dev/null || true
    umount "${ROOTFS}/sys"  2>/dev/null || true
    umount "${ROOTFS}/dev"  2>/dev/null || true
}
trap cleanup EXIT

log "Installiere Kernel und wichtige Pakete..."
chroot "${ROOTFS}" /bin/bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y \
        linux-image-amd64 \
        firmware-linux \
        initramfs-tools \
        nfs-common \
        systemd \
        systemd-sysv \
        dbus \
        locales \
        console-setup \
        keyboard-configuration \
        sudo \
        openssh-server \
        curl \
        wget \
        nano \
        vim-tiny \
        htop \
        net-tools \
        iputils-ping \
        iproute2 \
        dnsutils \
        bash-completion \
        pciutils \
        usbutils \
        less
"

# =============================================================================
# Schritt 4: System für Diskless-Boot konfigurieren
# =============================================================================
log "Schritt 4: System für Diskless-Boot konfigurieren"

# --- Hostname ---
echo "${HOSTNAME}" > "${ROOTFS}/etc/hostname"
cat > "${ROOTFS}/etc/hosts" << EOF
127.0.0.1   localhost
127.0.1.1   ${HOSTNAME}.${DOMAIN} ${HOSTNAME}
EOF

# --- fstab: tmpfs für beschreibbare Verzeichnisse ---
cat > "${ROOTFS}/etc/fstab" << EOF
# =============================================================================
# fstab für NFS-Root Diskless Boot
# =============================================================================
# Das Root-FS kommt via NFS (wird vom Kernel gemountet)
# Temporäre/beschreibbare Verzeichnisse als tmpfs

proc            /proc           proc    defaults                    0 0
tmpfs           /tmp            tmpfs   defaults,nosuid,nodev,size=512M  0 0
tmpfs           /run            tmpfs   defaults,nosuid,nodev,mode=755   0 0
tmpfs           /var/tmp        tmpfs   defaults,nosuid,nodev,size=256M  0 0
tmpfs           /var/log        tmpfs   defaults,nosuid,nodev,size=256M  0 0
EOF

# --- Netzwerk: DHCP via systemd-networkd ---
mkdir -p "${ROOTFS}/etc/systemd/network"
cat > "${ROOTFS}/etc/systemd/network/20-wired.network" << EOF
[Match]
Name=en*
Type=ether

[Network]
DHCP=yes

[DHCP]
UseDNS=yes
UseNTP=yes
EOF

# systemd-networkd aktivieren
chroot "${ROOTFS}" /bin/bash -c "
    systemctl enable systemd-networkd
    systemctl enable systemd-resolved
"

# --- DNS Resolver ---
ln -sf /run/systemd/resolve/resolv.conf "${ROOTFS}/etc/resolv.conf"

# --- Root-Passwort setzen ---
log "Setze root-Passwort (Lab: '${ROOT_PASSWORD}')"
chroot "${ROOTFS}" /bin/bash -c "echo 'root:${ROOT_PASSWORD}' | chpasswd"

# --- SSH: Root-Login erlauben (NUR FÜR LAB!) ---
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' "${ROOTFS}/etc/ssh/sshd_config"

# --- Locale ---
chroot "${ROOTFS}" /bin/bash -c "
    echo 'de_DE.UTF-8 UTF-8' >> /etc/locale.gen
    echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
    locale-gen
    update-locale LANG=de_DE.UTF-8
"

# --- Tastatur-Layout ---
cat > "${ROOTFS}/etc/default/keyboard" << EOF
XKBMODEL="pc105"
XKBLAYOUT="de"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF

# =============================================================================
# Schritt 5: Initramfs für NFS-Boot konfigurieren
# =============================================================================
log "Schritt 5: Initramfs für NFS-Boot konfigurieren"

# NFS-Support in Initramfs einbauen
cat > "${ROOTFS}/etc/initramfs-tools/initramfs.conf" << EOF
MODULES=netboot
BUSYBOX=auto
COMPRESS=gzip
DEVICE=
NFSROOT=auto
BOOT=nfs
EOF

# Netzwerk-Module sicherstellen
mkdir -p "${ROOTFS}/etc/initramfs-tools/modules.d"
cat > "${ROOTFS}/etc/initramfs-tools/modules" << EOF
# Netzwerk-Treiber für PXE-Boot (VirtIO + E1000)
virtio_net
e1000
e1000e
# NFS
nfs
nfsv4
EOF

# Initramfs neu bauen
log "Baue Initramfs neu (mit NFS-Support)..."
chroot "${ROOTFS}" /bin/bash -c "update-initramfs -u -k all"

# =============================================================================
# Schritt 6: Kernel + Initramfs ins TFTP-Verzeichnis kopieren
# =============================================================================
log "Schritt 6: Kernel + Initramfs ins TFTP-Verzeichnis kopieren"

TFTP_DIR="/srv/netboot/tftp/debian12"
mkdir -p "${TFTP_DIR}"

# Neuesten Kernel finden
KERNEL_VERSION=$(ls "${ROOTFS}/boot/vmlinuz-"* | sort -V | tail -1 | sed 's|.*/vmlinuz-||')
log "Kernel-Version: ${KERNEL_VERSION}"

cp "${ROOTFS}/boot/vmlinuz-${KERNEL_VERSION}" "${TFTP_DIR}/vmlinuz"
cp "${ROOTFS}/boot/initrd.img-${KERNEL_VERSION}" "${TFTP_DIR}/initrd.img"

log "Kernel und Initramfs kopiert nach ${TFTP_DIR}"

# =============================================================================
# Fertig!
# =============================================================================
echo ""
echo "============================================================================="
echo -e "${GREEN} Debian 12 NFS Root-Filesystem erfolgreich erstellt!${NC}"
echo "============================================================================="
echo ""
echo "  Root-FS:     ${ROOTFS}"
echo "  Kernel:      ${TFTP_DIR}/vmlinuz (${KERNEL_VERSION})"
echo "  Initramfs:   ${TFTP_DIR}/initrd.img"
echo "  Hostname:    ${HOSTNAME}"
echo "  Root-Login:  root / ${ROOT_PASSWORD}"
echo ""
echo "  Nächster Schritt: setup-netboot-server.sh ausführen"
echo "============================================================================="
