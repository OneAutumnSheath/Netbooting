<?php

namespace App\Http\Controllers;

use App\Models\BootSession;
use App\Services\IpxeScriptService;
use Illuminate\Http\Response;
use Illuminate\Routing\Controller;

class BootSessionController extends Controller
{
    public function __construct(
        private IpxeScriptService $ipxeService,
    ) {}

    /**
     * GET /boot/session/{mac}
     *
     * iPXE ruft diese URL auf. Wenn eine aktive Session existiert,
     * wird das passende iPXE-Script zurueckgegeben.
     * Ohne Session: HTTP 404 → iPXE laedt stattdessen Kiosk-Linux.
     */
    public function show(string $mac): Response
    {
        // MAC-Adresse normalisieren (iPXE sendet mit Doppelpunkten)
        $mac = strtolower(str_replace('-', ':', $mac));

        $session = BootSession::findActive($mac);

        if (! $session) {
            // Keine Session → iPXE soll Kiosk-Linux laden
            return response('No active session', 404);
        }

        $script = $this->ipxeService->generateForSession($session);

        // Session nach einmaligem Abruf loeschen (one-shot)
        $session->delete();

        return response($script, 200)
            ->header('Content-Type', 'text/plain; charset=utf-8');
    }
}
