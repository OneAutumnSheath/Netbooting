# Phase 1: Lab-Netzwerk auf Proxmox aufbauen

## Übersicht

In dieser Phase erstellen wir die isolierte Lab-Umgebung auf Proxmox:
- Neues virtuelles Netzwerk (vmbr1)
- OPNsense als Gateway konfigurieren (WAN = öffentliche IP)
- NetBoot Server VM (Debian 12)
- Test-Client VMs (leere VMs für PXE-Boot)

## Netzwerk-Architektur

```
           Internet
              │
              │ Öffentliche IP
              │
       ┌──────┴───────┐
       │   OPNsense   │
       │              │
       │  WAN: vmbr0  │  ← 188.34.130.124/27 (Öffentliche IP)
       │  LAN: vmbr1  │  ← 10.0.0.1/24 (Lab-Netz)
       └──────┬───────┘
              │
    vmbr1 (10.0.0.0/24)
              │
    ┌─────────┼──────────┐
    │         │          │
┌───┴───┐ ┌──┴───┐ ┌───┴────┐
│NetBoot│ │Client│ │Client  │
│Server │ │ VM 1 │ │ VM 2   │
│  .2   │ │(PXE) │ │(PXE)   │
└───────┘ └──────┘ └────────┘
```

> **Hinweis:** OPNsense bekommt eine öffentliche IP auf WAN (vmbr0).
> Das Lab-Netz hat **keinen Zugang** zum internen Produktivnetz.

---

## Schritt 1: Virtuelle Bridge erstellen (vmbr1)

### Auf dem Proxmox Host

**Via Web-GUI:**
1. Proxmox Web-UI → Datacenter → Node → System → Network
2. "Create" → "Linux Bridge"
3. Einstellungen:

| Feld | Wert |
|------|------|
| Name | `vmbr1` |
| IPv4/CIDR | *leer lassen* |
| Gateway | *leer lassen* |
| Bridge ports | *leer lassen* (rein virtuell!) |
| Comment | `NetBoot Lab - Isoliert` |

4. "Apply Configuration" klicken

**Oder via CLI:**
```bash
# /etc/network/interfaces erweitern:
cat >> /etc/network/interfaces << 'EOF'

auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    # NetBoot Lab - Isoliertes Netzwerk
EOF

# Netzwerk neu laden (oder reboot)
ifreload -a
```

### Verifizierung
```bash
# Bridge sollte existieren
brctl show vmbr1

# Sollte keine physischen Ports haben
ip link show vmbr1
```

---

## Schritt 2: OPNsense konfigurieren

### 2.1 Zweites NIC hinzufügen

1. Proxmox Web-UI → OPNsense VM → Hardware
2. "Add" → "Network Device"
3. Einstellungen:

| Feld | Wert |
|------|------|
| Bridge | `vmbr1` |
| Model | VirtIO (paravirtualized) |
| Firewall | ☑️ aktiviert |

4. OPNsense VM neustarten

### 2.2 LAN-Interface in OPNsense einrichten

1. OPNsense Web-UI öffnen (über WAN/bestehende IP)
2. **Interfaces → Assignments**
   - Neues Interface zuweisen (das neue vtnet1 / vmbr1)
   - "Save"
3. **Interfaces → [LAN]** (oder das neue Interface)
   - Enable: ☑️
   - IPv4 Configuration Type: Static IPv4
   - IPv4 Address: `10.0.0.1/24`
   - Save & Apply

### 2.3 DHCP auf OPNsense DEAKTIVIEREN (für Lab-Netz)

> **Wichtig:** Wir machen DHCP auf dem NetBoot-Server selbst (dnsmasq),
> damit wir volle Kontrolle über PXE-Optionen haben!

1. **Services → DHCPv4 → [LAN]**
   - Enable: ☐ (deaktiviert!)
   - Save

### 2.4 Firewall-Regeln für Lab-Netz

1. **Firewall → Rules → LAN**
2. Folgende Regeln erstellen:

| # | Action | Source | Destination | Port | Beschreibung |
|---|--------|--------|-------------|------|--------------|
| 1 | Pass | LAN net | LAN net | any | Lab-interne Kommunikation |
| 2 | Pass | LAN net | * | 80,443 | HTTP/HTTPS (Updates) |
| 3 | Pass | LAN net | * | 53 | DNS |
| 4 | Block | LAN net | RFC1918 | any | Kein Zugriff auf private Netze |
| 5 | Pass | LAN net | * | any | Rest erlauben (Internet) |

> Regel 4 stellt sicher, dass das Lab **nicht** auf andere interne Netze zugreifen kann.

### 2.5 DNS-Weiterleitung

1. **Services → Unbound DNS → General**
   - Listen on: LAN Interface hinzufügen
   - Oder: NAT/Forwarding aktivieren damit Lab-Netz DNS auflösen kann

---

## Schritt 3: NetBoot Server VM erstellen

### 3.1 VM in Proxmox anlegen

**Via Web-GUI:**

| Einstellung | Wert |
|-------------|------|
| VM ID | z.B. `200` |
| Name | `netboot-server` |
| OS | Debian 12 ISO |
| System | BIOS: OVMF (UEFI), Machine: q35 |
| CPU | 4 Cores |
| RAM | 8192 MB (8 GB) |
| Disk | 200 GB (für OS-Images) |
| Network | Bridge: `vmbr1`, Model: VirtIO |

**Via CLI:**
```bash
# VM erstellen
qm create 200 \
  --name netboot-server \
  --cores 4 \
  --memory 8192 \
  --net0 virtio,bridge=vmbr1 \
  --scsihw virtio-scsi-single \
  --scsi0 local-lvm:200,ssd=1 \
  --boot order=scsi0 \
  --ostype l26 \
  --agent enabled=1
```

### 3.2 Debian 12 installieren

1. Debian 12 ISO herunterladen und in Proxmox hochladen
2. ISO als CD-ROM mounten und VM starten
3. Minimal-Installation durchführen:

| Einstellung | Wert |
|-------------|------|
| Hostname | `netboot-server` |
| Domain | `lab.local` |
| Root Passwort | (sicheres Passwort wählen) |
| User | `admin` |
| Partitionierung | Guided - entire disk |
| Software | ☑️ SSH Server, ☑️ Standard System Utilities |
|  | ☐ Desktop Environment (nicht nötig!) |

### 3.3 Statische IP konfigurieren

Nach der Installation:
```bash
# /etc/network/interfaces
auto ens18
iface ens18 inet static
    address 10.0.0.2/24
    gateway 10.0.0.1
    dns-nameservers 10.0.0.1
```

### 3.4 Basis-Pakete installieren

```bash
apt update && apt upgrade -y

apt install -y \
  dnsmasq \
  tftpd-hpa \
  nfs-kernel-server \
  samba \
  nginx \
  ipxe \
  git \
  curl \
  wget \
  htop \
  net-tools
```

---

## Schritt 4: Test-Client VMs erstellen

### 4.1 Client VM für PXE-Boot

> **Wichtig:** Wir erstellen VMs OHNE Festplatte und mit PXE als Boot-Option!

**Via Web-GUI:**

| Einstellung | Wert |
|-------------|------|
| VM ID | z.B. `210` |
| Name | `pxe-client-1` |
| OS | Do not use any media |
| System | BIOS: SeaBIOS (Legacy) ODER OVMF (UEFI) |
| CPU | 2 Cores |
| RAM | 4096 MB (4 GB) |
| Disk | **Keine!** (bei Wizard "No Disk" oder nachher löschen) |
| Network | Bridge: `vmbr1`, Model: `Intel E1000` |

> **NIC Model:** Wir nehmen erstmal `Intel E1000` statt VirtIO, weil E1000
> einen eingebauten PXE-ROM hat. VirtIO braucht einen extra iPXE-ROM.

**Via CLI:**
```bash
# Client VM ohne Disk erstellen
qm create 210 \
  --name pxe-client-1 \
  --cores 2 \
  --memory 4096 \
  --net0 e1000,bridge=vmbr1 \
  --boot order=net0 \
  --ostype l26

# Zweiten Client erstellen
qm create 211 \
  --name pxe-client-2 \
  --cores 2 \
  --memory 4096 \
  --net0 e1000,bridge=vmbr1 \
  --boot order=net0 \
  --ostype l26
```

### 4.2 Boot-Reihenfolge verifizieren

1. VM → Options → Boot Order
2. Sicherstellen: `net0` ist **erste** Boot-Option
3. Alle anderen Optionen deaktivieren oder nach unten schieben

### 4.3 Für spätere UEFI-Tests

Zusätzlich eine UEFI-Client-VM erstellen:
```bash
qm create 212 \
  --name pxe-client-uefi \
  --cores 2 \
  --memory 4096 \
  --net0 virtio,bridge=vmbr1 \
  --boot order=net0 \
  --ostype l26 \
  --bios ovmf \
  --machine q35 \
  --efidisk0 local-lvm:1
```

---

## Schritt 5: Verbindungstest

### 5.1 Vom NetBoot-Server aus

```bash
# Gateway erreichbar?
ping -c 3 10.0.0.1

# Internet erreichbar?
ping -c 3 8.8.8.8

# DNS funktioniert?
nslookup google.com
```

### 5.2 Test-Client starten (noch kein PXE-Server!)

Wenn du jetzt einen Test-Client startest, solltest du sehen:
- Client versucht PXE-Boot
- "PXE-E51: No DHCP or proxyDHCP offers were received"
- **Das ist korrekt!** → DHCP/PXE wird in Phase 2 eingerichtet

---

## ✅ Checkliste Phase 1

- [ ] vmbr1 Bridge auf Proxmox erstellt
- [ ] OPNsense: Zweites NIC (vmbr1) hinzugefügt
- [ ] OPNsense: LAN-Interface konfiguriert (10.0.0.1/24)
- [ ] OPNsense: DHCP auf LAN deaktiviert
- [ ] OPNsense: Firewall-Regeln für Lab-Netz erstellt
- [ ] OPNsense: DNS-Forwarding funktioniert
- [ ] NetBoot Server VM erstellt und Debian 12 installiert
- [ ] NetBoot Server: Statische IP 10.0.0.2 konfiguriert
- [ ] NetBoot Server: Basis-Pakete installiert
- [ ] NetBoot Server: Ping zu Gateway + Internet funktioniert
- [ ] Test-Client VMs erstellt (ohne Disk, PXE-Boot)
- [ ] Test-Client: Zeigt PXE-Boot-Versuch (noch kein Server = Fehler erwartet)

---

## Nächster Schritt

→ [Phase 2: Linux Diskless Boot](phase-2-linux-diskless.md)
