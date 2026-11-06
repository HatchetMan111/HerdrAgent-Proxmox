#!/usr/bin/env python3
"""
herdr web dashboard
===================

A dependency-free dashboard for a headless herdr server. It talks to the
herdr socket API (newline-delimited JSON over a Unix socket) and serves a
small single-page UI plus a read-only JSON API.

Why not herdr-app? herdr-app is a native desktop client (GPUI/Vulkan), so it
cannot be served from a headless LXC. This dashboard covers the browser case;
herdr-app can still connect to the same server as an SSH machine.

Configuration is read from the environment (systemd EnvironmentFile):
  WEB_USER / WEB_PW        basic-auth credentials (required)
  DASH_PORT                listen port (default 8080)
  DASH_HOST                listen address (default 0.0.0.0)
  WEB_PORT                 ttyd port, used for the "open terminal" link
  HERDR_BIN                herdr binary path
  HERDR_SOCKET_PATH        alternative socket path
  OPENROUTER_API_KEY       optional install-time OpenRouter API key
  OPENROUTER_BASE_URL      optional OpenRouter base URL (default https://openrouter.ai/api/v1)
  OPENROUTER_MODEL          optional OpenRouter model (ANTHROPIC_MODEL)

Only Python's standard library is used.
"""

from __future__ import annotations

import base64
import itertools
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

APP_VERSION = "1.0.0"
APP_DIR = os.path.dirname(os.path.abspath(__file__))
STATIC_DIR = os.path.join(APP_DIR, "static")

HOST = os.environ.get("DASH_HOST", "0.0.0.0")
PORT = int(os.environ.get("DASH_PORT") or 8080)
WEB_USER = os.environ.get("WEB_USER", "herdr")
WEB_PW = os.environ.get("WEB_PW", "")
TTYD_PORT = int(os.environ.get("WEB_PORT") or 7681)

HERDR_BIN = os.environ.get("HERDR_BIN", "/usr/local/bin/herdr")
HERDR_HOME = os.environ.get("HERDR_HOME") or os.path.join(
    os.path.expanduser("~"), ".config", "herdr"
)
SOCKET_PATH = os.environ.get("HERDR_SOCKET_PATH") or os.path.join(
    HERDR_HOME, "herdr.sock"
)

OPENROUTER_API_KEY = os.environ.get("OPENROUTER_API_KEY") or ""
OPENROUTER_BASE_URL = os.environ.get("OPENROUTER_BASE_URL") or "https://openrouter.ai/api/v1"
OPENROUTER_MODEL = os.environ.get("OPENROUTER_MODEL") or ""
ENV_KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]{0,63}$")
ENV_VALUE_MAX_CHARS = 512
ENV_MAX_KEYS = 10

MAX_BODY_BYTES = 64 * 1024
MAX_READ_LINES = 500
MAX_RESPONSE_BYTES = 4 * 1024 * 1024

PANE_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,64}$")
READ_SOURCES = {"visible", "recent", "recent_unwrapped", "detection"}

# Static files are whitelisted; the dashboard never serves arbitrary paths.
STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/static/styles.css": ("styles.css", "text/css; charset=utf-8"),
    "/static/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/favicon.svg": ("favicon.svg", "image/svg+xml"),
}

SERVICE_NAMES = ("herdr", "ttyd", "herdr-dashboard")

_rpc_ids = itertools.count(1)
_service_cache_lock = threading.Lock()
_service_cache: dict[str, tuple[float, str]] = {}
_version_cache_lock = threading.Lock()
_version_cache: tuple[float, str | None] | None = None


class HerdrError(Exception):
    """An error returned by herdr or by the socket transport."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def herdr_rpc(method: str, params: dict | None = None, timeout: float = 10.0):
    """Send one request to the herdr socket and return the result object."""
    request_id = f"dashboard-{next(_rpc_ids)}"
    payload = (
        json.dumps(
            {"id": request_id, "method": method, "params": params or {}},
            separators=(",", ":"),
            ensure_ascii=False,
        ).encode("utf-8")
        + b"\n"
    )

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect(SOCKET_PATH)
        sock.sendall(payload)
        buffer = bytearray()
        while b"\n" not in buffer:
            chunk = sock.recv(65536)
            if not chunk:
                raise HerdrError(
                    "connection_closed",
                    "herdr closed the socket before answering",
                )
            buffer.extend(chunk)
            if len(buffer) > MAX_RESPONSE_BYTES:
                raise HerdrError(
                    "response_too_large",
                    "herdr response exceeded the size limit",
                )
    except FileNotFoundError as exc:
        raise HerdrError(
            "socket_missing",
            f"herdr socket not found at {SOCKET_PATH}",
        ) from exc
    except (ConnectionRefusedError, ConnectionResetError) as exc:
        raise HerdrError(
            "socket_unreachable",
            f"cannot connect to herdr at {SOCKET_PATH}",
        ) from exc
    except TimeoutError as exc:
        raise HerdrError("timeout", f"herdr did not answer within {timeout:g}s") from exc
    finally:
        sock.close()

    line = bytes(buffer).split(b"\n", 1)[0]
    try:
        message = json.loads(line)
    except ValueError as exc:
        raise HerdrError("bad_response", f"invalid JSON from herdr: {exc}") from exc

    if message.get("error"):
        error = message["error"]
        raise HerdrError(
            str(error.get("code", "error")),
            str(error.get("message", "herdr returned an error")),
        )
    if "result" not in message:
        raise HerdrError("bad_response", "herdr response contained no result")
    return message["result"]


def service_state(name: str) -> str:
    """Return systemd's active state, cached for a few seconds."""
    now = time.monotonic()
    with _service_cache_lock:
        cached = _service_cache.get(name)
        if cached and now - cached[0] < 5.0:
            return cached[1]

    try:
        completed = subprocess.run(
            ["systemctl", "is-active", name],
            capture_output=True,
            text=True,
            timeout=3,
        )
        state = (completed.stdout or completed.stderr).strip() or "unknown"
    except (OSError, subprocess.SubprocessError):
        state = "unknown"

    with _service_cache_lock:
        _service_cache[name] = (now, state)
    return state


def read_meminfo() -> dict[str, int]:
    values: dict[str, int] = {}
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as handle:
            for line in handle:
                key, _, rest = line.partition(":")
                fields = rest.split()
                if fields:
                    values[key] = int(fields[0]) * 1024
    except OSError:
        pass
    return values


def system_stats() -> dict:
    mem = read_meminfo()
    mem_total = mem.get("MemTotal", 0)
    mem_available = mem.get("MemAvailable", mem.get("MemFree", 0))
    swap_total = mem.get("SwapTotal", 0)
    swap_free = mem.get("SwapFree", 0)

    try:
        with open("/proc/uptime", "r", encoding="utf-8") as handle:
            uptime = float(handle.read().split()[0])
    except (OSError, ValueError, IndexError):
        uptime = 0.0

    try:
        load1, load5, load15 = os.getloadavg()
    except OSError:
        load1 = load5 = load15 = 0.0

    try:
        vfs = os.statvfs("/")
        disk_total = vfs.f_frsize * vfs.f_blocks
        disk_free = vfs.f_frsize * vfs.f_bavail
    except OSError:
        disk_total = disk_free = 0

    return {
        "hostname": socket.gethostname(),
        "cpus": os.cpu_count() or 1,
        "uptime_seconds": round(uptime),
        "load": {
            "one": round(load1, 2),
            "five": round(load5, 2),
            "fifteen": round(load15, 2),
        },
        "memory": {
            "total": mem_total,
            "available": mem_available,
            "used": max(mem_total - mem_available, 0),
        },
        "swap": {
            "total": swap_total,
            "free": swap_free,
            "used": max(swap_total - swap_free, 0),
        },
        "disk": {
            "total": disk_total,
            "free": disk_free,
            "used": max(disk_total - disk_free, 0),
        },
    }


def herdr_version() -> str | None:
    """Return `herdr --version`, cached for a minute (polled every few seconds)."""
    global _version_cache
    now = time.monotonic()
    with _version_cache_lock:
        if _version_cache and now - _version_cache[0] < 60.0:
            return _version_cache[1]

    try:
        completed = subprocess.run(
            [HERDR_BIN, "--version"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        text = (completed.stdout or completed.stderr).strip() or None
    except (OSError, subprocess.SubprocessError):
        text = None

    with _version_cache_lock:
        _version_cache = (now, text)
    return text


def dashboard_payload() -> dict:
    response = herdr_rpc("session.snapshot")
    snapshot = response.get("snapshot", response)
    return {
        "ok": True,
        "generated_at": time.time(),
        "dashboard": {
            "version": APP_VERSION,
            "port": PORT,
        },
        "herdr": {
            "version": snapshot.get("version"),
            "protocol": snapshot.get("protocol"),
            "binary_version": herdr_version(),
            "socket": SOCKET_PATH,
        },
        "services": {name: service_state(name) for name in SERVICE_NAMES},
        "system": system_stats(),
        "snapshot": snapshot,
        "links": {
            "ttyd_port": TTYD_PORT,
        },
    }


def validate_pane_id(value: object) -> str:
    if not isinstance(value, str) or not PANE_ID_RE.match(value):
        raise ValueError("invalid pane_id")
    return value


def openrouter_env() -> dict:
    """Launch env for new panes from the install-time OpenRouter key."""
    key = OPENROUTER_API_KEY or ""
    if not key.strip():
        return {}
    env = {
        "ANTHROPIC_BASE_URL": OPENROUTER_BASE_URL,
        "ANTHROPIC_API_KEY": key.strip(),
    }
    if OPENROUTER_MODEL.strip():
        env["ANTHROPIC_MODEL"] = OPENROUTER_MODEL.strip()
    return env


def launch_env_for(requested: dict) -> dict:
    """Merge requested env entries over the install-time OpenRouter defaults."""
    env = dict(openrouter_env())
    api_key = (requested.get("ANTHROPIC_API_KEY") or "").strip()
    base_url = (requested.get("ANTHROPIC_BASE_URL") or OPENROUTER_BASE_URL).strip()
    model = (requested.get("ANTHROPIC_MODEL") or OPENROUTER_MODEL).strip()
    if api_key:
        env = {
            "ANTHROPIC_BASE_URL": base_url,
            "ANTHROPIC_API_KEY": api_key,
        }
        if model:
            env["ANTHROPIC_MODEL"] = model
    extra = {
        key: value
        for key, value in requested.items()
        if key not in {"ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL"}
    }
    env.update(extra)
    return env


def validate_env(value: object) -> dict:
    """Normalize an optional per-request env map for pane/workspace/tab creation."""
    if not isinstance(value, dict) or not value:
        return {}
    if len(value) > ENV_MAX_KEYS:
        raise ValueError("env supports at most 10 keys")
    result: dict = {}
    for key, val in value.items():
        if not isinstance(key, str) or not ENV_KEY_RE.match(key):
            raise ValueError("invalid env key")
        if not isinstance(val, str) or not val.strip():
            raise ValueError(f"env value for {key} must not be empty")
        if len(val) > ENV_VALUE_MAX_CHARS:
            raise ValueError(f"env value for {key} is too long")
        result[key] = val
    return result


def validate_text(value: object, field: str = "text", limit: int = 16000) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{field} must be a string")
    if not value.strip():
        raise ValueError(f"{field} must not be empty")
    if len(value) > limit:
        raise ValueError(f"{field} is too long (max {limit} characters)")
    return value


def run_action(body: dict) -> dict:
    """Whitelisted actions for the UI. Never forwards arbitrary methods."""
    action = body.get("action")
    if not isinstance(action, str):
        raise ValueError("action is required")

    if action == "pane.focus":
        pane_id = validate_pane_id(body.get("pane_id"))
        return herdr_rpc("pane.focus", {"pane_id": pane_id})

    if action == "pane.close":
        pane_id = validate_pane_id(body.get("pane_id"))
        return herdr_rpc("pane.close", {"pane_id": pane_id})

    if action == "pane.rename":
        pane_id = validate_pane_id(body.get("pane_id"))
        label = body.get("label")
        if label is not None and not isinstance(label, str):
            raise ValueError("label must be a string or null")
        if isinstance(label, str):
            label = label.strip()[:120] or None
        return herdr_rpc("pane.rename", {"pane_id": pane_id, "label": label})

    if action == "pane.swap":
        source_pane_id = validate_pane_id(body.get("source_pane_id"))
        target_pane_id = validate_pane_id(body.get("target_pane_id"))
        return herdr_rpc(
            "pane.swap",
            {"source_pane_id": source_pane_id, "target_pane_id": target_pane_id},
        )

    if action in {"pane.prompt", "pane.type"}:
        pane_id = validate_pane_id(body.get("pane_id"))
        text = validate_text(body.get("text"))

        if action == "pane.type":
            return herdr_rpc("pane.send_text", {"pane_id": pane_id, "text": text})

        # Prefer the semantic agent prompt (sends Enter and knows agent state).
        # For plain shells fall back to typed input plus Enter.
        try:
            return herdr_rpc("agent.prompt", {"target": pane_id, "text": text})
        except HerdrError as exc:
            if exc.code in {"not_found", "not_an_agent", "agent_not_found"}:
                return herdr_rpc(
                    "pane.send_input",
                    {"pane_id": pane_id, "text": text, "keys": ["enter"]},
                )
            raise

    if action == "pane.keys":
        pane_id = validate_pane_id(body.get("pane_id"))
        keys = body.get("keys")
        if (
            not isinstance(keys, list)
            or not 1 <= len(keys) <= 20
            or not all(isinstance(key, str) and 0 < len(key) <= 32 for key in keys)
        ):
            raise ValueError("keys must be a list of 1-20 key names")
        return herdr_rpc("pane.send_keys", {"pane_id": pane_id, "keys": keys})

    if action == "pane.read":
        pane_id = validate_pane_id(body.get("pane_id"))
        source = body.get("source", "recent")
        if source not in READ_SOURCES:
            raise ValueError("invalid read source")
        lines = min(max(int(body.get("lines", 120)), 1), MAX_READ_LINES)
        return herdr_rpc(
            "pane.read",
            {
                "pane_id": pane_id,
                "source": source,
                "lines": lines,
                "strip_ansi": True,
                "format": "text",
            },
        )

    if action == "workspace.create":
        label = body.get("label")
        cwd = body.get("cwd")
        params: dict = {"focus": True}
        if isinstance(label, str) and label.strip():
            params["label"] = label.strip()[:120]
        if isinstance(cwd, str) and cwd.strip():
            if not cwd.strip().startswith("/"):
                raise ValueError("cwd must be an absolute path")
            params["cwd"] = cwd.strip()
        launch_env = launch_env_for(validate_env(body.get("env")))
        if launch_env:
            params["env"] = launch_env
        return herdr_rpc("workspace.create", params)

    if action == "workspace.focus":
        workspace_id = body.get("workspace_id")
        if not isinstance(workspace_id, str) or not PANE_ID_RE.match(workspace_id):
            raise ValueError("invalid workspace_id")
        return herdr_rpc("workspace.focus", {"workspace_id": workspace_id})

    if action == "workspace.rename":
        workspace_id = body.get("workspace_id")
        if not isinstance(workspace_id, str) or not PANE_ID_RE.match(workspace_id):
            raise ValueError("invalid workspace_id")
        label = validate_text(body.get("label"), "label", 120).strip()
        return herdr_rpc(
            "workspace.rename", {"workspace_id": workspace_id, "label": label}
        )

    if action == "tab.create":
        label = body.get("label")
        workspace_id = body.get("workspace_id")
        params = {"focus": True}
        if isinstance(label, str) and label.strip():
            params["label"] = label.strip()[:120]
        if isinstance(workspace_id, str) and PANE_ID_RE.match(workspace_id):
            params["workspace_id"] = workspace_id
        launch_env = launch_env_for(validate_env(body.get("env")))
        if launch_env:
            params["env"] = launch_env
        return herdr_rpc("tab.create", params)

    if action == "tab.focus":
        tab_id = body.get("tab_id")
        if not isinstance(tab_id, str) or not PANE_ID_RE.match(tab_id):
            raise ValueError("invalid tab_id")
        return herdr_rpc("tab.focus", {"tab_id": tab_id})

    raise ValueError(f"unknown action: {action}")


class DashboardHandler(BaseHTTPRequestHandler):
    server_version = f"herdr-dashboard/{APP_VERSION}"
    protocol_version = "HTTP/1.1"

    # -- helpers ---------------------------------------------------------

    def _security_headers(self) -> None:
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; connect-src 'self'; img-src 'self' data:; "
            "style-src 'self'; script-src 'self'; base-uri 'none'; "
            "form-action 'self'; frame-ancestors 'none'",
        )
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")

    def _send_bytes(
        self,
        status: int,
        body: bytes,
        content_type: str,
        cache: str = "no-store",
        extra_headers: dict[str, str] | None = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self._security_headers()
        for key, value in (extra_headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def _send_json(
        self,
        status: int,
        payload: dict,
        extra_headers: dict[str, str] | None = None,
    ) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self._send_bytes(
            status,
            body,
            "application/json; charset=utf-8",
            extra_headers=extra_headers,
        )

    def _error(self, status: int, code: str, message: str) -> None:
        self._send_json(status, {"ok": False, "error": {"code": code, "message": message}})

    def _authorized(self) -> bool:
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        try:
            decoded = base64.b64decode(header[6:], validate=True).decode("utf-8")
            username, _, password = decoded.partition(":")
        except (ValueError, UnicodeDecodeError):
            return False
        user_ok = secrets.compare_digest(username, WEB_USER)
        password_ok = secrets.compare_digest(password, WEB_PW)
        return user_ok and password_ok

    def _require_auth(self) -> bool:
        if self._authorized():
            return True
        time.sleep(0.15)
        self._send_json(
            401,
            {"ok": False, "error": {"code": "unauthorized", "message": "login required"}},
            {"WWW-Authenticate": 'Basic realm="herdr dashboard", charset="UTF-8"'},
        )
        return False

    def _same_origin(self) -> bool:
        """Reject cross-site POSTs; Basic auth alone is not CSRF protection."""
        fetch_site = (self.headers.get("Sec-Fetch-Site") or "").lower()
        if fetch_site and fetch_site not in {"same-origin", "none"}:
            return False
        origin = self.headers.get("Origin")
        if not origin:
            return True
        origin_host = urlparse(origin).netloc.lower()
        request_host = (
            self.headers.get("X-Forwarded-Host")
            or self.headers.get("Host")
            or ""
        ).split(",")[0].strip().lower()
        return bool(origin_host) and origin_host == request_host

    def _read_json_body(self) -> dict:
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError as exc:
            raise ValueError("invalid Content-Length") from exc
        if length <= 0:
            raise ValueError("request body is required")
        if length > MAX_BODY_BYTES:
            raise ValueError("request body is too large")
        raw = self.rfile.read(length)
        try:
            parsed = json.loads(raw)
        except ValueError as exc:
            raise ValueError(f"invalid JSON: {exc}") from exc
        if not isinstance(parsed, dict):
            raise ValueError("request body must be a JSON object")
        return parsed

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write(
            "%s - - [%s] %s\n"
            % (self.address_string(), self.log_date_time_string(), fmt % args)
        )

    # -- HTTP verbs ------------------------------------------------------

    def do_HEAD(self) -> None:  # noqa: N802 - http.server API
        self.do_GET()

    def do_GET(self) -> None:  # noqa: N802 - http.server API
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/healthz":
            self._send_json(200, {"ok": True})
            return

        if path == "/logout":
            body = (
                "<!doctype html><meta charset=\"utf-8\">"
                "<title>herdr dashboard</title>"
                "<p>Abgemeldet. <a href=\"/\">Neu anmelden</a></p>"
            ).encode("utf-8")
            self._send_bytes(
                401,
                body,
                "text/html; charset=utf-8",
                extra_headers={
                    "WWW-Authenticate": 'Basic realm="herdr dashboard", charset="UTF-8"'
                },
            )
            return

        if not self._require_auth():
            return

        if path == "/terminal":
            self.send_response(302)
            self.send_header("Location", self._terminal_url())
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if path == "/api/snapshot":
            try:
                self._send_json(200, dashboard_payload())
            except HerdrError as exc:
                self._send_json(
                    503,
                    {
                        "ok": False,
                        "error": {"code": exc.code, "message": exc.message},
                        "services": {name: service_state(name) for name in SERVICE_NAMES},
                        "system": system_stats(),
                        "herdr": {"socket": SOCKET_PATH, "binary_version": herdr_version()},
                    },
                )
            return

        if path == "/api/pane":
            query = parse_qs(parsed.query)
            try:
                pane_id = validate_pane_id((query.get("pane_id") or [""])[0])
                source = (query.get("source") or ["recent"])[0]
                if source not in READ_SOURCES:
                    raise ValueError("invalid read source")
                try:
                    lines = int((query.get("lines") or ["120"])[0])
                except ValueError as exc:
                    raise ValueError("lines must be a number") from exc
                lines = min(max(lines, 1), MAX_READ_LINES)
                result = herdr_rpc(
                    "pane.read",
                    {
                        "pane_id": pane_id,
                        "source": source,
                        "lines": lines,
                        "strip_ansi": True,
                        "format": "text",
                    },
                )
                self._send_json(200, {"ok": True, "pane": result})
            except ValueError as exc:
                self._error(400, "bad_request", str(exc))
            except HerdrError as exc:
                self._error(502, exc.code, exc.message)
            return

        if path in STATIC_FILES:
            filename, content_type = STATIC_FILES[path]
            full_path = os.path.join(STATIC_DIR, filename)
            try:
                with open(full_path, "rb") as handle:
                    body = handle.read()
            except OSError:
                self._error(404, "not_found", "static file is missing")
                return
            cache = "no-cache" if content_type.startswith("text/html") else "public, max-age=300"
            self._send_bytes(200, body, content_type, cache=cache)
            return

        self._error(404, "not_found", "not found")

    def do_POST(self) -> None:  # noqa: N802 - http.server API
        if not self._require_auth():
            return

        parsed = urlparse(self.path)
        if parsed.path != "/api/action":
            self._error(404, "not_found", "not found")
            return

        content_type = (
            (self.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
        )
        if content_type != "application/json":
            self._error(
                415,
                "unsupported_media_type",
                "Content-Type must be application/json",
            )
            return
        if not self._same_origin():
            self._error(403, "forbidden_origin", "cross-origin request rejected")
            return

        try:
            body = self._read_json_body()
            result = run_action(body)
            self._send_json(200, {"ok": True, "result": result})
        except ValueError as exc:
            self._error(400, "bad_request", str(exc))
        except HerdrError as exc:
            self._error(502, exc.code, exc.message)

    # -- misc ------------------------------------------------------------

    def _terminal_url(self) -> str:
        host_header = self.headers.get("Host", "")
        host = host_header
        if host_header.startswith("["):
            # IPv6 literal: [::1]:8080
            closing = host_header.find("]")
            if closing != -1:
                host = host_header[: closing + 1]
        elif ":" in host_header:
            host = host_header.rsplit(":", 1)[0]
        host = host or "127.0.0.1"
        scheme = self.headers.get("X-Forwarded-Proto", "http").split(",")[0].strip()
        if scheme not in {"http", "https"}:
            scheme = "http"
        return f"{scheme}://{host}:{TTYD_PORT}/"


class DashboardServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main() -> int:
    if not WEB_PW:
        print(
            "ERROR: WEB_PW is empty. Refusing to start an unauthenticated dashboard.",
            file=sys.stderr,
        )
        return 1
    if not os.path.isfile(os.path.join(STATIC_DIR, "index.html")):
        print(f"ERROR: dashboard assets missing in {STATIC_DIR}", file=sys.stderr)
        return 1

    server = DashboardServer((HOST, PORT), DashboardHandler)
    print(f"herdr dashboard {APP_VERSION} listening on http://{HOST}:{PORT}", flush=True)
    print(f"herdr socket: {SOCKET_PATH}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
