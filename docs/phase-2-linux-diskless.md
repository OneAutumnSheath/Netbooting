# Phase 2: Linux Diskless Boot (Debian 12 via NFS)

## Übersicht

In dieser Phase bringen wir einen Test-Client dazu, ein vollständiges Debian 12 über das Netzwerk zu booten – komplett ohne lokale Festplatte. Das Root-Filesystem liegt auf dem NetBoot-Server und wird per NFS gemountet.

**Alles passiert auf den Proxmox-VMs – nicht auf dem Host!**

## Boot-Kette

```
┌──────────────────────────────────────────────────────────────────┐
│                      iPXE Boot-Ablauf                            │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Client VM (210)                    NetBoot-Server (10.0.0.2)   │
│  ┌──────────┐                       ┌──────────────────┐        │
│  │ iPXE-ROM │──── DHCP Discover ───→│ dnsmasq          │        │
│  │ (E1000)  │←─── DHCP Offer ──────│ (DHCP + TFTP)    │        │
│  │          │     IP: 10.0.0.1xx    │                  │        │
│  │          │     next: 10.0.0.2    │                  │        │
│  │          │     file: boot.ipxe   │                  │        │
│  │          │                       │                  │        │
│  │          │──── TFTP: boot.ipxe ─→│ /srv/netboot/    │        │
│  │          │←─── iPXE-Script ─────│   tftp/           │        │
│  │          │                       │                  │        │
│  │  iPXE    │──── Menü-Auswahl ────→│                  │        │
│  │  Menü    │←─── vmlinuz ─────────│   tftp/debian12/ │        │
│  │          │←─── initrd.img ──────│                  │        │
│  │          │                       │                  │        │
│  │  Kernel  │──── NFS Mount ───────→│ nfs-server       │        │
│  │  bootet  │←─── Root-FS ─────────│   /srv/netboot/  │        │
│  │          │                       │   rootfs/        │        │
│  └──────────┘                       └──────────────────┘        │
│                                                                  │
│  Ergebnis: Vollständiges Debian 12 läuft auf Client VM          │
│            ohne lokale Festplatte!                               │
└──────────────────────────────────────────────────────────────────┘
```

## Voraussetzungen

- [x] Phase 1 abgeschlossen (Lab-Netzwerk steht)
- [x] NetBoot-Server VM (10.0.0.2) läuft mit Debian 12
- [x] Test-Client VM (210) ohne Festplatte, E1000 NIC, PXE-Boot
- [x] OPNsense: DHCP auf LAN **deaktiviert**
- [x] Internet-Zugang vom NetBoot-Server aus funktioniert

---

## Schritt 1: Repo auf den NetBoot-Server bringen

### Auf dem NetBoot-Server (10.0.0.2)

Das Repo mit den Scripts und Configs muss auf den Server. Entweder per Git oder SCP:

**Option A: Git (wenn Internet funktioniert)**
```bash
apt install -y git
cd /opt
git clone <repo-url> netboot-spielerei
cd /opt/netboot-spielerei
```

**Option B: SCP vom lokalen Rechner**
```bash
# Vom lokalen Mac aus:
scp -r /pfad/zu/NetBoot-Spielerei admin@10.0.0.2:/opt/netboot-spielerei
```

---

## Schritt 2: Root-Filesystem bauen (debootstrap)

### Auf dem NetBoot-Server (10.0.0.2)

Das Script `build-rootfs.sh` erstellt ein komplettes Debian 12 Root-FS per debootstrap und konfiguriert es für diskless Boot.

```bash
# Script ausführbar machen und starten
chmod +x /opt/netboot-spielerei/scripts/build-rootfs.sh
sudo /opt/netboot-spielerei/scripts/build-rootfs.sh
```

**Was das Script macht:**

1. **debootstrap** – Installiert ein minimales Debian 12 nach `/srv/netboot/rootfs`
2. **APT-Quellen** – Konfiguriert main + contrib + non-free + firmware
3. **Pakete** – Installiert Kernel, Firmware, NFS-Client, SSH, Basis-Tools
4. **Hostname** – Setzt `nabe-client.lab.local`
5. **fstab** – Konfiguriert tmpfs für `/tmp`, `/run`, `/var/log`, `/var/tmp`
6. **Netzwerk** – Aktiviert systemd-networkd mit DHCP
7. **Initramfs** – Baut initrd mit `BOOT=nfs` und Netzwerk-Treibern (e1000, virtio_net)
8. **Kernel** – Kopiert vmlinuz + initrd.img nach `/srv/netboot/tftp/debian12/`

### Manuelle Prüfung nach dem Script

```bash
# Root-FS vorhanden?
ls /srv/netboot/rootfs/etc/

# Kernel + Initrd vorhanden?
ls -la /srv/netboot/tftp/debian12/
# → vmlinuz und initrd.img sollten da sein

# Initramfs enthält NFS-Module?
lsinitramfs /srv/netboot/tftp/debian12/initrd.img | grep nfs
# → sollte nfs.ko, nfsv4.ko etc. zeigen
```

**Dauer:** ca. 5–10 Minuten (je nach Internetgeschwindigkeit)

---

## Schritt 3: NetBoot-Server einrichten (DHCP + TFTP + NFS)

### Auf dem NetBoot-Server (10.0.0.2)

Das Script `setup-netboot-server.sh` richtet dnsmasq (DHCP+TFTP), das iPXE-Boot-Script und den NFS-Server ein.

```bash
chmod +x /opt/netboot-spielerei/scripts/setup-netboot-server.sh
sudo /opt/netboot-spielerei/scripts/setup-netboot-server.sh
```

**Was das Script macht:**

1. **Pakete** – Installiert dnsmasq, nfs-kernel-server
2. **tftpd-hpa** – Wird deaktiviert (dnsmasq übernimmt TFTP)
3. **TFTP-Verzeichnis** – Erstellt Verzeichnisstruktur
4. **Configs** – Deployed dnsmasq.conf, NFS exports, iPXE Boot-Script
5. **Services** – Startet und aktiviert dnsmasq + NFS-Server

### Manuelle Prüfung nach dem Script

```bash
# Services laufen?
systemctl status dnsmasq
systemctl status nfs-kernel-server

# dnsmasq lauscht auf richtigem Interface?
ss -ulnp | grep :67   # DHCP
ss -ulnp | grep :69   # TFTP

# NFS-Export aktiv?
exportfs -v
# → /srv/netboot/rootfs 10.0.0.0/24(...)

# TFTP-Verzeichnis komplett?
ls -la /srv/netboot/tftp/
# → boot.ipxe
ls -la /srv/netboot/tftp/debian12/
# → vmlinuz, initrd.img
```

---

## Schritt 4: Erster PXE-Boot-Test

### 4.1 Test-Client starten

1. **Proxmox Web-UI** → VM 210 (`pxe-client-1`)
2. **Console** öffnen (noVNC oder SPICE)
3. **Start** klicken

### 4.2 Was du sehen solltest

```
1. iPXE-ROM initialisiert
   → "iPXE initialising devices..."
   → "net0: <MAC> using 82540em on ..."

2. DHCP-Anfrage
   → "Configuring (net0 <MAC>)... ok"
   → "net0: 10.0.0.1xx/255.255.255.0"
   → "Next server: 10.0.0.2"
   → "Filename: boot.ipxe"

3. iPXE Boot-Menü
   ╔═══════════════════════════════════════╗
   ║  NetBoot Lab - Boot Menue            ║
   ╠═══════════════════════════════════════╣
   ║  1. Debian 12 Diskless (NFS Boot)  ◄ ║
   ║  2. Debian 12 Diskless (Read-Only)   ║
   ║  3. Von lokaler Festplatte booten    ║
   ║     iPXE Shell                        ║
   ╚═══════════════════════════════════════╝

4. Kernel lädt...
   → "tftp://10.0.0.2/debian12/vmlinuz... ok"
   → "tftp://10.0.0.2/debian12/initrd.img... ok"

5. Kernel-Meldungen
   → "IP-Config: Got DHCP answer from 10.0.0.2"
   → "NFS: mounted 10.0.0.2:/srv/netboot/rootfs"

6. Login-Prompt!
   → "nabe-client login: root"
   → "Password: netboot"
```

### 4.3 Nach dem Login testen

```bash
# Wo kommt das Root-FS her?
df -h
# → 10.0.0.2:/srv/netboot/rootfs  on  /

mount | grep nfs
# → 10.0.0.2:/srv/netboot/rootfs on / type nfs4 (...)

# tmpfs-Mounts da?
df -h | grep tmpfs
# → tmpfs auf /tmp, /run, /var/log

# Netzwerk funktioniert?
ip addr show
ping -c 3 10.0.0.1    # Gateway
ping -c 3 8.8.8.8     # Internet
ping -c 3 google.com  # DNS

# System-Info
uname -a
cat /etc/os-release
free -h
```

---

## Schritt 5: Debugging & Troubleshooting

### Logs auf dem NetBoot-Server beobachten

Am besten **zwei SSH-Sessions** zum NetBoot-Server öffnen:

**Terminal 1: DHCP/TFTP-Logs**
```bash
journalctl -fu dnsmasq
# oder
tail -f /var/log/dnsmasq.log
```

**Terminal 2: NFS-Logs**
```bash
journalctl -fu nfs-kernel-server
```

### Häufige Probleme

#### Problem: "No DHCP offers received"
```
No IP address configured
```
**Ursache:** dnsmasq läuft nicht oder lauscht auf falschem Interface
```bash
# Auf dem NetBoot-Server:
systemctl status dnsmasq
journalctl -u dnsmasq --no-pager | tail -20

# Prüfen ob Port 67 offen ist:
ss -ulnp | grep :67

# Interface richtig? Muss ens18 sein:
ip addr show ens18
```

#### Problem: "TFTP Timeout / boot.ipxe not found"
```
Could not boot: Connection timed out (http://ipxe.org/4c106035)
```
**Ursache:** TFTP-Root falsch oder Datei fehlt
```bash
# Datei vorhanden?
ls -la /srv/netboot/tftp/boot.ipxe

# TFTP-Root in dnsmasq.conf prüfen:
grep tftp /etc/dnsmasq.conf

# TFTP testen (von einem anderen Rechner im Lab):
apt install tftp-hpa
tftp 10.0.0.2 -c get boot.ipxe
```

#### Problem: iPXE bekommt kein Script (startet in Shell)
```
iPXE> _
```
**Ursache:** dnsmasq erkennt iPXE nicht korrekt oder boot.ipxe wird nicht zugewiesen
```bash
# dnsmasq-Log prüfen – iPXE-Tag gesetzt?
grep -i ipxe /var/log/dnsmasq.log

# Manueller Test aus der iPXE-Shell:
iPXE> dhcp
iPXE> chain tftp://10.0.0.2/boot.ipxe
```

#### Problem: Kernel lädt, aber "VFS: Unable to mount root fs"
```
VFS: Unable to mount root fs on unknown-block(0,255)
```
**Ursache:** Initramfs hat keine NFS-Unterstützung
```bash
# Prüfen ob NFS im Initramfs ist:
lsinitramfs /srv/netboot/tftp/debian12/initrd.img | grep nfs

# Falls nicht: Im Root-FS die initramfs.conf prüfen und neu bauen:
chroot /srv/netboot/rootfs
cat /etc/initramfs-tools/initramfs.conf   # BOOT=nfs ?
update-initramfs -u -k all
exit

# Neues initrd.img ins TFTP-Verzeichnis kopieren:
KVER=$(ls /srv/netboot/rootfs/boot/vmlinuz-* | sort -V | tail -1 | sed 's|.*/vmlinuz-||')
cp /srv/netboot/rootfs/boot/initrd.img-${KVER} /srv/netboot/tftp/debian12/initrd.img
```

#### Problem: NFS-Mount hängt / "nfs: server not responding"
```
nfs: server 10.0.0.2 not responding, still trying
```
**Ursache:** NFS-Server läuft nicht oder Export fehlt
```bash
# Auf dem NetBoot-Server:
systemctl status nfs-kernel-server
exportfs -v
# → Muss /srv/netboot/rootfs zeigen

# NFS-Ports offen?
ss -tlnp | grep 2049

# Export neu laden:
exportfs -ra
systemctl restart nfs-kernel-server
```

#### Problem: Boot klappt, aber kein Netzwerk im Debian
**Ursache:** systemd-networkd nicht aktiv oder falscher Interface-Name
```bash
# Im gebooteten Client:
ip link show                         # Welche Interfaces gibt es?
systemctl status systemd-networkd    # Läuft der Netzwerk-Dienst?

# Auf dem Server im Root-FS prüfen:
cat /srv/netboot/rootfs/etc/systemd/network/20-wired.network
# → [Match] Name=en*  sollte E1000 und VirtIO matchen
```

---

## Konfigurationsdateien (Referenz)

Alle Config-Templates liegen im Repo unter `configs/`:

| Datei | Zweck | Deploy-Ziel auf Server |
|-------|-------|----------------------|
| `configs/dnsmasq/dnsmasq.conf` | DHCP + TFTP + iPXE | `/etc/dnsmasq.conf` |
| `configs/nfs/exports` | NFS-Exporte | `/etc/exports` |
| `configs/ipxe/boot.ipxe` | iPXE Boot-Script | `/srv/netboot/tftp/boot.ipxe` |
| `configs/pxelinux/default` | Legacy PXE-Menü (nicht mehr deployed) | — |

### Anpassungen

**DHCP-Range ändern:**
```bash
# In /etc/dnsmasq.conf:
dhcp-range=10.0.0.100,10.0.0.200,255.255.255.0,12h
```

**Root-Passwort ändern:**
```bash
chroot /srv/netboot/rootfs
passwd root
exit
```

**Zusätzliche Pakete im Root-FS installieren:**
```bash
chroot /srv/netboot/rootfs
apt install -y <paketname>
exit
```

---

## Verzeichnisstruktur auf dem NetBoot-Server

```
/srv/netboot/
├── tftp/                          ← TFTP-Root (dnsmasq)
│   ├── boot.ipxe                  ← iPXE Boot-Script (Menü)
│   └── debian12/
│       ├── vmlinuz                ← Linux Kernel
│       └── initrd.img             ← Initramfs (mit NFS-Support)
│
└── rootfs/                        ← NFS Root-Filesystem (Debian 12)
    ├── bin/ usr/ lib/ ...         ← Vollständiges Debian System
    └── etc/
        ├── fstab                  ← tmpfs-Mounts für beschreibbare Pfade
        ├── hostname               ← nabe-client
        ├── initramfs-tools/
        │   └── initramfs.conf     ← BOOT=nfs
        └── systemd/network/
            └── 20-wired.network   ← DHCP via systemd-networkd
```

---

## Checkliste Phase 2

- [ ] Repo auf NetBoot-Server gebracht (`/opt/netboot-spielerei`)
- [ ] `build-rootfs.sh` ausgeführt → Root-FS unter `/srv/netboot/rootfs`
- [ ] Kernel + Initrd vorhanden unter `/srv/netboot/tftp/debian12/`
- [ ] Initramfs enthält NFS-Module (`lsinitramfs | grep nfs`)
- [ ] `setup-netboot-server.sh` ausgeführt
- [ ] dnsmasq läuft (`systemctl status dnsmasq`)
- [ ] NFS-Server läuft (`systemctl status nfs-kernel-server`)
- [ ] NFS-Export aktiv (`exportfs -v`)
- [ ] iPXE Boot-Script vorhanden (`/srv/netboot/tftp/boot.ipxe`)
- [ ] Test-Client VM (210) gestartet → iPXE-Boot erfolgreich
- [ ] DHCP-Adresse erhalten
- [ ] iPXE Boot-Menü erscheint
- [ ] Kernel + Initrd laden
- [ ] NFS-Root wird gemountet
- [ ] Login-Prompt erscheint → root / netboot
- [ ] Netzwerk funktioniert (ping Gateway + Internet)

---

## Nächster Schritt

→ [Phase 3: Windows Server + AD + WDS](phase-3-windows-ad.md)
