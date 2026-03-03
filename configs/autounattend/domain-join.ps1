# =============================================================================
# domain-join.ps1 – NABE Domain-Join Script
# =============================================================================
# Wird nach der Windows-Installation automatisch ausgefuehrt (FirstLogonCommand).
# Fragt den Techniker nach AD-Credentials und tritt der Domain bei.
#
# Wird via $OEM$-Distribution automatisch nach C:\NABE\ kopiert.
# =============================================================================

$domain = "lab.local"
$dnsServer = "10.10.0.3"

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  NABE - Domain-Beitritt ($domain)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# --- Schritt 1: DNS auf AD-Server setzen ---
Write-Host "Setze DNS-Server auf $dnsServer ..." -ForegroundColor Yellow
try {
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if ($adapter) {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($dnsServer, "10.10.0.1")
        Write-Host "DNS konfiguriert: $dnsServer (primaer), 10.10.0.1 (fallback)" -ForegroundColor Green
    } else {
        Write-Host "WARNUNG: Kein aktiver Netzwerkadapter gefunden!" -ForegroundColor Red
    }
} catch {
    Write-Host "WARNUNG: DNS-Konfiguration fehlgeschlagen: $_" -ForegroundColor Red
}

# --- Schritt 2: Verbindung zum AD testen ---
Write-Host ""
Write-Host "Teste Verbindung zum AD-Server ($dnsServer) ..." -ForegroundColor Yellow
$ping = Test-Connection -ComputerName $dnsServer -Count 2 -Quiet
if ($ping) {
    Write-Host "AD-Server erreichbar." -ForegroundColor Green
} else {
    Write-Host "WARNUNG: AD-Server nicht erreichbar! Domain-Join koennte fehlschlagen." -ForegroundColor Red
    Write-Host "Trotzdem fortfahren? (Enter = Ja, Strg+C = Abbrechen)" -ForegroundColor Yellow
    Read-Host
}

# --- Schritt 3: Computername festlegen ---
Write-Host ""
$currentName = $env:COMPUTERNAME
Write-Host "Aktueller Computername: $currentName"
$newName = Read-Host "Neuer Computername (leer lassen fuer '$currentName')"
if ([string]::IsNullOrWhiteSpace($newName)) {
    $newName = $null
}

# --- Schritt 4: AD-Credentials abfragen ---
Write-Host ""
Write-Host "Bitte AD-Admin-Anmeldedaten eingeben:" -ForegroundColor Yellow
Write-Host "  (Benutzer mit Recht, PCs zur Domain hinzuzufuegen)" -ForegroundColor Gray
Write-Host "  Format: admin01@lab.local oder LAB\admin01" -ForegroundColor Gray
Write-Host ""
$cred = Get-Credential -Message "AD-Anmeldedaten fuer Domain-Beitritt ($domain)"

if (-not $cred) {
    Write-Host ""
    Write-Host "Domain-Beitritt abgebrochen." -ForegroundColor Red
    Write-Host "Manuell nachholen: Add-Computer -DomainName '$domain' -Credential (Get-Credential) -Restart" -ForegroundColor Gray
    Read-Host "Enter druecken zum Fortfahren"
    exit 1
}

# --- Schritt 5: Domain beitreten ---
Write-Host ""
Write-Host "Trete Domain '$domain' bei..." -ForegroundColor Yellow

try {
    $params = @{
        DomainName = $domain
        Credential = $cred
        Force      = $true
    }
    if ($newName) {
        $params.NewName = $newName
        Write-Host "Computer wird umbenannt zu: $newName"
    }

    Add-Computer @params

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  Domain-Beitritt erfolgreich!" -ForegroundColor Green
    Write-Host "  Domain: $domain" -ForegroundColor Green
    if ($newName) {
        Write-Host "  Computername: $newName" -ForegroundColor Green
    }
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "PC wird in 5 Sekunden neu gestartet..."
    Start-Sleep -Seconds 5
    Restart-Computer -Force

} catch {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Red
    Write-Host "  FEHLER beim Domain-Beitritt!" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Fehlermeldung: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "Moegliche Ursachen:" -ForegroundColor Yellow
    Write-Host "  - Falsches Passwort oder Benutzername"
    Write-Host "  - Benutzer hat keine Rechte fuer Domain-Join"
    Write-Host "  - AD-Server nicht erreichbar (DNS: $dnsServer)"
    Write-Host "  - Domain '$domain' nicht aufloesbar"
    Write-Host ""
    Write-Host "Manuell versuchen:" -ForegroundColor Gray
    Write-Host "  Add-Computer -DomainName '$domain' -Credential (Get-Credential) -Restart" -ForegroundColor Gray
    Write-Host ""
    Read-Host "Enter druecken zum Fortfahren"
    exit 1
}
