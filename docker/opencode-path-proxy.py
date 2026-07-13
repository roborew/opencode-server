#!/usr/bin/env python3
"""Reverse-proxy OpenCode HTTP/SSE and rewrite worktree paths for clients.

OpenCode creates workspaces under OPENCODE_CONTAINER_WORKTREE
(/var/opencode-xdg/opencode/worktree). That directory is a bind-mount of
OPENCODE_WORKTREES_DIR on the host — one filesystem, one server-side path.

This proxy rewrites that container path ↔ the host path in requests/responses
(including SSE, buffered by event) so the UI always sees the host path,
without ever registering two sandboxes.
"""
from __future__ import annotations

import json
import os
import select
import subprocess
import sys
import threading
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote


LISTEN_HOST = os.environ.get("OPENCODE_PROXY_BIND", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("OPENCODE_PROXY_PORT", "4097"))
UPSTREAM_HOST = os.environ.get("OPENCODE_UPSTREAM_HOST", "127.0.0.1")
UPSTREAM_PORT = int(os.environ.get("OPENCODE_UPSTREAM_PORT", "4098"))

# Prefer explicit container worktree; fall back to legacy /root path for old images
CONTAINER_WT = (
    os.environ.get("OPENCODE_CONTAINER_WORKTREE", "").rstrip("/")
    or "/var/opencode-xdg/opencode/worktree"
)
HOST_WT = os.environ.get("OPENCODE_WORKTREES_DIR", "").rstrip("/")
# Also rewrite legacy /root paths from older workspaces
LEGACY_ROOT_WT = "/root/.local/share/opencode/worktree"

# Clients send directory= as fully percent-encoded paths (%2FUsers%2F...).
# Plain string replace misses those; rewrite both plaintext and encoded forms.
HOST_WT_ENC = quote(HOST_WT, safe="") if HOST_WT else ""
CONTAINER_WT_ENC = quote(CONTAINER_WT, safe="") if CONTAINER_WT else ""
LEGACY_ROOT_WT_ENC = quote(LEGACY_ROOT_WT, safe="")

HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "content-length",
    "host",
}


def _rewrite_pairs(data: bytes, pairs: list[tuple[str, str]]) -> bytes:
    for src, dst in pairs:
        if not src or src == dst:
            continue
        if src.encode() in data:
            data = data.replace(src.encode(), dst.encode())
        src_enc = quote(src, safe="")
        dst_enc = quote(dst, safe="")
        if src_enc.encode() in data:
            data = data.replace(src_enc.encode(), dst_enc.encode())
    return data


def to_client(data: bytes) -> bytes:
    if not HOST_WT:
        return data
    data = _rewrite_pairs(
        data,
        [
            (CONTAINER_WT, HOST_WT),
            (LEGACY_ROOT_WT, HOST_WT),
        ],
    )
    return _dedupe_sandbox_paths_in_json(data)


def to_server(data: bytes) -> bytes:
    if not HOST_WT or not CONTAINER_WT:
        return data
    return _rewrite_pairs(data, [(HOST_WT, CONTAINER_WT)])


def to_server_str(value: str) -> str:
    if not HOST_WT or not CONTAINER_WT:
        return value
    if HOST_WT in value:
        value = value.replace(HOST_WT, CONTAINER_WT)
    if HOST_WT_ENC and HOST_WT_ENC in value:
        value = value.replace(HOST_WT_ENC, CONTAINER_WT_ENC)
    return value


def to_client_str(value: str) -> str:
    if not HOST_WT:
        return value
    if CONTAINER_WT in value:
        value = value.replace(CONTAINER_WT, HOST_WT)
    if CONTAINER_WT_ENC and CONTAINER_WT_ENC in value:
        value = value.replace(CONTAINER_WT_ENC, HOST_WT_ENC)
    if LEGACY_ROOT_WT in value:
        value = value.replace(LEGACY_ROOT_WT, HOST_WT)
    if LEGACY_ROOT_WT_ENC in value:
        value = value.replace(LEGACY_ROOT_WT_ENC, HOST_WT_ENC)
    return value


def _dedupe_sandbox_paths_in_json(data: bytes) -> bytes:
    if b"sandboxes" not in data or not data.lstrip().startswith((b"{", b"[")):
        return data
    try:
        payload = json.loads(data)
    except Exception:  # noqa: BLE001
        return data

    def fix(obj):
        if isinstance(obj, dict):
            if "sandboxes" in obj and isinstance(obj["sandboxes"], list):
                seen: set[str] = set()
                uniq = []
                for item in obj["sandboxes"]:
                    if not isinstance(item, str) or item in seen:
                        continue
                    seen.add(item)
                    uniq.append(item)
                obj["sandboxes"] = uniq
            for value in obj.values():
                fix(value)
        elif isinstance(obj, list):
            for value in obj:
                fix(value)

    fix(payload)
    return json.dumps(payload, separators=(",", ":")).encode()


def _trigger_git_metadata_rewrite() -> None:
    """Rewrite gitdirs to host paths after worktree create (plugins miss worktree.* events)."""
    script = "/usr/local/bin/dedupe-worktree-sandboxes.py"
    if not os.path.isfile(script):
        return

    def run() -> None:
        try:
            # Small delay so git finishes writing worktree metadata
            select.select([], [], [], 0.3)
            subprocess.run(
                ["python3", script],
                check=False,
                capture_output=True,
                timeout=30,
                env=os.environ.copy(),
            )
        except Exception as exc:  # noqa: BLE001
            sys.stderr.write(f"opencode-path-proxy: dedupe after create failed: {exc}\n")

    threading.Thread(target=run, daemon=True).start()


def _trigger_worktree_remove(directory: str, project_dir: str) -> None:
    """Finish git worktree/branch cleanup after OpenCode delete (path mismatch)."""
    script = "/usr/local/bin/dedupe-worktree-sandboxes.py"
    if not os.path.isfile(script) or not directory:
        return

    def run() -> None:
        try:
            select.select([], [], [], 0.2)
            env = os.environ.copy()
            cmd = ["python3", script, "remove", "--directory", directory]
            if project_dir:
                cmd.extend(["--project", project_dir])
            proc = subprocess.run(
                cmd,
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
                env=env,
            )
            if proc.stdout:
                sys.stderr.write(proc.stdout)
            if proc.stderr:
                sys.stderr.write(proc.stderr)
            if proc.returncode != 0:
                sys.stderr.write(
                    f"opencode-path-proxy: remove cleanup exit {proc.returncode}\n"
                )
        except Exception as exc:  # noqa: BLE001
            sys.stderr.write(f"opencode-path-proxy: remove cleanup failed: {exc}\n")

    threading.Thread(target=run, daemon=True).start()


def _parse_query_directory(path: str) -> str:
    from urllib.parse import parse_qs, urlparse, unquote

    qs = parse_qs(urlparse(path).query)
    values = qs.get("directory") or []
    return unquote(values[0]) if values else ""


def _parse_body_directory(body: bytes) -> str:
    if not body:
        return ""
    try:
        payload = json.loads(body)
    except Exception:  # noqa: BLE001
        return ""
    if isinstance(payload, dict) and isinstance(payload.get("directory"), str):
        return payload["directory"]
    return ""


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("opencode-path-proxy: %s\n" % (fmt % args))

    def _proxy(self) -> None:
        if not HOST_WT:
            self.send_error(500, "OPENCODE_WORKTREES_DIR not set")
            return

        length = int(self.headers.get("Content-Length", "0") or 0)
        body = self.rfile.read(length) if length > 0 else b""
        # Capture client body directory before rewrite (host path from UI)
        remove_directory = _parse_body_directory(body) if self.command == "DELETE" else ""
        body = to_server(body)
        if not remove_directory and self.command == "DELETE":
            remove_directory = _parse_body_directory(body)

        path = to_server_str(self.path)
        headers = {}
        for key, value in self.headers.items():
            if key.lower() in HOP_BY_HOP:
                continue
            headers[key] = to_server_str(value)

        is_worktree_create = self.command == "POST" and path.startswith("/experimental/worktree")
        is_worktree_remove = self.command == "DELETE" and path.startswith("/experimental/worktree")
        remove_project = _parse_query_directory(path) if is_worktree_remove else ""

        conn = HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=600)
        try:
            conn.request(self.command, path, body=body or None, headers=headers)
            upstream = conn.getresponse()
            content_type = (upstream.headers.get("Content-Type") or "").lower()
            is_stream = "text/event-stream" in content_type

            self.send_response(upstream.status)
            for key, value in upstream.getheaders():
                lk = key.lower()
                if lk in HOP_BY_HOP:
                    continue
                if lk == "content-length" and not is_stream:
                    continue
                self.send_header(key, to_client_str(value))
            self.send_header("Connection", "close")

            if not is_stream:
                data = to_client(upstream.read())
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                if is_worktree_create and 200 <= upstream.status < 300:
                    _trigger_git_metadata_rewrite()
                if is_worktree_remove and 200 <= upstream.status < 300:
                    _trigger_worktree_remove(remove_directory, remove_project)
            else:
                # SSE: must use read1() — read(n) can block until n bytes arrive,
                # which stalls forever on a quiet event stream and leaves the UI
                # stuck in "loading" waiting for worktree.ready.
                self.end_headers()
                try:
                    self.wfile.flush()
                except Exception:  # noqa: BLE001
                    pass
                buf = b""
                while True:
                    try:
                        chunk = (
                            upstream.read1(4096)
                            if hasattr(upstream, "read1")
                            else upstream.fp.read(4096)
                        )
                    except Exception:  # noqa: BLE001
                        chunk = b""
                    if not chunk:
                        if buf:
                            try:
                                self.wfile.write(to_client(buf))
                                self.wfile.flush()
                            except Exception:  # noqa: BLE001
                                pass
                        break
                    buf += chunk
                    while b"\n\n" in buf:
                        event, buf = buf.split(b"\n\n", 1)
                        try:
                            self.wfile.write(to_client(event + b"\n\n"))
                            self.wfile.flush()
                        except BrokenPipeError:
                            return
                        except Exception:  # noqa: BLE001
                            return
        except Exception as exc:  # noqa: BLE001
            try:
                self.send_error(502, f"upstream error: {exc}")
            except Exception:  # noqa: BLE001
                pass
        finally:
            conn.close()

    def do_GET(self) -> None:  # noqa: N802
        self._proxy()

    def do_POST(self) -> None:  # noqa: N802
        self._proxy()

    def do_PUT(self) -> None:  # noqa: N802
        self._proxy()

    def do_PATCH(self) -> None:  # noqa: N802
        self._proxy()

    def do_DELETE(self) -> None:  # noqa: N802
        self._proxy()

    def do_OPTIONS(self) -> None:  # noqa: N802
        self._proxy()

    def do_HEAD(self) -> None:  # noqa: N802
        self._proxy()


def main() -> int:
    if not HOST_WT:
        print("opencode-path-proxy: OPENCODE_WORKTREES_DIR unset — refusing to start", file=sys.stderr)
        return 1
    for _ in range(50):
        try:
            c = HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=1)
            c.request("GET", "/global/health")
            c.getresponse()
            c.close()
            break
        except Exception:  # noqa: BLE001
            select.select([], [], [], 0.2)
    else:
        print("opencode-path-proxy: warn: upstream not ready yet, starting anyway", file=sys.stderr)

    print(
        f"opencode-path-proxy: {LISTEN_HOST}:{LISTEN_PORT} → {UPSTREAM_HOST}:{UPSTREAM_PORT} "
        f"(rewrite {CONTAINER_WT} ↔ {HOST_WT})",
        file=sys.stderr,
    )
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), ProxyHandler)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
