<?php

namespace App\Http\Controllers;

use Illuminate\Http\Request;
use Illuminate\Routing\Controller;

class DashboardController extends Controller
{
    /**
     * GET /dashboard?mac=XX:XX:XX:XX:XX:XX
     *
     * Zeigt das Boot-Dashboard fuer den Kiosk-Browser.
     */
    public function index(Request $request)
    {
        $mac = $request->query('mac', '00:00:00:00:00:00');

        return view('dashboard', [
            'mac' => $mac,
        ]);
    }
}
