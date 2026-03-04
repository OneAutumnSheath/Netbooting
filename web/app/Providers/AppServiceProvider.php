<?php

namespace App\Providers;

use App\Services\ActiveDirectoryService;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        $this->app->singleton(ActiveDirectoryService::class);
    }

    public function boot(): void
    {
        //
    }
}
