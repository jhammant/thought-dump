"""Thought Dump's HTTP API, for the iPhone, iPad and Watch app. Standard library only.

Binds 127.0.0.1; put it on your tailnet with `tailscale serve --bg --https=8783 http://127.0.0.1:8783`.
Every /api route needs `Authorization: Bearer <token>`, the token `dump pair` prints. When the config
lists server.allowed_logins, a request that came through tailscale serve must also carry one of
those Tailscale-User-Login values (tagged devices carry none and are refused).

    GET  /api/pair                                 no token needed: hands the token to an allowed Tailscale login
    GET  /api/health                               {"ok": true, ...}
    GET  /api/dumps                                newest first, summaries
    POST /api/dumps                                {"text", "client_id", "recorded_at"?, "duration_seconds"?, "device"?}
    GET  /api/dumps/<id>                           the note, the thoughts found, how each is handled
    POST /api/dumps/<id>/plan                      {"start_now"?, "routes"?: {task: run|draft|todo|skip}, "stop"?: [task]}
    POST /api/dumps/<id>/retry                     split again after a failed split
    GET  /api/dumps/<id>/files/<task>/<path>       a file a worker made
"""
from datetime import datetime, timezone
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import mimetypes
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit

import thought_dump as td

ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
CLIENT_RE = re.compile(r"^[A-Za-z0-9-]{8,64}$")
MAX_BODY = 200_000
LIST_LIMIT = 50


def batches_dir():
    return td.HOME / "batches"


def batch(dump_id):
    if not ID_RE.fullmatch(dump_id):
        raise LookupError
    path = batches_dir() / dump_id
    if not path.is_dir() or path.is_symlink():
        raise LookupError
    return path


def token():
    path = td.HOME / "token"
    return path.read_text(encoding="utf-8").strip() if path.is_file() else ""


def new_batch_id(client_id, recorded_at):
    try:
        when = datetime.fromisoformat(recorded_at).astimezone(timezone.utc) if recorded_at else datetime.now(timezone.utc)
    except (TypeError, ValueError):
        when = datetime.now(timezone.utc)
    # Same client_id, same batch: the app retries freely without making a second dump.
    return f"app-{when:%Y%m%d-%H%M%S}-{hashlib.sha256(client_id.encode()).hexdigest()[:6]}"


def start_capture(state):
    """Split then go, in its own session so it outlives the request (and a server restart)."""
    extra = json.loads(os.environ.get("THOUGHT_DUMP_CAPTURE_ARGS", "[]"))  # tests: --fake-claude --hold 0
    (state / "go.log").unlink(missing_ok=True)
    log = os.open(state / "go.log", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        subprocess.Popen(
            [sys.executable, str(td.ROOT / "dump"), "capture", str(state / "source.md"), "--state-dir", str(state), *extra],
            cwd=td.ROOT, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True,
        )
    finally:
        os.close(log)


class Handler(BaseHTTPRequestHandler):
    server_version = "ThoughtDump/1"

    def log_message(self, fmt, *args):  # one line per request, never bodies
        sys.stderr.write(f"{self.log_date_time_string()} {self.command} {urlsplit(self.path).path} {args[1] if len(args) > 1 else ''}\n")

    def reply(self, code, payload, content_type="application/json"):
        body = payload if isinstance(payload, bytes) else (json.dumps(payload, ensure_ascii=False) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def allowed(self):
        expected = token()
        given = self.headers.get("Authorization", "")
        if not expected or not hmac.compare_digest(given.encode(), f"Bearer {expected}".encode()):
            return False
        logins = td.config()["server"].get("allowed_logins") or []
        login = self.headers.get("Tailscale-User-Login")
        via_tailscale = login is not None or self.headers.get("Tailscale-User-Name") is not None
        return not (logins and via_tailscale and login not in logins)

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not 0 < length <= MAX_BODY:
            raise ValueError("body must be 1–200000 bytes of JSON")
        data = json.loads(self.rfile.read(length))
        if not isinstance(data, dict):
            raise ValueError("body must be a JSON object")
        return data

    def route(self):
        parts = [unquote(part) for part in urlsplit(self.path).path.split("/") if part]
        if parts[:1] != ["api"]:
            raise LookupError
        return parts[1:]

    def do_GET(self):
        self.handle_request("GET")

    def do_POST(self):
        self.handle_request("POST")

    def handle_request(self, method):
        try:
            parts = self.route()
            if method == "GET" and parts == ["pair"]:
                return self.pair()
            if not self.allowed():
                return self.reply(401, {"error": "pair the app with this Mac: run `dump pair`"})
            if method == "GET" and parts == ["health"]:
                return self.reply(200, {"ok": True, "name": "Thought Dump", "api": 1,
                                        "workspaces": list(td.config()["workspaces"])})
            if method == "GET" and parts == ["dumps"]:
                return self.reply(200, {"dumps": self.list_dumps()})
            if method == "POST" and parts == ["dumps"]:
                return self.create(self.body())
            if len(parts) >= 2 and parts[0] == "dumps":
                state = batch(parts[1])
                if method == "GET" and len(parts) == 2:
                    return self.reply(200, td.snapshot(state))
                if method == "POST" and parts[2:] == ["plan"]:
                    data = self.body()
                    td.update_plan(state, start_now=bool(data.get("start_now")),
                                   routes=data.get("routes") or None, stop=data.get("stop") or None)
                    return self.reply(200, td.snapshot(state))
                if method == "POST" and parts[2:] == ["retry"]:
                    if (state / "tasks.json").exists() or not (state / "failed.json").exists():
                        return self.reply(409, {"error": "only a failed split can be retried"})
                    start_capture(state)
                    return self.reply(202, td.snapshot(state))
                if method == "GET" and len(parts) >= 5 and parts[2] == "files":
                    return self.file(state, parts[3], "/".join(parts[4:]))
            raise LookupError
        except LookupError:
            self.reply(404, {"error": "not found"})
        except (ValueError, td.DumpError) as exc:
            self.reply(400, {"error": str(exc)[:300]})
        except OSError as exc:
            self.reply(500, {"error": type(exc).__name__})

    def pair(self):
        """On a tailnet the identity is already proven: an allowed login gets the token without
        copying a link. Everyone else pairs with the link `dump pair` prints."""
        logins = td.config()["server"].get("allowed_logins") or []
        login = self.headers.get("Tailscale-User-Login")
        if not logins or login not in logins or not token():
            return self.reply(401, {"error": "pair with the link `dump pair` prints on the Mac"})
        return self.reply(200, {"token": token(), "name": "Thought Dump"})

    def list_dumps(self):
        views = []
        root = batches_dir()
        for path in root.iterdir() if root.is_dir() else []:
            if path.is_dir() and not path.is_symlink() and ID_RE.fullmatch(path.name):
                try:
                    views.append(td.snapshot(path, full=False))
                except (td.DumpError, OSError):
                    continue
        views.sort(key=lambda view: view["created_at"], reverse=True)
        return views[:LIST_LIMIT]

    def create(self, data):
        text, client_id = data.get("text"), data.get("client_id")
        if not isinstance(text, str) or not text.strip() or len(text) > td.MAX_INPUT:
            raise ValueError(f"text must be 1–{td.MAX_INPUT} characters")
        if not isinstance(client_id, str) or not CLIENT_RE.fullmatch(client_id):
            raise ValueError("client_id must be 8–64 letters, digits or dashes")
        state = batches_dir() / new_batch_id(client_id, data.get("recorded_at"))
        if state.exists():
            return self.reply(200, td.snapshot(state))
        state.mkdir(parents=True, mode=0o700)
        td.atomic_text(state / "source.md", text.strip() + "\n")
        td.write_json(state / "client.json", {
            "client_id": client_id, "device": str(data.get("device", ""))[:40],
            "recorded_at": str(data.get("recorded_at", ""))[:40],
            "duration_seconds": data.get("duration_seconds") if isinstance(data.get("duration_seconds"), (int, float)) else None,
        })
        start_capture(state)
        return self.reply(201, td.snapshot(state))

    def file(self, state, task_id, relative):
        tasks = {task["id"]: task for task in td.load_tasks(state)}
        if task_id not in tasks or relative not in td.workspace_files(state, tasks[task_id]):
            raise LookupError
        path = td.contained(state, tasks[task_id]["workspace"]) / relative
        if path.stat().st_size > td.MAX_OUTPUT:
            raise LookupError
        kind = mimetypes.guess_type(path.name)[0] or "text/plain"
        if kind.startswith("text/") or kind in {"application/json", "text/x-python"} or path.suffix in {".py", ".md", ".swift"}:
            kind = "text/plain; charset=utf-8"
        return self.reply(200, path.read_bytes(), kind)


def main(args):
    port = args.port or int(td.config()["server"]["port"])
    if not token():
        print("No token yet: run `dump pair` first.", file=sys.stderr)
        return 1
    batches_dir().mkdir(parents=True, exist_ok=True, mode=0o700)
    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"Thought Dump API on http://127.0.0.1:{port}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0
