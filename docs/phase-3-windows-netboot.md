# Phase 3: Windows 11 Netboot mit AD-Authentifizierung

## Übersicht

Windows 11 wird via Netzwerk bootbar gemacht. Vor dem Boot authentifiziert sich
der Benutzer über iPXE mit seinen AD-Credentials. Ein Flask-Backend prüft die
Anmeldedaten per LDAP gegen den Active Directory Domain Controller und gibt
basierend auf der Gruppenzugehörigkeit das passende iPXE-Boot-Script zurück.

## Boot-Kette

Zwei Pfade, abhängig von AD-Gruppenzugehörigkeit:

```
Client PXE → iPXE (Menü) → "Windows (AD-Login erforderlich)"
  → iPXE login-Prompt (Benutzername + Passwort)
  → HTTP GET mit Basic-Auth an nginx → Flask-Backend prüft LDAP gegen AD

  INSTALL-PFAD (Gruppe: NetBoot-Install):
  → iPXE lädt wimboot + BCD + boot.sdi + install-boot.wim
  → WinPE startet, mountet Samba-Share → setup.exe auf lokale Platte

  ADMIN-PFAD (Gruppe: NetBoot-Admin):
  → Backend prüft: Existiert iSCSI-Image für diesen User?
    NEIN → Backend erstellt 60 GB sparse Image + iSCSI-Target
         → iPXE: sanhook (iSCSI-Disk verbinden) + WinPE laden
         → WinPE installiert Windows auf die iSCSI-Disk
    JA   → iPXE: sanboot direkt von iSCSI-Disk (diskless Boot)
```

**Warum iSCSI?** Die Admin-Umgebung ist komplett vom User-System getrennt.
Keine Admin-Daten landen auf der lokalen Festplatte. Jeder Admin bekommt
sein eigenes Disk-Image auf dem Server.

## Netzwerk-Übersicht

| Rolle              | IP          | Hostname           |
|--------------------|-------------|--------------------|
| OPNsense Gateway   | 10.10.0.1   | gw.lab.local       |
| NetBoot-Server     | 10.10.0.2   | netboot.lab.local  |
| Windows Server (AD)| 10.10.0.3   | dc01.lab.local     |
| DHCP-Range         | .100–.200   | (dynamisch)        |

## Voraussetzungen

- Phase 2 (Linux Diskless Boot) funktioniert
- Proxmox-Host mit genug Ressourcen für Windows Server VM
- Windows 11 ISO (z.B. `Win11_23H2_German_x64.iso`)
- Zugang zu einem Windows-Rechner für WinPE-Bau (siehe `winpe-build-anleitung.md`)

---

## Schritt 1: Windows Server VM erstellen (Proxmox)

### 1.1 VM anlegen

In der Proxmox-Weboberfläche (https://10.10.0.1:8006 oder Host-IP):

```
VM-ID:       300
Name:        win-dc01
OS:          Microsoft Windows 11/2022/2025
ISO:         Windows Server 2022 Evaluation ISO
CPU:         4 Kerne (host)
RAM:         4096 MB
Disk:        60 GB (virtio-scsi)
Netzwerk:    vmbr1 (Lab-Netz), Modell: VirtIO
```

> **Tipp:** Windows Server 2022 Evaluation ist 180 Tage kostenlos nutzbar.
> Download: https://www.microsoft.com/de-de/evalcenter/evaluate-windows-server-2022

### 1.2 Windows Server installieren

1. VM starten, Windows Server 2022 Standard (Desktop Experience) wählen
2. Administrator-Passwort setzen (z.B. `P@ssw0rd!Lab`)
3. Nach Installation: VirtIO Guest Tools installieren (für Netzwerk)
4. Statische IP konfigurieren:
   - IP: `10.10.0.3`
   - Subnetzmaske: `255.255.255.0`
   - Gateway: `10.10.0.1`
   - DNS: `127.0.0.1` (wird nach AD-Installation zum eigenen DNS)

---

## Schritt 2: Active Directory Domain Services installieren

### 2.1 AD DS Rolle hinzufügen

PowerShell (als Administrator):

```powershell
# AD DS Rolle installieren
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools

# Domain erstellen
Install-ADDSForest `
    -DomainName "lab.local" `
    -DomainNetBIOSName "LAB" `
    -SafeModeAdministratorPassword (ConvertTo-SecureString "P@ssw0rd!Safe" -AsPlainText -Force) `
    -InstallDns:$true `
    -Force:$true
```

Der Server startet automatisch neu.

### 2.2 DNS konfigurieren

Nach dem Neustart: DNS-Weiterleitung einrichten, damit Lab-Clients auch
externe Namen auflösen können.

```powershell
# DNS-Weiterleitung zu OPNsense
Add-DnsServerForwarder -IPAddress 10.10.0.1

# Reverse-Lookup-Zone erstellen (optional, aber empfohlen)
Add-DnsServerPrimaryZone -NetworkID "10.10.0.0/24" -ReplicationScope Domain
```

### 2.3 Statische DNS-Einträge

```powershell
Add-DnsServerResourceRecordA -ZoneName "lab.local" -Name "netboot" -IPv4Address "10.10.0.2"
Add-DnsServerResourceRecordA -ZoneName "lab.local" -Name "gw" -IPv4Address "10.10.0.1"
```

---

## Schritt 3: AD-Gruppen und Benutzer anlegen

### 3.1 Sicherheitsgruppen erstellen

```powershell
# OU für NetBoot-Benutzer
New-ADOrganizationalUnit -Name "NetBoot" -Path "DC=lab,DC=local"

# Gruppen erstellen
New-ADGroup -Name "NetBoot-Install" `
    -GroupScope Global `
    -GroupCategory Security `
    -Path "OU=NetBoot,DC=lab,DC=local" `
    -Description "Darf Windows 11 via Netzwerk installieren"

New-ADGroup -Name "NetBoot-Admin" `
    -GroupScope Global `
    -GroupCategory Security `
    -Path "OU=NetBoot,DC=lab,DC=local" `
    -Description "Darf WinPE Admin-Environment booten"
```

### 3.2 Test-Benutzer erstellen

```powershell
# Techniker mit Installations-Recht
New-ADUser -Name "tech01" `
    -SamAccountName "tech01" `
    -UserPrincipalName "tech01@lab.local" `
    -AccountPassword (ConvertTo-SecureString "Tech01!Pass" -AsPlainText -Force) `
    -Enabled $true `
    -Path "OU=NetBoot,DC=lab,DC=local"

Add-ADGroupMember -Identity "NetBoot-Install" -Members "tech01"

# Admin mit vollem Zugriff
New-ADUser -Name "admin01" `
    -SamAccountName "admin01" `
    -UserPrincipalName "admin01@lab.local" `
    -AccountPassword (ConvertTo-SecureString "Admin01!Pass" -AsPlainText -Force) `
    -Enabled $true `
    -Path "OU=NetBoot,DC=lab,DC=local"

Add-ADGroupMember -Identity "NetBoot-Install" -Members "admin01"
Add-ADGroupMember -Identity "NetBoot-Admin" -Members "admin01"
```

---

## Schritt 4: NetBoot-Server konfigurieren

### 4.1 Setup-Script ausführen

Auf dem NetBoot-Server (10.10.0.2):

```bash
cd /opt/netboot-spielerei   # oder wo das Repo liegt
git pull
sudo ./scripts/setup-windows-boot.sh
```

Das Script:
- Installiert nginx, samba, python3-flask, python3-ldap3
- Lädt wimboot von ipxe.org herunter
- Erstellt Verzeichnisstruktur unter `/srv/netboot/`
- Deployed alle Configs (nginx, samba, iPXE-Scripts)
- Startet Auth-Backend, nginx und samba

### 4.2 Verzeichnisstruktur nach Setup

```
/srv/netboot/
├── tftp/
│   ├── boot.ipxe                (Haupt-Boot-Menü, mit Windows-Option)
│   ├── win-install.ipxe         (WinPE Install-Boot, statisch)
│   ├── debian12/
│   │   ├── vmlinuz
│   │   └── initrd.img
│   └── winpe/
│       ├── wimboot              (iPXE wimboot Loader, automatisch)
│       ├── bcd                  ← manuell hochladen
│       ├── boot.sdi             ← manuell hochladen
│       └── install-boot.wim     ← manuell hochladen
├── rootfs/                      (Linux NFS-Root, Phase 2)
├── win11/                       (Win11 Installationsfiles)
│   └── (ISO-Inhalt hierhin)     ← manuell hochladen
└── iscsi/                       (Admin iSCSI Disk-Images)
    ├── admin01.img              (automatisch erstellt, 60 GB sparse)
    ├── admin02.img              ...
    └── (pro Admin ein Image)
```

> **Hinweis:** Admin-Boot-Scripts (iSCSI) werden dynamisch vom Auth-Backend
> generiert – keine statischen iPXE-Dateien nötig.

---

## Schritt 5: Windows 11 ISO bereitstellen

Die Win11-Installationsdateien werden via Samba-Share bereitgestellt.
Das `setup-windows-boot.sh` Script legt dort auch automatisch die
`autounattend.xml` und das Domain-Join-Script ab.

```bash
# ISO mounten und Dateien kopieren
sudo mkdir -p /srv/netboot/win11
sudo mount -o loop Win11_23H2_German_x64.iso /mnt
sudo cp -r /mnt/* /srv/netboot/win11/
sudo umount /mnt
```

Nach dem Kopieren sollte die Struktur so aussehen:
```
/srv/netboot/win11/
├── setup.exe                    (Windows Setup)
├── sources/install.wim          (Windows Image)
├── autounattend.xml             (automatisch vom Setup-Script)
├── $OEM$/$1/NABE/
│   └── domain-join.ps1          (wird nach C:\NABE\ kopiert)
└── ...                          (restliche ISO-Dateien)
```

Die `autounattend.xml` automatisiert:
- TPM/SecureBoot/RAM-Check Bypass (nötig für VM/Netzwerk-Boot)
- Disk-Partitionierung (UEFI/GPT, Disk 0)
- Deutsche Sprach-/Tastatureinstellungen
- OOBE überspringen
- Temporärer Admin-Account für ersten Login
- **Domain-Join: Techniker wird nach AD-Credentials gefragt**

---

## Schritt 6: WinPE-Image hochladen

Das WinPE-Image wird auf einem Windows-Rechner gebaut (siehe
`winpe-build-anleitung.md`) und dann auf den NetBoot-Server hochgeladen.

Es wird nur **ein** WinPE-Image benötigt (`install-boot.wim`), das sowohl
für die normale Installation als auch für die Admin-Erstinstallation auf
die iSCSI-Disk verwendet wird.

```bash
# Vom Windows-Rechner per SCP:
scp bcd root@10.10.0.2:/srv/netboot/tftp/winpe/
scp boot.sdi root@10.10.0.2:/srv/netboot/tftp/winpe/
scp install-boot.wim root@10.10.0.2:/srv/netboot/tftp/winpe/
```

Alternativ per Samba-Share oder USB-Stick.

---

## Schritt 7: Verifikation

### 7.1 Services prüfen

```bash
# Alle Services aktiv?
systemctl status nginx
systemctl status smbd
systemctl status tgt
systemctl status netboot-auth
systemctl status dnsmasq
systemctl status nfs-kernel-server

# Auth-Backend erreichbar?
curl -v http://localhost:5000/health

# iSCSI-Targets anzeigen
tgtadm --lld iscsi --op show --mode target
```

### 7.2 AD-Authentifizierung testen

```bash
# Techniker (nur Install-Gruppe) → chain zu win-install.ipxe
curl -u tech01:Tech01!Pass http://localhost:5000/boot/auth/validate

# Admin (beide Gruppen) → Inline-Menü mit Install + Admin
curl -u admin01:Admin01!Pass http://localhost:5000/boot/auth/validate
# Beim ersten Mal: erstellt iSCSI-Image + zeigt "Erstinstallation"
# Ab dem zweiten Mal: zeigt "Admin-Umgebung starten (iSCSI)"

# iSCSI-Image prüfen
ls -la /srv/netboot/iscsi/
# → admin01.img sollte nach erstem Login existieren (60 GB sparse)
du -sh /srv/netboot/iscsi/admin01.img
# → Tatsächlicher Platzbedarf: nur genutzter Speicher
```

### 7.3 Boot-Test

1. Test-Client VM (ID 210) starten
2. Im iPXE-Menü: `4. Windows (AD-Login erforderlich)` wählen
3. Benutzername + Passwort eingeben
4. WinPE sollte laden und starten

---

## Troubleshooting

### AD nicht erreichbar

```bash
# LDAP-Verbindung testen
ldapsearch -x -H ldap://10.10.0.3 -D "tech01@lab.local" -w "Tech01!Pass" -b "DC=lab,DC=local"

# DNS-Auflösung prüfen
nslookup dc01.lab.local 10.10.0.3
```

### Auth-Backend Fehler

```bash
# Logs prüfen
journalctl -fu netboot-auth

# Manueller Test
cd /opt/netboot-auth
python3 app.py  # Startet im Debug-Modus
```

### iSCSI-Boot schlägt fehl

```bash
# Targets aktiv?
tgtadm --lld iscsi --op show --mode target

# Target für bestimmten User prüfen
tgtadm --lld iscsi --op show --mode target | grep -A5 "admin01"

# Image-Datei vorhanden?
ls -la /srv/netboot/iscsi/admin01.img

# tgt-Config vorhanden?
cat /etc/tgt/conf.d/admin01.conf

# Targets neu laden
tgt-admin --update ALL

# Port 3260 erreichbar?
ss -tlnp | grep 3260
```

### iSCSI-Image zurücksetzen (Neuinstallation erzwingen)

```bash
# Image + Target für einen User löschen
sudo /opt/netboot-auth/iscsi-manage.sh delete admin01
# Beim nächsten Login wird ein neues Image erstellt
```

### WinPE startet nicht

- Prüfen ob alle Files vorhanden: `ls -la /srv/netboot/tftp/winpe/`
- wimboot muss als erstes geladen werden
- BCD und boot.sdi müssen aus dem gleichen WinPE-Build stammen
- boot.wim darf nicht zu groß sein (max ~500 MB für HTTP-Transfer)

### nginx gibt 502 Bad Gateway

```bash
# Flask-Backend läuft?
systemctl status netboot-auth

# Port 5000 belegt?
ss -tlnp | grep 5000
```

### Samba-Share nicht erreichbar (aus WinPE)

```bash
# Samba-Status
smbstatus
testparm

# Firewall-Ports: TCP 445, 139
```

---

## Sicherheitshinweise (Lab!)

- Passwörter sind Klartext in der Doku → nur für Lab-Betrieb!
- HTTP Basic-Auth ist unverschlüsselt → in Produktion HTTPS verwenden
- Flask läuft im Development-Modus → in Produktion gunicorn + HTTPS
- Samba-Share ist read-only, aber ohne Authentifizierung (Guest OK)
- AD-Evaluation läuft 180 Tage

---

## Nächste Schritte (Phase 4+)

- HTTPS für Auth-Backend (Let's Encrypt oder Self-Signed)
- WinPE mit Treiber-Injection für physische Hardware
- Automatische Windows-Installation mit unattend.xml
- Admin-WinPE mit erweiterten Tools (DiskPart, Registry, etc.)
