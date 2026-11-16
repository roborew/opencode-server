#!/usr/bin/env python3
"""Streaming reverse proxy that:
1) Blocks DELETE of main app checkouts under OPENCODE_APPS_DIR.
2) After worktree DELETE, finishes git cleanup (host-path rewrite
   makes OpenCode's own `git worktree remove` leave prunable admin entries).

OpenCode v2 API: DELETE /api/worktree with JSON body
{"projectID": str, "directory": str, "force": bool}. There are no workspace
endpoints in v2 — projects replaced them.
"""

from __future__ import annotations

import json
import os
import select
import socket
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

UPSTREAM_HOST = os.environ.get("OPENCODE_UPSTREAM_HOST", "127.0.0.1")
UPSTREAM_PORT = int(os.environ.get("OPENCODE_UPSTREAM_PORT", "4098"))
LISTEN_HOST = os.environ.get("OPENCODE_GUARD_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("OPENCODE_GUARD_PORT", "4097"))

CONTAINER_WT = (
    os.environ.get("OPENCODE_CONTAINER_WORKTREE", "").rstrip("/")
    or "/var/opencode-xdg/opencode/worktree"
)
HOST_WT = os.environ.get("OPENCODE_WORKTREES_DIR", "").rstrip("/")
HOST_APPS = os.environ.get("OPENCODE_APPS_DIR", "").rstrip("/")
CLEANUP_SCRIPT = "/usr/local/bin/rewrite-worktree-gitdirs.py"


def _is_worktree_path(path: str) -> bool:
    path = (path or "").rstrip("/")
    for root in (CONTAINER_WT, HOST_WT):
        if root and (path == root or path.startswith(root + "/")):
            return True
    return False


def _is_protected_project_root(path: str) -> bool:
    path = (path or "").rstrip("/")
    if not path or _is_worktree_path(path):
        return False
    if not HOST_APPS:
        return False
    return path == HOST_APPS or path.startswith(HOST_APPS + "/")


def _parse_worktree_delete_body(raw: bytes) -> tuple[str, str]:
    """Return (directory, projectID) from a v2 DELETE /api/worktree body.

    Non-object bodies and non-string directories yield empty values so the
    protected-root check is skipped and the request still reaches the upstream
    for validation.
    """
    try:
        data = json.loads(raw.decode("utf-8") or "{}")
    except (UnicodeDecodeError, json.JSONDecodeError):
        return "", ""
    if not isinstance(data, dict):
        return "", ""
    raw_dir = data.get("directory")
    directory = raw_dir.rstrip("/") if isinstance(raw_dir, str) else ""
    project = str(data.get("projectID") or "")
    return directory, project


def _blocked_worktree_delete(body: bytes) -> str | None:
    directory, _ = _parse_worktree_delete_body(body)
    if directory and _is_protected_project_root(directory):
        return directory
    return None


def _schedule_git_cleanup(directory: str, project: str = "") -> None:
    directory = (directory or "").rstrip("/")
    if not directory or not _is_worktree_path(directory):
        return
    if not os.path.isfile(CLEANUP_SCRIPT):
        return

    def run() -> None:
        # Small delay so OpenCode finishes its own (partial) remove first.
        import time

        time.sleep(0.3)
        env = os.environ.copy()
        args = ["python3", CLEANUP_SCRIPT, "remove", "--directory", directory]
        if project:
            args.extend(["--project", project])
        try:
            proc = subprocess.run(
                args,
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
                env=env,
            )
            err = (proc.stderr or "").strip()
            if err:
                sys.stderr.write(f"worktree-delete-guard: cleanup: {err}\n")
            for cmd in ("prune", "scrub"):
                subprocess.run(
                    ["python3", CLEANUP_SCRIPT, cmd],
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=60,
                    env=env,
                )
        except (OSError, subprocess.TimeoutExpired) as exc:
            sys.stderr.write(f"worktree-delete-guard: cleanup failed: {exc}\n")

    threading.Thread(target=run, daemon=True).start()
    sys.stderr.write(f"worktree-delete-guard: scheduled git cleanup for {directory}\n")


class GuardHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("worktree-delete-guard: %s\n" % (fmt % args))

    def do_DELETE(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length > 0 else b""
        path = parsed.path.rstrip("/")

        if path == "/api/worktree":
            blocked = _blocked_worktree_delete(body)
            if blocked:
                msg = (
                    f"Refusing to delete project root {blocked} "
                    "(would wipe the real checkout under OPENCODE_APPS_DIR). "
                    "Only paths under the OpenCode worktree store can be deleted."
                )
                payload = json.dumps(
                    {"name": "WorktreeDeleteBlocked", "data": {"message": msg}}
                ).encode()
                self.send_response(409)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(payload)
                sys.stderr.write(f"worktree-delete-guard: blocked DELETE {blocked}\n")
                return

        # Resolve cleanup target before streaming DELETE (must not block response).
        # v2 DELETE /api/worktree body: {"projectID", "directory", "force"}.
        cleanup_dir = ""
        project = ""
        if path == "/api/worktree":
            cleanup_dir, project = _parse_worktree_delete_body(body)

        if cleanup_dir:
            _schedule_git_cleanup(cleanup_dir, project)

        self._proxy(body)

    def do_GET(self) -> None:  # noqa: N802
        self._proxy(b"")

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length > 0 else b""
        self._proxy(body)

    def do_PUT(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length > 0 else b""
        self._proxy(body)

    def do_PATCH(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length > 0 else b""
        self._proxy(body)

    def do_OPTIONS(self) -> None:  # noqa: N802
        self._proxy(b"")

    def do_HEAD(self) -> None:  # noqa: N802
        self._proxy(b"")

    def _proxy(self, body: bytes) -> None:
        upstream = socket.create_connection((UPSTREAM_HOST, UPSTREAM_PORT), timeout=60)
        try:
            lines = [f"{self.command} {self.path} HTTP/1.1".encode()]
            hop_by_hop = {
                "connection",
                "keep-alive",
                "proxy-authenticate",
                "proxy-authorization",
                "te",
                "trailers",
                "transfer-encoding",
                "upgrade",
                "proxy-connection",
            }
            for key, value in self.headers.items():
                if key.lower() in hop_by_hop:
                    continue
                if key.lower() == "host":
                    value = f"{UPSTREAM_HOST}:{UPSTREAM_PORT}"
                lines.append(f"{key}: {value}".encode())
            if body and "content-length" not in {
                k.lower() for k in self.headers.keys()
            }:
                lines.append(f"Content-Length: {len(body)}".encode())
            lines.append(b"")
            upstream.sendall(b"\r\n".join(lines) + b"\r\n")
            if body:
                upstream.sendall(body)

            buf = b""
            header_end = -1
            while header_end < 0:
                chunk = upstream.recv(65536)
                if not chunk:
                    break
                buf += chunk
                header_end = buf.find(b"\r\n\r\n")

            if header_end < 0:
                if buf:
                    self.connection.sendall(buf)
                return

            header_blob = buf[: header_end + 4]
            rest = buf[header_end + 4 :]
            self.connection.sendall(header_blob)
            if rest:
                self.connection.sendall(rest)

            # If Content-Length is known, stop after that many body bytes
            # (avoids hanging on keep-alive).
            content_length = None
            for line in header_blob.split(b"\r\n"):
                if line.lower().startswith(b"content-length:"):
                    try:
                        content_length = int(line.split(b":", 1)[1].strip())
                    except ValueError:
                        content_length = None
                    break

            received = len(rest)
            if content_length is not None:
                while received < content_length:
                    chunk = upstream.recv(min(65536, content_length - received))
                    if not chunk:
                        break
                    self.connection.sendall(chunk)
                    received += len(chunk)
                return

            sockets = [upstream, self.connection]
            while True:
                readable, _, _ = select.select(sockets, [], [], 60)
                if not readable:
                    break
                for sock in readable:
                    other = self.connection if sock is upstream else upstream
                    try:
                        data = sock.recv(65536)
                    except OSError:
                        data = b""
                    if not data:
                        return
                    try:
                        other.sendall(data)
                    except OSError:
                        return
        finally:
            try:
                upstream.close()
            except OSError:
                pass


def main() -> int:
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), GuardHandler)
    sys.stderr.write(
        f"worktree-delete-guard: listen {LISTEN_HOST}:{LISTEN_PORT} → "
        f"{UPSTREAM_HOST}:{UPSTREAM_PORT}\n"
    )
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
