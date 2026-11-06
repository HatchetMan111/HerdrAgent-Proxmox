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


class LaunchEnvTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_server_module()

    def setUp(self):
        self.saved = {
            name: getattr(self.mod, name, None)
            for name in ("OPENROUTER_API_KEY", "OPENROUTER_BASE_URL", "OPENROUTER_MODEL")
        }

    def tearDown(self):
        for name, value in self.saved.items():
            setattr(self.mod, name, value)

    def test_openrouter_env_from_install_key(self):
        mod = self.mod
        mod.OPENROUTER_API_KEY = "sk-or-install"
        mod.OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"
        mod.OPENROUTER_MODEL = "anthropic/claude-sonnet-4.5"
        env = mod.openrouter_env()
        self.assertEqual(env.get("ANTHROPIC_API_KEY"), "sk-or-install")
        self.assertEqual(env.get("ANTHROPIC_BASE_URL"), "https://openrouter.ai/api/v1")
        self.assertEqual(env.get("ANTHROPIC_MODEL"), "anthropic/claude-sonnet-4.5")

    def test_openrouter_env_empty_without_key(self):
        self.mod.OPENROUTER_API_KEY = ""
        self.assertEqual(self.mod.openrouter_env(), {})

    def test_launch_env_uses_install_key_when_no_request(self):
        self.mod.OPENROUTER_API_KEY = "sk-or-install"
        env = self.mod.launch_env_for({})
        self.assertEqual(env.get("ANTHROPIC_API_KEY"), "sk-or-install")
        self.assertEqual(env.get("ANTHROPIC_BASE_URL"), "https://openrouter.ai/api/v1")

    def test_launch_env_prefers_requested_key(self):
        self.mod.OPENROUTER_API_KEY = "sk-or-install"
        env = self.mod.launch_env_for(
            {"ANTHROPIC_API_KEY": "sk-or-user", "ANTHROPIC_MODEL": "openai/gpt-4o"}
        )
        self.assertEqual(env.get("ANTHROPIC_API_KEY"), "sk-or-user")
        self.assertEqual(env.get("ANTHROPIC_BASE_URL"), "https://openrouter.ai/api/v1")
        self.assertEqual(env.get("ANTHROPIC_MODEL"), "openai/gpt-4o")

    def test_validate_env_rejects_bad_keys_and_limits(self):
        self.assertEqual(self.mod.validate_env(None), {})
        self.assertEqual(self.mod.validate_env({}), {})
        self.assertEqual(
            self.mod.validate_env({"ANTHROPIC_API_KEY": "sk-or-x"}),
            {"ANTHROPIC_API_KEY": "sk-or-x"},
        )
        with self.assertRaises(ValueError):
            self.mod.validate_env({"BAD=KEY": "x"})
        with self.assertRaises(ValueError):
            self.mod.validate_env({"OPENROUTER_API_KEY": ""})
        with self.assertRaises(ValueError):
            self.mod.validate_env({f"K{i}": "v" for i in range(11)})


class ActionEnvTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_server_module()

    def setUp(self):
        self.calls = []
        self.mod.herdr_rpc = lambda method, params=None: (
            self.calls.append((method, params)) or {"ok": True}
        )

    def test_workspace_create_forwards_openrouter_env(self):
        mod = self.mod
        mod.OPENROUTER_API_KEY = "sk-or-install"
        result = mod.run_action({"action": "workspace.create", "label": "test"})
        method, params = self.calls[0]
        self.assertEqual(method, "workspace.create")
        self.assertEqual(params.get("focus"), True)
        self.assertEqual(params.get("env", {}).get("ANTHROPIC_API_KEY"), "sk-or-install")
        self.assertEqual(result, {"ok": True})

    def test_workspace_create_uses_requested_env(self):
        self.calls.clear()
        self.mod.run_action(
            {"action": "workspace.create", "label": "test", "env": {"ANTHROPIC_API_KEY": "sk-or-user"}}
        )
        method, params = self.calls[0]
        self.assertEqual(method, "workspace.create")
        self.assertEqual(params["env"]["ANTHROPIC_API_KEY"], "sk-or-user")

    def test_tab_create_forwards_openrouter_env(self):
        self.calls.clear()
        self.mod.OPENROUTER_API_KEY = "sk-or-install"
        self.mod.run_action({"action": "tab.create"})
        method, params = self.calls[0]
        self.assertEqual(method, "tab.create")
        self.assertEqual(params.get("focus"), True)
        self.assertEqual(params.get("env", {}).get("ANTHROPIC_API_KEY"), "sk-or-install")

    def test_tab_create_rejects_invalid_env(self):
        with self.assertRaises(ValueError):
            self.mod.run_action({"action": "tab.create", "env": {"BAD=KEY": "x"}})

    def test_pane_swap_forwards_source_and_target(self):
        self.calls.clear()
        result = self.mod.run_action(
            {
                "action": "pane.swap",
                "source_pane_id": "w1:p1",
                "target_pane_id": "w1:p2",
            }
        )
        method, params = self.calls[0]
        self.assertEqual(method, "pane.swap")
        self.assertEqual(params.get("source_pane_id"), "w1:p1")
        self.assertEqual(params.get("target_pane_id"), "w1:p2")
        self.assertEqual(result, {"ok": True})

    def test_pane_swap_requires_both_pane_ids(self):
        with self.assertRaises(ValueError):
            self.mod.run_action({"action": "pane.swap", "source_pane_id": "w1:p1"})
        self.calls.clear()
        with self.assertRaises(ValueError):
            self.mod.run_action({"action": "pane.swap", "target_pane_id": "w1:p2"})
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
