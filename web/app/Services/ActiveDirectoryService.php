<?php

namespace App\Services;

use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Process;
use Illuminate\Support\Str;

/**
 * AD-Authentifizierung via Kerberos (kinit + ldapsearch -Y GSSAPI).
 *
 * Voraussetzungen auf dem Server:
 *   - krb5-user, ldap-utils, libsasl2-modules-gssapi-mit
 *   - /etc/krb5.conf korrekt konfiguriert
 *
 * Flow:
 *   1. kinit user@REALM (Passwort via stdin) → TGT holen
 *   2. ldapsearch -Y GSSAPI                  → Gruppen abfragen
 *   3. kdestroy                               → Ticket loeschen
 *
 * Jeder Request nutzt einen eigenen Kerberos-Cache (KRB5CCNAME),
 * damit parallele Requests sich nicht in die Quere kommen.
 */
class ActiveDirectoryService
{
    /**
     * Authentifiziert einen Benutzer gegen AD und gibt Gruppen zurueck.
     *
     * @return array{username: string, groups: string[]}|null
     */
    public function authenticate(string $username, string $password): ?array
    {
        $realm = strtoupper(config('nabe.ad_domain'));
        $user = "{$username}@{$realm}";

        // Eindeutiger Kerberos-Cache pro Request (Race-Condition-sicher)
        $ccache = '/tmp/krb5cc_nabe_' . Str::random(12);
        $env = ['KRB5CCNAME' => $ccache];

        Log::info("AD-Auth: Versuche kinit fuer {$user}", ['ccache' => $ccache]);

        try {
            return $this->doAuthenticate($user, $username, $password, $env);
        } finally {
            // Kerberos-Ticket immer aufraeumen
            Process::env($env)->run(['kdestroy']);
            @unlink($ccache);
        }
    }

    private function doAuthenticate(string $user, string $username, string $password, array $env): ?array
    {
        // Kerberos TGT holen (MIT kinit liest Passwort von stdin)
        $result = Process::env($env)
            ->input("{$password}\n")
            ->timeout(10)
            ->run(['kinit', $user]);

        if ($result->failed()) {
            Log::warning("AD-Auth: kinit fehlgeschlagen fuer {$user}", [
                'exit_code' => $result->exitCode(),
                'stderr'    => $result->errorOutput(),
            ]);
            return null;
        }

        Log::info("AD-Auth: kinit erfolgreich fuer {$user}");

        // Gruppen via LDAP/GSSAPI abfragen
        $ldapResult = Process::env($env)
            ->timeout(10)
            ->run([
                'ldapsearch', '-Y', 'GSSAPI', '-Q',
                '-H', 'ldap://' . config('nabe.ad_server'),
                '-b', config('nabe.ad_base_dn'),
                "(sAMAccountName={$username})",
                'memberOf',
            ]);

        Log::info("AD-Auth: ldapsearch output", [
            'exit_code' => $ldapResult->exitCode(),
            'stdout'    => $ldapResult->output(),
            'stderr'    => $ldapResult->errorOutput(),
        ]);

        $groups = $this->parseMemberOf($ldapResult->output());

        Log::info("AD-Auth: Gruppen fuer {$username}", ['groups' => $groups]);

        return [
            'username' => $username,
            'groups'   => $groups,
        ];
    }

    /**
     * Parst memberOf-Attribute aus ldapsearch-Output.
     *
     * @return string[]
     */
    private function parseMemberOf(string $output): array
    {
        $groups = [];

        foreach (explode("\n", $output) as $line) {
            if (! str_starts_with($line, 'memberOf:')) {
                continue;
            }

            $dn = trim(substr($line, strlen('memberOf:')));

            foreach (explode(',', $dn) as $part) {
                $part = trim($part);
                if (stripos($part, 'CN=') === 0) {
                    $groups[] = substr($part, 3);
                    break;
                }
            }
        }

        return $groups;
    }
}
