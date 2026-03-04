<?php

use App\Http\Controllers\AuthController;
use App\Http\Controllers\BootSessionController;
use App\Http\Controllers\DashboardController;
use Illuminate\Support\Facades\Route;

// Dashboard (Kiosk-Browser)
Route::get('/dashboard', [DashboardController::class, 'index']);

// AD-Login (AJAX vom Dashboard)
Route::post('/auth/login', [AuthController::class, 'login']);

// iPXE Session-Abfrage (gibt iPXE-Script oder 404)
Route::get('/boot/session/{mac}', [BootSessionController::class, 'show']);

// Health-Check
Route::get('/health', fn () => response()->json([
    'status'    => 'ok',
    'ad_server' => config('nabe.ad_server'),
    'domain'    => config('nabe.ad_domain'),
]));
