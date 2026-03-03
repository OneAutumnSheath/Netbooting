# WinPE Build-Anleitung

## Übersicht

Diese Anleitung beschreibt, wie ein WinPE-Image (Windows Preinstallation
Environment) auf einem Windows-Rechner gebaut wird.

Es wird **ein** WinPE-Image (`install-boot.wim`) erstellt, das für beide
Szenarien verwendet wird:

1. **Windows 11 Installation** – WinPE mountet Samba-Share, startet setup.exe
   auf die lokale Platte
2. **Admin-Erstinstallation** – WinPE installiert Windows auf eine iSCSI-Disk
   (Netzwerk-Festplatte), die iPXE vorher via `sanhook` verbunden hat

Zusätzlich werden `BCD` und `boot.sdi` extrahiert, die iPXE zum Booten braucht.

> **Warum nur ein Image?** Die iSCSI-Disk erscheint in WinPE als normale
> Festplatte (dank iPXE sanhook + iBFT). Der Techniker wählt im Windows-Setup
> einfach die richtige Disk aus. Keine separaten WinPE-Varianten nötig.

## Voraussetzungen

- Windows 11/11 Rechner (physisch oder VM)
- Administratorrechte
- Ca. 10 GB freier Speicherplatz
- Netzwerkzugriff zum NetBoot-Server (10.10.0.2)

---

## Schritt 1: Windows ADK installieren

### 1.1 ADK herunterladen

- **Windows ADK:** https://learn.microsoft.com/de-de/windows-hardware/get-started/adk-install
- **WinPE Add-on:** Wird im ADK-Installer als separates Add-on angeboten

### 1.2 Installation

1. `adksetup.exe` starten
2. Feature auswählen: **Bereitstellungstools** (Deployment Tools)
3. Installation abschließen
4. WinPE Add-on Installer starten
5. Feature auswählen: **Windows-Vorinstallationsumgebung** (Windows PE)
6. Installation abschließen

---

## Schritt 2: WinPE-Arbeitsumgebung erstellen

Alle folgenden Befehle in der **Deployment and Imaging Tools Environment**
ausführen (Start → "Deployment" suchen → Als Administrator ausführen).

```cmd
:: Arbeitsverzeichnis erstellen
copype amd64 C:\WinPE_amd64
```

Dies erstellt:
```
C:\WinPE_amd64\
├── media\
│   ├── Boot\
│   │   ├── BCD          ← wird für iPXE benötigt
│   │   └── boot.sdi     ← wird für iPXE benötigt
│   └── sources\
│       └── boot.wim     ← WinPE-Image (Basis)
├── mount\               ← Hier wird das WIM gemountet
└── fwfiles\
```

---

## Schritt 3: WinPE-Image bauen

### 3.1 Basis-WIM kopieren

```cmd
:: Arbeitskopie erstellen
copy C:\WinPE_amd64\media\sources\boot.wim C:\WinPE_amd64\install-boot.wim
```

### 3.2 WIM mounten und Pakete hinzufügen

```cmd
:: WIM mounten
Dism /Mount-Image /ImageFile:C:\WinPE_amd64\install-boot.wim /Index:1 /MountDir:C:\WinPE_amd64\mount
```

Benötigte Pakete hinzufügen:

```cmd
set WINPE_OCS="C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs"

:: WMI (fuer Systemabfragen)
Dism /Image:C:\WinPE_amd64\mount /Add-Package /PackagePath:%WINPE_OCS%\WinPE-WMI.cab
Dism /Image:C:\WinPE_amd64\mount /Add-Package /PackagePath:%WINPE_OCS%\de-de\WinPE-WMI_de-de.cab

:: Scripting (fuer erweiterte Batch/VBS)
Dism /Image:C:\WinPE_amd64\mount /Add-Package /PackagePath:%WINPE_OCS%\WinPE-Scripting.cab

:: Wichtig: iSCSI-Unterstuetzung (fuer Admin-Disk via Netzwerk)
:: Damit WinPE die iSCSI-Disk erkennt, die iPXE via sanhook verbunden hat
Dism /Image:C:\WinPE_amd64\mount /Add-Package /PackagePath:%WINPE_OCS%\WinPE-iSCSI-WMI.cab
```

### 3.3 startnet.cmd anpassen

Die Datei `C:\WinPE_amd64\mount\Windows\System32\startnet.cmd` bearbeiten:

```cmd
wpeinit
echo.
echo ============================================
echo   NABE - Windows Netzwerk-Boot
echo ============================================
echo.
echo Netzwerk wird konfiguriert...
ping -n 5 127.0.0.1 >nul

echo.
echo Verfuegbare Festplatten:
echo list disk | diskpart
echo.

echo Verbinde mit Installationsserver...
net use Z: \\10.10.0.2\win11 /user:guest ""
if errorlevel 1 (
    echo WARNUNG: Samba-Verbindung fehlgeschlagen.
    echo Manuell verbinden: net use Z: \\10.10.0.2\win11 /user:guest ""
) else (
    echo Installationsdateien verfuegbar auf Z:\
)

echo.
echo ============================================
echo   Optionen:
echo     1) Automatische Installation (mit autounattend + Domain-Join)
echo     2) Manuelle Installation
echo     3) Kommandozeile
echo ============================================
echo.
echo Hinweis: Falls eine iSCSI-Disk verbunden ist,
echo erscheint sie als zusaetzliche Festplatte.
echo.
set /p CHOICE="Auswahl (1/2/3): "
if "%CHOICE%"=="1" (
    echo Starte automatische Installation...
    Z:\setup.exe /unattend:Z:\autounattend.xml
) else if "%CHOICE%"=="2" (
    echo Starte manuelle Installation...
    Z:\setup.exe
) else (
    echo Kommandozeile. Tippe 'exit' zum Beenden.
    cmd /k
)
```

> **Hinweis:** Das startnet.cmd öffnet eine Kommandozeile statt direkt
> setup.exe zu starten. So kann der Techniker bei der Admin-Erstinstallation
> zuerst die iSCSI-Disk prüfen und dann manuell setup.exe starten.

### 3.4 WIM unmounten und speichern

```cmd
Dism /Unmount-Image /MountDir:C:\WinPE_amd64\mount /Commit
```

---

## Schritt 4: BCD und boot.sdi extrahieren

Die Dateien liegen bereits in der WinPE-Arbeitsumgebung:

```
C:\WinPE_amd64\media\Boot\BCD        → bcd
C:\WinPE_amd64\media\Boot\boot.sdi   → boot.sdi
```

---

## Schritt 5: Dateien auf NetBoot-Server hochladen

### 5.1 Per SCP (empfohlen)

Voraussetzung: SSH-Client (in Windows 11/11 eingebaut) und SSH-Zugang zum Server.

```cmd
:: BCD und boot.sdi
scp C:\WinPE_amd64\media\Boot\BCD root@10.10.0.2:/srv/netboot/tftp/winpe/bcd
scp C:\WinPE_amd64\media\Boot\boot.sdi root@10.10.0.2:/srv/netboot/tftp/winpe/boot.sdi

:: WinPE-Image
scp C:\WinPE_amd64\install-boot.wim root@10.10.0.2:/srv/netboot/tftp/winpe/install-boot.wim
```

### 5.2 Alternativ: Per Samba-Share oder USB-Stick

Falls SCP nicht verfügbar.

---

## Schritt 6: Berechtigungen auf dem Server korrigieren

Nach dem Upload auf dem NetBoot-Server:

```bash
sudo chown -R dnsmasq:nogroup /srv/netboot/tftp/winpe/
sudo chmod 644 /srv/netboot/tftp/winpe/*
```

---

## Verifikation

### Dateien vorhanden?

```bash
ls -la /srv/netboot/tftp/winpe/
# Erwartete Dateien:
#   wimboot          (~200 KB, vom Setup-Script heruntergeladen)
#   bcd              (~256 KB)
#   boot.sdi         (~3.1 MB)
#   install-boot.wim (~200-400 MB)
```

### Größen prüfen

- `wimboot` sollte ca. 200 KB sein
- `bcd` sollte ca. 256 KB sein
- `boot.sdi` sollte ca. 3 MB sein
- `install-boot.wim` sollte 200–500 MB sein (nicht größer als ~500 MB für
  zuverlässigen HTTP-Transfer)

---

## Troubleshooting

### Dism-Fehler "Zugriff verweigert"

→ Deployment Tools Environment als Administrator starten.

### WIM zu groß (>500 MB)

Weniger Pakete hinzufügen oder WIM komprimieren:

```cmd
Dism /Export-Image /SourceImageFile:C:\WinPE_amd64\install-boot.wim /SourceIndex:1 /DestinationImageFile:C:\WinPE_amd64\install-boot-compressed.wim /Compress:max
```

### Netzwerk funktioniert nicht in WinPE

- VirtIO-Treiber werden nicht standardmäßig unterstützt
- In Proxmox VM-Netzwerk auf **E1000** oder **Intel E1000e** umstellen
- Alternativ: VirtIO-Treiber in WinPE einbinden:

```cmd
:: VirtIO-Treiber zum gemounteten WIM hinzufügen
Dism /Image:C:\WinPE_amd64\mount /Add-Driver /Driver:C:\virtio-win\NetKVM\w10\amd64 /Recurse
```

### iSCSI-Disk wird in WinPE nicht angezeigt

Die iSCSI-Disk wird über iPXE's `sanhook` + iBFT (iSCSI Boot Firmware Table)
an WinPE übergeben. Voraussetzungen:

1. WinPE muss das `WinPE-iSCSI-WMI` Paket enthalten (siehe Schritt 3.2)
2. iPXE muss `sanhook` erfolgreich ausgeführt haben
3. Nach `wpeinit` etwas warten (5 Sek.), damit die iSCSI-Verbindung steht

Falls die Disk trotzdem nicht erscheint:

```cmd
:: iSCSI-Initiator manuell starten
net start msiscsi

:: Verbundene Targets anzeigen
iscsicli ListTargets
iscsicli SessionList

:: Manuell verbinden (falls iBFT nicht klappt)
iscsicli LoginTarget iqn.2024-01.local.lab.netboot:BENUTZERNAME T 10.10.0.2 3260 * * * * * * * * * * * 0
```

### BCD-Fehler beim Booten

Die BCD-Datei muss zum WinPE-Build passen. Beide müssen aus dem gleichen
`copype`-Arbeitsverzeichnis stammen.
