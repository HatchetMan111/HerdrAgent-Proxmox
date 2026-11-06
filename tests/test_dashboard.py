"""Unit tests for the dashboard backend (stdlib only).

Run with:  python3 -m unittest discover -s tests -v
"""

from __future__ import annotations

import importlib.util
import json
import os
import socket
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVER_PATH = ROOT / "dashboard" / "server.py"


def load_server_module():
    os.environ.setdefault("WEB_USER", "herdr")
    os.environ.setdefault("WEB_PW", "test-password")
    spec = importlib.util.spec_from_file_location("herdr_dashboard", SERVER_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class ValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_server_module()

    def test_pane_id_accepts_herdr_ids(self):
        for value in ("w1:p1", "wabc:t12", "pane_1", "term-abc.1"):
            self.assertEqual(self.mod.validate_pane_id(value), value)

    def test_pane_id_rejects_injection(self):
        for value in ("", "w1:p1; rm -rf /", "../etc/passwd", "w1 p1", None, 42):
            with self.assertRaises(ValueError):
                self.mod.validate_pane_id(value)

    def test_text_validation(self):
        self.assertEqual(self.mod.validate_text("hello"), "hello")
        with self.assertRaises(ValueError):
            self.mod.validate_text("   ")
        with self.assertRaises(ValueError):
            self.mod.validate_text("x" * 17, "text", 16)
        with self.assertRaises(ValueError):
            self.mod.validate_text(None)

    def test_unknown_action_is_rejected(self):
        with self.assertRaises(ValueError):
            self.mod.run_action({"action": "server.stop"})

    def test_read_source_whitelist(self):
        self.assertIn("recent", self.mod.READ_SOURCES)
        self.assertNotIn("../../etc/passwd", self.mod.READ_SOURCES)

    def test_static_files_are_whitelisted(self):
        self.assertIn("/", self.mod.STATIC_FILES)
        self.assertNotIn("/../../etc/passwd", self.mod.STATIC_FILES)
        self.assertTrue(all(isinstance(entry, tuple) for entry in self.mod.STATIC_FILES.values()))

    def test_system_stats_shape(self):
        stats = self.mod.system_stats()
        for key in ("hostname", "cpus", "uptime_seconds", "load", "memory", "disk"):
            self.assertIn(key, stats)
        self.assertGreaterEqual(stats["cpus"], 1)
        self.assertGreaterEqual(stats["memory"]["total"], 0)


class RpcTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_server_module()

    def test_roundtrip_over_unix_socket(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "herdr.sock")
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(path)
            server.listen(1)

            def serve():
                conn, _ = server.accept()
                with conn:
                    buffer = b""
                    while b"\n" not in buffer:
                        chunk = conn.recv(4096)
                        if not chunk:
                            return
                        buffer += chunk
                    request = json.loads(buffer.split(b"\n", 1)[0])
                    response = {"id": request["id"], "result": {"type": "pong"}}
                    conn.sendall(json.dumps(response).encode() + b"\n")

            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            original = self.mod.SOCKET_PATH
            self.mod.SOCKET_PATH = path
            try:
                self.assertEqual(self.mod.herdr_rpc("ping"), {"type": "pong"})
            finally:
                self.mod.SOCKET_PATH = original
                server.close()
                thread.join(timeout=2)

    def test_missing_socket_raises_herdr_error(self):
        original = self.mod.SOCKET_PATH
        self.mod.SOCKET_PATH = "/nonexistent/herdr.sock"
        try:
            with self.assertRaises(self.mod.HerdrError) as ctx:
                self.mod.herdr_rpc("ping")
            self.assertEqual(ctx.exception.code, "socket_missing")
        finally:
            self.mod.SOCKET_PATH = original

    def test_error_response_is_raised(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "herdr.sock")
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(path)
            server.listen(1)

            def serve():
                conn, _ = server.accept()
                with conn:
                    buffer = b""
                    while b"\n" not in buffer:
                        chunk = conn.recv(4096)
                        if not chunk:
                            return
                        buffer += chunk
                    request = json.loads(buffer.split(b"\n", 1)[0])
                    response = {
                        "id": request["id"],
                        "error": {"code": "not_found", "message": "pane not found"},
                    }
                    conn.sendall(json.dumps(response).encode() + b"\n")

            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            original = self.mod.SOCKET_PATH
            self.mod.SOCKET_PATH = path
            try:
                with self.assertRaises(self.mod.HerdrError) as ctx:
                    self.mod.herdr_rpc("pane.read", {"pane_id": "nope"})
                self.assertEqual(ctx.exception.code, "not_found")
            finally:
                self.mod.SOCKET_PATH = original
                server.close()
                thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
