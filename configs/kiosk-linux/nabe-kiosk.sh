#!/bin/bash
# =============================================================================
# nabe-kiosk.sh – Firefox Kiosk fuer NABE Dashboard
# =============================================================================
# Pfad im Initramfs: /usr/local/bin/nabe-kiosk.sh
# Wird von nabe-kiosk.service via xinit gestartet.
# Liest die MAC-Adresse und oeffnet das Laravel-Dashboard.
# =============================================================================

# Bildschirmschoner deaktivieren
xset s off
xset -dpms
xset s noblank

# MAC-Adresse auslesen
MAC=$(cat /sys/class/net/eth0/address)

# Firefox ESR im Kiosk-Modus starten
exec firefox-esr --kiosk "http://10.10.0.2/dashboard?mac=${MAC}"
