<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('boot_sessions', function (Blueprint $table) {
            $table->string('mac')->primary();
            $table->string('username');
            $table->json('groups');
            $table->string('action'); // install|hbcd|admin-boot|admin-install|localboot
            $table->string('created_at');
            $table->string('expires_at');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('boot_sessions');
    }
};
