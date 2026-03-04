<?php

namespace App\Services;

use App\Models\BootSession;

/**
 * Generiert iPXE-Scripts basierend auf Boot-Sessions.
 *
 * Portiert die Logik aus dem bisherigen Python-Backend (app.py).
 */
class IpxeScriptService
{
    private string $serverIp;
    private string $iqnPrefix;

    public function __construct()
    {
        $this->serverIp  = config('nabe.server_ip');
        $this->iqnPrefix = config('nabe.iscsi_iqn_prefix');
    }

    /**
     * Generiert das iPXE-Script fuer eine aktive Boot-Session.
     */
    public function generateForSession(BootSession $session): string
    {
        return match ($session->action) {
            'install'       => $this->installScript(),
            'hbcd'          => $this->hbcdScript(),
            'admin-boot'    => $this->adminBootScript($session->username),
            'admin-install' => $this->adminInstallScript($session->username),
            'localboot'     => $this->localbootScript(),
            default         => $this->errorScript("Unbekannte Aktion: {$session->action}"),
        };
    }

    /**
     * Windows 11 Installation (WinPE auf lokale Platte).
     */
    public function installScript(): string
    {
        return <<<IPXE
        #!ipxe
        echo
        echo ============================================
        echo   Support-Tools - Windows 11 Installation
        echo ============================================
        echo
        echo Lade WinPE-Komponenten via HTTP...
        kernel http://{$this->serverIp}/boot/winpe/wimboot || goto fail
        initrd --name bcd http://{$this->serverIp}/boot/winpe/bcd bcd || goto fail
        initrd --name boot.sdi http://{$this->serverIp}/boot/winpe/boot.sdi boot.sdi || goto fail
        initrd --name boot.wim http://{$this->serverIp}/boot/winpe/install-boot.wim boot.wim || goto fail
        boot || goto fail

        :fail
        echo FEHLER: WinPE konnte nicht geladen werden!
        echo Druecke eine Taste...
        prompt
        shell
        IPXE;
    }

    /**
     * HBCD – Hiren's Boot CD PE.
     */
    public function hbcdScript(): string
    {
        return <<<IPXE
        #!ipxe
        echo
        echo ============================================
        echo   Support-Tools - Hiren's Boot CD PE
        echo ============================================
        echo
        echo Lade HBCD-Komponenten via HTTP...
        kernel http://{$this->serverIp}/boot/hbcd/wimboot || goto fail
        initrd --name bcd http://{$this->serverIp}/boot/hbcd/bcd bcd || goto fail
        initrd --name boot.sdi http://{$this->serverIp}/boot/hbcd/boot.sdi boot.sdi || goto fail
        initrd --name boot.wim http://{$this->serverIp}/boot/hbcd/HBCD.wim boot.wim || goto fail
        boot || goto fail

        :fail
        echo FEHLER: HBCD konnte nicht geladen werden!
        echo Druecke eine Taste...
        prompt
        shell
        IPXE;
    }

    /**
     * Admin-Umgebung: iSCSI-Boot (Image existiert).
     */
    public function adminBootScript(string $username): string
    {
        $targetIqn = "{$this->iqnPrefix}:{$username}";

        return <<<IPXE
        #!ipxe
        echo
        echo Starte Admin-Umgebung fuer {$username}...
        echo
        set initiator-iqn iqn.2024-01.local.lab:{$username}
        echo [DEBUG] initiator-iqn: \${initiator-iqn}
        echo [DEBUG] target: {$targetIqn}
        echo [DEBUG] server: {$this->serverIp}
        echo [DEBUG] sanboot iscsi:{$this->serverIp}::3260:1:{$targetIqn}
        echo
        echo Verbinde mit iSCSI-Target...
        sanboot iscsi:{$this->serverIp}::3260:1:{$targetIqn} || goto fail

        :fail
        echo
        echo FEHLER: iSCSI-Boot fehlgeschlagen!
        echo Druecke eine Taste fuer iPXE Shell...
        prompt
        shell
        IPXE;
    }

    /**
     * Admin-Umgebung: Erstinstallation auf iSCSI-Disk.
     */
    public function adminInstallScript(string $username): string
    {
        $targetIqn = "{$this->iqnPrefix}:{$username}";

        return <<<IPXE
        #!ipxe
        echo
        echo ============================================
        echo   Neue Admin-Umgebung fuer {$username}
        echo ============================================
        echo
        set initiator-iqn iqn.2024-01.local.lab:{$username}
        echo [DEBUG] initiator-iqn: \${initiator-iqn}
        echo [DEBUG] target: {$targetIqn}
        echo [DEBUG] sanhook iscsi:{$this->serverIp}::3260:1:{$targetIqn}
        echo
        echo Verbinde iSCSI-Disk (Netzwerk-Festplatte)...
        sanhook iscsi:{$this->serverIp}::3260:1:{$targetIqn} || goto fail
        echo iSCSI-Disk verbunden.
        echo
        echo Lade WinPE fuer Windows-Installation...
        echo Die iSCSI-Disk erscheint als lokale Festplatte.
        echo Bitte Windows darauf installieren!
        echo
        kernel http://{$this->serverIp}/boot/winpe/wimboot || goto fail
        initrd --name bcd http://{$this->serverIp}/boot/winpe/bcd bcd || goto fail
        initrd --name boot.sdi http://{$this->serverIp}/boot/winpe/boot.sdi boot.sdi || goto fail
        initrd --name boot.wim http://{$this->serverIp}/boot/winpe/admin-boot.wim boot.wim || goto fail
        boot || goto fail

        :fail
        echo FEHLER: Admin-Umgebung konnte nicht gestartet werden!
        echo Druecke eine Taste...
        prompt
        shell
        IPXE;
    }

    /**
     * Lokaler Boot (iPXE exit).
     */
    public function localbootScript(): string
    {
        return <<<IPXE
        #!ipxe
        echo Boote von lokaler Festplatte...
        exit 1
        IPXE;
    }

    /**
     * Fehler-Script.
     */
    public function errorScript(string $message): string
    {
        return <<<IPXE
        #!ipxe
        echo FEHLER: {$message}
        echo Druecke eine Taste...
        prompt
        IPXE;
    }
}
