#!/usr/bin/env python3
import json
import os
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from board_control import BoardControlTokenError, control_token  # noqa: E402


HELPER = Path(__file__).resolve().parents[1] / "lib" / "board_control.py"


class _BootstrapHandler(BaseHTTPRequestHandler):
    token = "bootstrap-token"

    def do_GET(self):
        if self.path != "/api/control/bootstrap":
            self.send_error(404)
            return
        body = json.dumps({"controlToken": self.token}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        pass


class BoardControlTokenSmokeTests(unittest.TestCase):
    def test_reads_mode_0600_runtime_info_for_same_loopback_port(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "board-server.json"
            path.write_text(json.dumps({
                "url": "http://127.0.0.1:9912",
                "controlToken": "runtime-token",
            }), encoding="utf-8")
            path.chmod(stat.S_IRUSR | stat.S_IWUSR)
            self.assertEqual(
                control_token("http://localhost:9912", info_path=path),
                "runtime-token",
            )

    def test_cli_prints_curl_compatible_header(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "board-server.json"
            path.write_text(json.dumps({
                "url": "http://127.0.0.1:9912",
                "controlToken": "runtime-token",
            }), encoding="utf-8")
            path.chmod(0o600)
            result = subprocess.run(
                [
                    sys.executable,
                    str(HELPER),
                    "--base-url",
                    "http://127.0.0.1:9912",
                    "--runtime-info",
                    str(path),
                    "--header",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.stdout.strip(), "X-Meee2-Control-Token: runtime-token")

    def test_falls_back_to_bootstrap_when_runtime_info_is_absent(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), _BootstrapHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            missing = Path(tempfile.gettempdir()) / f"missing-board-info-{os.getpid()}.json"
            self.assertEqual(
                control_token(f"http://127.0.0.1:{server.server_port}", info_path=missing),
                "bootstrap-token",
            )
        finally:
            server.shutdown()
            server.server_close()

    def test_refuses_runtime_info_readable_by_group_or_world(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "board-server.json"
            path.write_text(json.dumps({
                "url": "http://127.0.0.1:9912",
                "controlToken": "unsafe-token",
            }), encoding="utf-8")
            path.chmod(0o644)
            with self.assertRaises(BoardControlTokenError):
                control_token("http://127.0.0.1:9912", info_path=path)


if __name__ == "__main__":
    unittest.main()
