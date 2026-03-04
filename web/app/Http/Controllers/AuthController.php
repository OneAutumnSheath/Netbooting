<?php

namespace App\Http\Controllers;

use App\Models\BootSession;
use App\Services\ActiveDirectoryService;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Routing\Controller;
use Illuminate\Support\Facades\Log;

class AuthController extends Controller
{
    public function __construct(
        private ActiveDirectoryService $adService,
    ) {}

    /**
     * POST /auth/login
     *
     * AD-Login via Kerberos. Erstellt eine Boot-Session.
     * Body: {username, password, mac, action}
     */
    public function login(Request $request): JsonResponse
    {
        $request->validate([
            'username' => 'required|string|max:100',
            'password' => 'required|string',
            'mac'      => 'required|string|regex:/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i',
            'action'   => 'required|string|in:install,hbcd,admin-boot,admin-install',
        ]);

        $username = $request->input('username');
        $password = $request->input('password');
        $mac      = strtolower($request->input('mac'));
        $action   = $request->input('action');

        // AD-Authentifizierung
        $authResult = $this->adService->authenticate($username, $password);

        if ($authResult === null) {
            return response()->json([
                'success' => false,
                'message' => 'Anmeldung fehlgeschlagen. Benutzername oder Passwort falsch.',
            ], 401);
        }

        $groups = $authResult['groups'];

        // Gruppen-Berechtigung pruefen
        $groupInstall = config('nabe.group_install');
        $groupAdmin   = config('nabe.group_admin');
        $isInstall    = in_array($groupInstall, $groups);
        $isAdmin      = in_array($groupAdmin, $groups);

        // Berechtigungs-Check je nach Aktion
        if (in_array($action, ['install', 'hbcd']) && ! $isInstall) {
            return response()->json([
                'success' => false,
                'message' => "Keine Berechtigung. Gruppe '{$groupInstall}' erforderlich.",
            ], 403);
        }

        if (in_array($action, ['admin-boot', 'admin-install']) && ! $isAdmin) {
            return response()->json([
                'success' => false,
                'message' => "Keine Berechtigung. Gruppe '{$groupAdmin}' erforderlich.",
            ], 403);
        }

        // Admin: iSCSI-Target pruefen/erstellen
        if ($action === 'admin-boot') {
            if (! $this->iscsiImageExists($username)) {
                // Kein Image → Frontend fragen ob eins erstellt werden soll
                return response()->json([
                    'success'      => false,
                    'needs_create' => true,
                    'message'      => "Keine Admin-Umgebung fuer '{$username}' vorhanden.",
                ]);
            }
        }

        if ($action === 'admin-install') {
            $created = $this->ensureIscsiTarget($username);
            if (! $created) {
                return response()->json([
                    'success' => false,
                    'message' => 'iSCSI-Target konnte nicht erstellt werden.',
                ], 500);
            }
        }

        // Boot-Session erstellen
        BootSession::createOrUpdate($mac, $username, $groups, $action);

        Log::info("Boot-Session erstellt", [
            'mac' => $mac, 'username' => $username,
            'action' => $action, 'groups' => $groups,
        ]);

        return response()->json([
            'success' => true,
            'message' => 'Anmeldung erfolgreich. Bitte Rechner neu starten.',
            'action'  => $action,
        ]);
    }

    private function iscsiImageExists(string $username): bool
    {
        $script = config('nabe.iscsi_manage');
        $result = \Illuminate\Support\Facades\Process::run(
            ['sudo', $script, 'exists', $username]
        );

        return trim($result->output()) === 'true';
    }

    private function ensureIscsiTarget(string $username): bool
    {
        if ($this->iscsiImageExists($username)) {
            return true;
        }

        $script = config('nabe.iscsi_manage');
        $result = \Illuminate\Support\Facades\Process::run(
            ['sudo', $script, 'create', $username]
        );

        if ($result->failed()) {
            Log::error("iSCSI-Target Erstellung fehlgeschlagen", [
                'username' => $username,
                'stderr'   => $result->errorOutput(),
            ]);
            return false;
        }

        return true;
    }
}
