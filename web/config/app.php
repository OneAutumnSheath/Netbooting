<?php

return [
    'name'            => env('APP_NAME', 'Support-Tools'),
    'env'             => env('APP_ENV', 'production'),
    'debug'           => (bool) env('APP_DEBUG', false),
    'url'             => env('APP_URL', 'http://10.10.0.2'),
    'timezone'        => 'Europe/Berlin',
    'locale'          => 'de',
    'fallback_locale' => 'en',
    'key'             => env('APP_KEY'),
    'cipher'          => 'AES-256-CBC',
    'maintenance'     => ['driver' => 'file'],

    'providers' => \Illuminate\Support\ServiceProvider::defaultProviders()->merge([
        App\Providers\AppServiceProvider::class,
    ])->toArray(),
];
