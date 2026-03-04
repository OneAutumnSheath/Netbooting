<?php

namespace App\Services;

use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Process;

/**
 * AD-Authentifizierung via Kerberos (kinit + ldapsearch -Y GSSAPI).
 *
 * Voraussetzungen auf dem Server:
 *   - krb5-user, ldap-utils, libsasl2-modules-gssapi-mit
 *   - /etc/krb5.conf korrekt konfiguriert
 *
 * Flow:
 *   1. kinit --password-stdin user@REALM  → TGT holen
 *   2. ldapsearch -Y GSSAPI              → Gruppen abfragen
 *   3. kdestroy                           → Ticket loeschen
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

        Log::info("AD-Auth: Versuche kinit fuer {$user}");

        // Kerberos TGT holen
        $result = Process::input($password)
            ->run(['kinit', '--password-stdin', $user]);

        if ($result->failed()) {
            Log::warning("AD-Auth: kinit fehlgeschlagen fuer {$user}", [
                'stderr' => $result->errorOutput(),
            ]);
            return null;
        }

        Log::info("AD-Auth: kinit erfolgreich fuer {$user}");

        // Gruppen via LDAP/GSSAPI abfragen
        $ldapResult = Process::run([
            'ldapsearch', '-Y', 'GSSAPI', '-Q',
            '-H', 'ldap://' . config('nabe.ad_server'),
            '-b', config('nabe.ad_base_dn'),
            "(sAMAccountName={$username})",
            'memberOf',
        ]);

        $groups = $this->parseMemberOf($ldapResult->output());

        Log::info("AD-Auth: Gruppen fuer {$username}", ['groups' => $groups]);

        // Kerberos-Ticket aufraeumen
        Process::run(['kdestroy']);

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
