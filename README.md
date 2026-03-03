# NABE – Network Admin Boot Environment

## 🎯 Projektziel

Aufbau einer PXE/NetBoot-Infrastruktur, die es ermöglicht, von **jedem beliebigen PC** im Kundennetzwerk eine **diskless Admin-Umgebung** zu booten – geschützt durch Active Directory Authentifizierung.

## 🏗️ Use Case

Als IT-Dienstleister bauen wir für Kunden komplette Netzwerke auf (Windows 11, Hybrid AD).
Wir benötigen eine Möglichkeit, uns an jedem PC im Netz eine **sichere Admin-Umgebung** zu booten, ohne:
- Uns am User-Windows anzumelden
- Einen USB-Stick mitzubringen
- Die User-Installation zu beeinflussen

## 📋 Phasen

| Phase | Inhalt | Status |
|-------|--------|--------|
| [Phase 1](docs/phase-1-lab-netzwerk.md) | Lab-Netzwerk auf Proxmox aufbauen | ✅ Fertig |
| [Phase 2](docs/phase-2-linux-diskless.md) | Linux Diskless Boot (PoC) | 🔨 In Arbeit |
| [Phase 3](docs/phase-3-windows-ad.md) | Windows Server + AD + WDS | 🔲 Offen |
| [Phase 4](docs/phase-4-admin-environment.md) | Admin Boot Environment mit AD-Auth | 🔲 Offen |
| [Phase 5](docs/phase-5-produktion.md) | Hardening & Kunden-Deployment | 🔲 Offen |

## 🖥️ Lab-Umgebung

**Proxmox Host:**
- CPU: 80 × Intel Xeon Gold 6138 @ 2.00GHz (2 Sockets)
- RAM: 503 GiB
- SSD: 4,76 TB

**Bestehende VMs:**
- OPNsense (Gateway/Firewall)

## 🌐 Netzwerk-Design

```
Internet
       │
       │ 188.34.130.124/27 (Öffentliche IP)
       │
┌──────┴───────┐
│   OPNsense   │
│  WAN: vmbr0  │  ← 188.34.130.124/27
│  LAN: vmbr1  │  ← 10.0.0.1/24
└──────┬───────┘
       │
vmbr1 (Isoliertes Lab-Netz: 10.0.0.0/24)
       │
       ├── NetBoot Server  (10.0.0.2)
       ├── Test-Client 1   (DHCP)
       └── Test-Client 2   (DHCP)
```

## 📂 Repo-Struktur

```
├── README.md                  # Diese Datei
├── docs/                      # Schritt-für-Schritt Anleitungen
│   ├── phase-1-lab-netzwerk.md
│   ├── phase-2-linux-diskless.md
│   ├── phase-3-windows-ad.md
│   ├── phase-4-admin-environment.md
│   └── phase-5-produktion.md
├── configs/                   # Config-Templates
│   ├── dnsmasq/
│   ├── ipxe/
│   ├── nfs/
│   └── proxmox/
├── scripts/                   # Automatisierungs-Scripts
│   ├── setup-netboot-server.sh
│   └── create-lab-vms.sh
└── images/                    # Diagramme & Screenshots
```

## 🔐 Sicherheitskonzept (Ziel)

1. **iPXE HTTP-Auth**: Credentials werden vor Image-Auslieferung gegen AD/LDAP geprüft
2. **AD-Login**: Admin-Umgebung erlaubt nur Login für Mitglieder der Admin-Gruppe
3. **Netzwerk-Isolation**: Boot-Traffic in eigenem VLAN/Subnet

## 🛠️ Technologie-Stack

| Funktion | Technologie |
|----------|-------------|
| PXE Boot-Loader | iPXE (UEFI + Legacy BIOS) |
| DHCP + TFTP | dnsmasq (Lab) → Windows DHCP (Produktion) |
| Diskless Root | NFS (Linux) / iSCSI (Windows) |
| OS Deployment | WDS + MDT |
| Auth vor Boot | iPXE HTTP-Script → LDAP-Validierung |
| Directory | Windows Server AD DS + Entra Connect |
