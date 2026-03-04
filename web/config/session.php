<?php

return [
    'driver'          => 'file',
    'lifetime'        => 120,
    'expire_on_close' => false,
    'encrypt'         => false,
    'files'           => storage_path('framework/sessions'),
    'cookie'          => 'nabe_session',
    'path'            => '/',
    'domain'          => null,
    'secure'          => false,
    'http_only'       => true,
    'same_site'       => 'lax',
];
