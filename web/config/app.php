<?php

return [
    'name'     => env('APP_NAME', 'Support-Tools'),
    'env'      => env('APP_ENV', 'production'),
    'debug'    => (bool) env('APP_DEBUG', false),
    'url'      => env('APP_URL', 'http://10.10.0.2'),
    'timezone' => 'Europe/Berlin',
    'locale'   => 'de',
    'key'      => env('APP_KEY'),
    'cipher'   => 'AES-256-CBC',

    'providers' => [
        // Laravel
        Illuminate\Auth\AuthServiceProvider::class,
        Illuminate\Cache\CacheServiceProvider::class,
        Illuminate\Database\DatabaseServiceProvider::class,
        Illuminate\Filesystem\FilesystemServiceProvider::class,
        Illuminate\Foundation\Providers\ConsoleSupportServiceProvider::class,
        Illuminate\Foundation\Providers\FoundationServiceProvider::class,
        Illuminate\Hashing\HashServiceProvider::class,
        Illuminate\Pipeline\PipelineServiceProvider::class,
        Illuminate\Queue\QueueServiceProvider::class,
        Illuminate\Routing\RoutingServiceProvider::class,
        Illuminate\Session\SessionServiceProvider::class,
        Illuminate\View\ViewServiceProvider::class,

        // App
        App\Providers\AppServiceProvider::class,
    ],
];
