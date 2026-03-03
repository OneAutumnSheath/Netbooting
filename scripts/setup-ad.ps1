# =============================================================================
# setup-ad.ps1 – Active Directory fuer NetBoot vorkonfigurieren
# =============================================================================
# Ausfuehren auf: Windows Server (DC01, 10.10.0.3)
# Als: Domain-Administrator
#
# Was dieses Script macht:
#   1. Prueft/erstellt AD-Gruppen (NetBoot-Install, NetBoot-Admin)
#   2. Erstellt Test-Benutzer (tech01, admin01)
#   3. Weist Benutzer den Gruppen zu
#   4. Konfiguriert DNS-Weiterleitung (an OPNsense / Gateway)
#   5. Erstellt statische DNS-Eintraege (netboot, gw)
# =============================================================================

$ErrorActionPreference = "Continue"

# --- Konfiguration ---
$Domain       = "lab.local"
$BaseDN       = "DC=lab,DC=local"
$NetbootIP    = "10.10.0.2"
$GatewayIP    = "10.10.0.1"

# Gruppen (werden im Root erstellt falls nicht vorhanden)
$GroupInstall = "NetBoot-Install"
$GroupAdmin   = "NetBoot-Admin"

# Test-Benutzer
$Users = @(
    @{
        Name     = "tech01"
        Password = "Tech01!Pass"
        Groups   = @($GroupInstall)
        Desc     = "Techniker - darf Windows installieren"
    },
    @{
        Name     = "admin01"
        Password = "Admin01!Pass"
        Groups   = @($GroupInstall, $GroupAdmin)
        Desc     = "Admin - Installation + iSCSI Admin-Umgebung"
    }
)

# =============================================================================
Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  NABE - Active Directory Setup" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""

# =============================================================================
# Schritt 1: AD-Gruppen pruefen/erstellen
# =============================================================================
Write-Host "[1] AD-Gruppen pruefen..." -ForegroundColor Cyan

foreach ($GroupName in @($GroupInstall, $GroupAdmin)) {
    $existing = Get-ADGroup -Filter "Name -eq '$GroupName'" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "    OK: '$GroupName' existiert bereits ($($existing.DistinguishedName))" -ForegroundColor Yellow
    } else {
        New-ADGroup -Name $GroupName `
            -GroupScope Global `
            -GroupCategory Security `
            -Path $BaseDN `
            -Description "NetBoot-Gruppe: $GroupName"
        Write-Host "    Erstellt: '$GroupName'" -ForegroundColor Green
    }
}

# =============================================================================
# Schritt 2: Test-Benutzer erstellen
# =============================================================================
Write-Host ""
Write-Host "[2] Test-Benutzer erstellen..." -ForegroundColor Cyan

foreach ($User in $Users) {
    $sam = $User.Name
    $existing = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "    OK: '$sam' existiert bereits" -ForegroundColor Yellow
    } else {
        New-ADUser -Name $sam `
            -SamAccountName $sam `
            -UserPrincipalName "$sam@$Domain" `
            -AccountPassword (ConvertTo-SecureString $User.Password -AsPlainText -Force) `
            -Enabled $true `
            -PasswordNeverExpires $true `
            -Path $BaseDN `
            -Description $User.Desc
        Write-Host "    Erstellt: '$sam' (Passwort: $($User.Password))" -ForegroundColor Green
    }

    # Gruppenzuweisungen
    foreach ($GroupName in $User.Groups) {
        $isMember = Get-ADGroupMember -Identity $GroupName -ErrorAction SilentlyContinue |
                    Where-Object { $_.SamAccountName -eq $sam }
        if ($isMember) {
            Write-Host "    OK: '$sam' ist bereits in '$GroupName'" -ForegroundColor Yellow
        } else {
            Add-ADGroupMember -Identity $GroupName -Members $sam
            Write-Host "    Zugewiesen: '$sam' -> '$GroupName'" -ForegroundColor Green
        }
    }
}

# =============================================================================
# Schritt 3: DNS-Weiterleitung konfigurieren
# =============================================================================
Write-Host ""
Write-Host "[3] DNS-Weiterleitung konfigurieren..." -ForegroundColor Cyan

$forwarders = (Get-DnsServerForwarder).IPAddress.IPAddressToString 2>$null
if ($forwarders -contains $GatewayIP) {
    Write-Host "    OK: Weiterleitung an $GatewayIP existiert bereits" -ForegroundColor Yellow
} else {
    Add-DnsServerForwarder -IPAddress $GatewayIP
    Write-Host "    Erstellt: DNS-Weiterleitung an $GatewayIP" -ForegroundColor Green
}

# =============================================================================
# Schritt 4: Statische DNS-Eintraege
# =============================================================================
Write-Host ""
Write-Host "[4] DNS-Eintraege erstellen..." -ForegroundColor Cyan

$dnsRecords = @(
    @{ Name = "netboot"; IP = $NetbootIP },
    @{ Name = "gw";      IP = $GatewayIP }
)

foreach ($rec in $dnsRecords) {
    $existing = Get-DnsServerResourceRecord -ZoneName $Domain -Name $rec.Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "    OK: '$($rec.Name).$Domain' existiert bereits" -ForegroundColor Yellow
    } else {
        Add-DnsServerResourceRecordA -ZoneName $Domain -Name $rec.Name -IPv4Address $rec.IP
        Write-Host "    Erstellt: $($rec.Name).$Domain -> $($rec.IP)" -ForegroundColor Green
    }
}

# =============================================================================
# Zusammenfassung
# =============================================================================
Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Setup abgeschlossen!" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Gruppen:" -ForegroundColor White
Write-Host "    $GroupInstall -> darf Windows installieren"
Write-Host "    $GroupAdmin   -> darf iSCSI Admin-Umgebung nutzen"
Write-Host ""
Write-Host "  Test-Benutzer:" -ForegroundColor White
foreach ($User in $Users) {
    Write-Host "    $($User.Name) / $($User.Password) -> $($User.Groups -join ', ')"
}
Write-Host ""
Write-Host "  DNS:" -ForegroundColor White
Write-Host "    netboot.$Domain -> $NetbootIP"
Write-Host "    gw.$Domain      -> $GatewayIP"
Write-Host "    Weiterleitung   -> $GatewayIP"
Write-Host ""
Write-Host "  Test vom NetBoot-Server:" -ForegroundColor White
Write-Host "    ldapsearch -x -H ldap://10.10.0.3 -D 'tech01@$Domain' -w 'Tech01!Pass' -b '$BaseDN'"
Write-Host "    curl -u tech01:Tech01!Pass http://localhost:5000/boot/auth/validate"
Write-Host ""
