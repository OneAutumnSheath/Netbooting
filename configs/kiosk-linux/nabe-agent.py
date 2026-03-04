#!/usr/bin/env python3
"""
nabe-agent.py – Lokaler HTTP-Agent fuer kexec/reboot im Kiosk-Linux.

Laeuft auf localhost:8080 und nimmt Befehle vom Browser (Dashboard JS) entgegen.
Nur von localhost erreichbar (Sicherheit).

Endpunkte:
    POST /reboot          – Neustart (iPXE bootet erneut)
    POST /poweroff        – Herunterfahren
    POST /kexec           – Kernel via kexec laden und starten
        Body (JSON): {kernel_url, initrd_url, cmdline}

Pfad im Initramfs: /usr/local/bin/nabe-agent.py
"""

import json
import os
import subprocess
import tempfile
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler


class AgentHandler(BaseHTTPRequestHandler):
    """HTTP-Handler fuer lokale Steuerungsbefehle."""

    def do_POST(self):
        if self.path == "/reboot":
            self._respond(200, {"status": "rebooting"})
            os.system("reboot")

        elif self.path == "/poweroff":
            self._respond(200, {"status": "powering off"})
            os.system("poweroff")

        elif self.path == "/kexec":
            body = self._read_body()
            if not body:
                self._respond(400, {"error": "JSON body required"})
                return
            try:
                self._do_kexec(body)
            except Exception as e:
                self._respond(500, {"error": str(e)})

        else:
            self._respond(404, {"error": "not found"})

    def do_GET(self):
        if self.path == "/health":
            self._respond(200, {"status": "ok"})
        else:
            self._respond(404, {"error": "not found"})

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return None
        try:
            return json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, ValueError):
            return None

    def _respond(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def do_OPTIONS(self):
        """CORS preflight fuer fetch() aus dem Browser."""
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def _do_kexec(self, body):
        """Laedt Kernel + Initrd via HTTP und startet per kexec."""
        kernel_url = body.get("kernel_url")
        initrd_url = body.get("initrd_url")
        cmdline = body.get("cmdline", "")

        if not kernel_url:
            self._respond(400, {"error": "kernel_url required"})
            return

        tmpdir = tempfile.mkdtemp(prefix="nabe-kexec-")
        kernel_path = os.path.join(tmpdir, "vmlinuz")
        initrd_path = os.path.join(tmpdir, "initrd.img")

        # Kernel herunterladen
        urllib.request.urlretrieve(kernel_url, kernel_path)

        # kexec-Kommando zusammenbauen
        cmd = ["kexec", "-l", kernel_path]
        if initrd_url:
            urllib.request.urlretrieve(initrd_url, initrd_path)
            cmd += ["--initrd", initrd_path]
        if cmdline:
            cmd += ["--command-line", cmdline]

        # Kernel laden
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            self._respond(500, {"error": f"kexec -l failed: {result.stderr}"})
            return

        self._respond(200, {"status": "kexec loaded, executing..."})

        # kexec ausfuehren (Punkt ohne Wiederkehr)
        os.system("kexec -e")

    def log_message(self, format, *args):
        """Logging auf stderr (journald faengt das auf)."""
        print(f"[nabe-agent] {args[0]} {args[1]} {args[2]}")


def main():
    server = HTTPServer(("127.0.0.1", 8080), AgentHandler)
    print("[nabe-agent] Listening on 127.0.0.1:8080")
    server.serve_forever()


if __name__ == "__main__":
    main()
