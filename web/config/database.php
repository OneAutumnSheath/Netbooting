<?php

return [
    'default' => env('DB_CONNECTION', 'sqlite'),

    'connections' => [
        'sqlite' => [
            'driver'   => 'sqlite',
            'database' => env('DB_DATABASE', database_path('nabe.sqlite')),
            'prefix'   => '',
        ],
    ],

    'migrations' => [
        'table' => 'migrations',
    ],
];
