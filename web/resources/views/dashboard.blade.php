<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Support-Tools – Boot-Manager</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }

        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: #0a1929 url('/img/background.jpg') center/cover no-repeat fixed;
            color: #fff;
            min-height: 100vh;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            padding: 20px;
        }

        .header {
            text-align: center;
            margin-bottom: 40px;
        }
        .header .logo {
            height: 80px;
            margin-bottom: 16px;
            filter: drop-shadow(0 0 20px rgba(131, 243, 143, 0.3));
        }
        .header h1 {
            font-size: 2rem;
            font-weight: 300;
            letter-spacing: 2px;
        }
        .header .subtitle {
            color: rgba(255, 255, 255, 0.5);
            font-size: 0.9rem;
            margin-top: 5px;
        }

        .boot-grid {
            display: grid;
            grid-template-columns: repeat(2, 1fr);
            gap: 20px;
            max-width: 700px;
            width: 100%;
        }

        .boot-card {
            background: rgba(255, 255, 255, 0.06);
            border: 1px solid rgba(255, 255, 255, 0.1);
            border-radius: 12px;
            padding: 30px 20px;
            text-align: center;
            cursor: pointer;
            transition: all 0.3s ease;
            backdrop-filter: blur(8px);
        }
        .boot-card:hover {
            background: rgba(131, 243, 143, 0.08);
            border-color: rgba(131, 243, 143, 0.4);
            transform: translateY(-2px);
            box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
        }
        .boot-card .icon {
            font-size: 2.5rem;
            margin-bottom: 12px;
        }
        .boot-card .title {
            font-size: 1.1rem;
            font-weight: 600;
            margin-bottom: 6px;
        }
        .boot-card .desc {
            font-size: 0.8rem;
            color: rgba(255, 255, 255, 0.5);
        }
        .boot-card .badge {
            display: inline-block;
            margin-top: 10px;
            padding: 2px 10px;
            border-radius: 10px;
            font-size: 0.7rem;
            background: rgba(255, 200, 50, 0.15);
            color: #ffc832;
        }
        .boot-card.no-login .badge {
            background: rgba(131, 243, 143, 0.15);
            color: #83f38f;
        }

        /* Login Modal */
        .modal-overlay {
            display: none;
            position: fixed;
            top: 0; left: 0; right: 0; bottom: 0;
            background: rgba(0, 0, 0, 0.7);
            backdrop-filter: blur(4px);
            z-index: 100;
            align-items: center;
            justify-content: center;
        }
        .modal-overlay.active {
            display: flex;
        }
        .modal {
            background: rgba(10, 25, 41, 0.95);
            border: 1px solid rgba(131, 243, 143, 0.2);
            border-radius: 16px;
            padding: 40px;
            width: 380px;
            max-width: 90vw;
            backdrop-filter: blur(12px);
        }
        .modal h2 {
            font-size: 1.3rem;
            font-weight: 400;
            margin-bottom: 24px;
            text-align: center;
        }
        .modal .form-group {
            margin-bottom: 16px;
        }
        .modal label {
            display: block;
            font-size: 0.85rem;
            color: rgba(255, 255, 255, 0.5);
            margin-bottom: 6px;
        }
        .modal input {
            width: 100%;
            padding: 10px 14px;
            background: rgba(255, 255, 255, 0.06);
            border: 1px solid rgba(255, 255, 255, 0.15);
            border-radius: 8px;
            color: #fff;
            font-size: 1rem;
            outline: none;
        }
        .modal input:focus {
            border-color: rgba(131, 243, 143, 0.5);
        }
        .modal .btn-row {
            display: flex;
            gap: 10px;
            margin-top: 24px;
        }
        .modal .btn {
            flex: 1;
            padding: 12px;
            border: none;
            border-radius: 8px;
            font-size: 1rem;
            cursor: pointer;
            transition: all 0.2s;
        }
        .btn-primary {
            background: #83f38f;
            color: #0a1929;
            font-weight: 600;
        }
        .btn-primary:hover {
            background: #6de07a;
        }
        .btn-primary:disabled {
            background: #555;
            color: #999;
            cursor: not-allowed;
        }
        .btn-cancel {
            background: rgba(255, 255, 255, 0.1);
            color: #ccc;
        }
        .btn-cancel:hover {
            background: rgba(255, 255, 255, 0.15);
        }

        .error-msg {
            color: #ef4444;
            font-size: 0.85rem;
            text-align: center;
            margin-top: 12px;
            min-height: 20px;
        }
        .success-msg {
            color: #83f38f;
            font-size: 0.85rem;
            text-align: center;
            margin-top: 12px;
        }

        .mac-info {
            text-align: center;
            margin-top: 30px;
            font-size: 0.75rem;
            color: rgba(255, 255, 255, 0.25);
        }

        /* Loading spinner */
        .spinner {
            display: none;
            width: 20px;
            height: 20px;
            border: 2px solid rgba(131, 243, 143, 0.3);
            border-top-color: #83f38f;
            border-radius: 50%;
            animation: spin 0.6s linear infinite;
            margin: 0 auto;
        }
        .spinner.active { display: inline-block; }
        @keyframes spin { to { transform: rotate(360deg); } }
    </style>
</head>
<body>
    <div class="header">
        <img src="/img/logo.svg" alt="hast IT" class="logo">
        <h1>Support-Tools</h1>
        <div class="subtitle">Boot-Manager</div>
    </div>

    <div class="boot-grid">
        <div class="boot-card" onclick="bootAction('hbcd')">
            <div class="icon">&#x1F6E0;</div>
            <div class="title">HBCD</div>
            <div class="desc">Hiren's Boot CD PE</div>
            <div class="badge">Login erforderlich</div>
        </div>

        <div class="boot-card" onclick="bootAction('install')">
            <div class="icon">&#x1FA9F;</div>
            <div class="title">Windows 11</div>
            <div class="desc">Neuinstallation auf lokale Platte</div>
            <div class="badge">Login erforderlich</div>
        </div>

        <div class="boot-card no-login" onclick="bootLocal()">
            <div class="icon">&#x1F4BD;</div>
            <div class="title">Lokale Festplatte</div>
            <div class="desc">Vom lokalen Datentraeger booten</div>
            <div class="badge">Kein Login</div>
        </div>

        <div class="boot-card" onclick="bootAction('admin-boot')">
            <div class="icon">&#x1F527;</div>
            <div class="title">Admin-Umgebung</div>
            <div class="desc">Netzwerk-Boot (iSCSI)</div>
            <div class="badge">Login erforderlich</div>
        </div>
    </div>

    <div class="mac-info">MAC: {{ $mac }}</div>

    <!-- Login Modal -->
    <div class="modal-overlay" id="loginModal">
        <div class="modal">
            <h2 id="modalTitle">Anmeldung</h2>
            <form onsubmit="submitLogin(event)">
                <div class="form-group">
                    <label for="username">Benutzername</label>
                    <input type="text" id="username" autocomplete="username" autofocus>
                </div>
                <div class="form-group">
                    <label for="password">Passwort</label>
                    <input type="password" id="password" autocomplete="current-password">
                </div>
                <div class="btn-row">
                    <button type="button" class="btn btn-cancel" onclick="closeModal()">Abbrechen</button>
                    <button type="submit" class="btn btn-primary" id="loginBtn">Anmelden</button>
                </div>
            </form>
            <div class="error-msg" id="errorMsg"></div>
            <div class="success-msg" id="successMsg"></div>
            <div class="spinner" id="spinner"></div>
        </div>
    </div>

    <script>
        const MAC = @json($mac);
        const AGENT_URL = 'http://127.0.0.1:8080';
        let currentAction = null;

        const titles = {
            'hbcd':          'HBCD – Anmeldung',
            'install':       'Windows 11 – Anmeldung',
            'admin-boot':    'Admin-Umgebung – Anmeldung',
            'admin-install': 'Admin (Erstinstallation) – Anmeldung',
        };

        function bootAction(action) {
            currentAction = action;
            document.getElementById('modalTitle').textContent = titles[action] || 'Anmeldung';
            document.getElementById('errorMsg').textContent = '';
            document.getElementById('successMsg').textContent = '';
            document.getElementById('username').value = '';
            document.getElementById('password').value = '';
            document.getElementById('loginModal').classList.add('active');
            document.getElementById('username').focus();
        }

        function closeModal() {
            document.getElementById('loginModal').classList.remove('active');
            currentAction = null;
        }

        function bootLocal() {
            if (!confirm('Vom lokalen Datentraeger booten?\n\nDer Rechner wird neu gestartet.')) return;
            agentReboot();
        }

        async function submitLogin(e) {
            e.preventDefault();
            const btn = document.getElementById('loginBtn');
            const spinner = document.getElementById('spinner');
            const errorMsg = document.getElementById('errorMsg');
            const successMsg = document.getElementById('successMsg');

            const username = document.getElementById('username').value.trim();
            const password = document.getElementById('password').value;

            if (!username || !password) {
                errorMsg.textContent = 'Bitte Benutzername und Passwort eingeben.';
                return;
            }

            btn.disabled = true;
            spinner.classList.add('active');
            errorMsg.textContent = '';
            successMsg.textContent = '';

            try {
                const res = await fetch('/auth/login', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                        'Accept': 'application/json',
                    },
                    body: JSON.stringify({
                        username: username,
                        password: password,
                        mac: MAC,
                        action: currentAction,
                    }),
                });

                const data = await res.json();

                if (data.success) {
                    successMsg.textContent = data.message;
                    // Kurz warten, dann Reboot ausloesen
                    setTimeout(() => agentReboot(), 2000);
                } else {
                    errorMsg.textContent = data.message || 'Anmeldung fehlgeschlagen.';
                }
            } catch (err) {
                errorMsg.textContent = 'Verbindung zum Server fehlgeschlagen.';
            } finally {
                btn.disabled = false;
                spinner.classList.remove('active');
            }
        }

        async function agentReboot() {
            try {
                await fetch(AGENT_URL + '/reboot', { method: 'POST' });
            } catch (e) {
                // Agent nicht erreichbar – Fallback-Hinweis
                alert('Neustart konnte nicht ausgeloest werden.\nBitte manuell neu starten.');
            }
        }

        // ESC schliesst Modal
        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape') closeModal();
        });
    </script>
</body>
</html>
