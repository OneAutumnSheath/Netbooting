<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

/**
 * Boot-Session: Speichert die Boot-Auswahl eines Clients (nach Login).
 *
 * iPXE fragt /boot/session/{mac} ab. Wenn eine aktive Session existiert,
 * wird das passende iPXE-Script zurueckgegeben.
 *
 * @property string $mac        MAC-Adresse (Primary Key)
 * @property string $username   AD-Benutzername
 * @property array  $groups     AD-Gruppen (JSON)
 * @property string $action     Boot-Aktion: install|hbcd|admin-boot|admin-install|localboot
 * @property string $created_at
 * @property string $expires_at
 */
class BootSession extends Model
{
    protected $table = 'boot_sessions';

    protected $primaryKey = 'mac';

    public $incrementing = false;

    protected $keyType = 'string';

    public $timestamps = false;

    protected $fillable = [
        'mac',
        'username',
        'groups',
        'action',
        'created_at',
        'expires_at',
    ];

    protected $casts = [
        'groups' => 'array',
    ];

    /**
     * Prueft ob die Session noch gueltig ist.
     */
    public function isValid(): bool
    {
        return $this->expires_at > now()->toDateTimeString();
    }

    /**
     * Findet eine aktive (nicht abgelaufene) Session fuer eine MAC-Adresse.
     */
    public static function findActive(string $mac): ?self
    {
        $session = static::find($mac);

        if ($session && $session->isValid()) {
            return $session;
        }

        // Abgelaufene Session aufraeumen
        if ($session) {
            $session->delete();
        }

        return null;
    }

    /**
     * Erstellt oder aktualisiert eine Boot-Session.
     */
    public static function createOrUpdate(
        string $mac,
        string $username,
        array $groups,
        string $action,
    ): self {
        $timeout = (int) config('nabe.session_timeout', 5);

        return static::updateOrCreate(
            ['mac' => $mac],
            [
                'username'   => $username,
                'groups'     => $groups,
                'action'     => $action,
                'created_at' => now()->toDateTimeString(),
                'expires_at' => now()->addMinutes($timeout)->toDateTimeString(),
            ]
        );
    }
}
