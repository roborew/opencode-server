"""code-index refresh-and-prune loop (config repo ADR 0017, plan Task 8).

Upstream's watcher only follows the MCP session's working-dir project and never
forgets a removed worktree. This loop runs next to mcp-proxy and, every
CODE_INDEX_REFRESH_SECONDS (default 30; 0 disables it), for every project that
was already indexed (indexing stays on request):

- re-indexes it when its git HEAD or working-tree state changed (incremental,
  about a second on an unchanged repo);
- deletes it when its root is gone but the root's parent still has other
  entries, so a removed slice worktree disappears while an empty or missing
  mount deletes nothing (a project in an emptied parent waits for a sibling).

It talks to the server through mcp-proxy, so one stdio child owns the store.
The bearer comes from MCP_PROXY_AUTH_TOKEN and is never logged.
"""
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8080"
TOKEN = os.environ.get("MCP_PROXY_AUTH_TOKEN", "")
INTERVAL = int(os.environ.get("CODE_INDEX_REFRESH_SECONDS", "30") or "30")
GIT_TIMEOUT = 20


def log(msg):
    print(f"code-index-refresh: {msg}", flush=True)


class Client:
    def __init__(self):
        self.sid = None
        self.next_id = 1

    def _post(self, body, timeout=600):
        headers = {"Content-Type": "application/json",
                   "Accept": "application/json, text/event-stream",
                   "Authorization": "Bearer " + TOKEN}
        if self.sid:
            headers["Mcp-Session-Id"] = self.sid
        req = urllib.request.Request(BASE + "/mcp", json.dumps(body).encode(), headers)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            self.sid = resp.headers.get("Mcp-Session-Id") or self.sid
            raw = resp.read().decode()
        payload = None
        for line in raw.splitlines():
            if line.startswith("data:"):
                payload = json.loads(line[5:])
        if payload is None and raw.strip().startswith("{"):
            payload = json.loads(raw)
        return payload

    def open(self):
        self._post({"jsonrpc": "2.0", "id": 0, "method": "initialize",
                    "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                               "clientInfo": {"name": "code-index-refresh", "version": "1"}}})
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def close(self):
        if not self.sid:
            return
        headers = {"Authorization": "Bearer " + TOKEN, "Mcp-Session-Id": self.sid}
        try:
            urllib.request.urlopen(urllib.request.Request(BASE + "/mcp", headers=headers, method="DELETE"), timeout=10).close()
        except Exception:
            pass
        self.sid = None

    def call(self, name, arguments):
        self.next_id += 1
        reply = self._post({"jsonrpc": "2.0", "id": self.next_id, "method": "tools/call",
                            "params": {"name": name, "arguments": arguments}})
        result = (reply or {}).get("result") or {}
        if not result or result.get("isError"):
            raise RuntimeError(f"{name} failed: {json.dumps(reply)[:300]}")
        return result["content"][0]["text"]

    def projects(self):
        found, offset = [], 0
        while True:
            page = json.loads(self.call("list_projects", {"format": "json", "limit": 500, "offset": offset}))
            found.extend(page.get("projects") or [])
            if not page.get("has_more"):
                return found
            offset += page.get("returned") or 500


def git(root, *args):
    return subprocess.run(["git", "-C", root, *args], capture_output=True,
                          timeout=GIT_TIMEOUT, check=True).stdout


def digest(root):
    """HEAD plus the working-tree state, including edits to already-dirty files."""
    h = hashlib.sha256()
    try:
        h.update(git(root, "rev-parse", "HEAD"))
        status = git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all")
    except (subprocess.SubprocessError, OSError):
        return None  # not a git repo (or git timed out): leave it as indexed
    h.update(status)
    entries = status.split(b"\0")
    for entry in entries:
        path = entry[3:]
        if not path:
            continue
        try:
            st = os.stat(os.path.join(root.encode(), path))
            h.update(b"%s %d %d\n" % (path, st.st_mtime_ns, st.st_size))
        except OSError:
            h.update(b"%s gone\n" % path)
    return h.hexdigest()


def parent_is_live(root):
    """A removed worktree leaves siblings behind; an empty or missing parent may
    be a mount whose host source is absent, so it never counts as proof."""
    parent = os.path.dirname(root)
    try:
        with os.scandir(parent) as entries:
            return any(True for _ in entries)
    except OSError:
        return False


def refresh_project(client, seen, name, root):
    if not os.path.isdir(root):
        if parent_is_live(root):
            client.call("delete_project", {"project": name})
            seen.pop(name, None)
            log(f"pruned {name} (root removed)")
        else:
            log(f"prune skipped for {name}: {os.path.dirname(root)} is empty or missing (mount may be down)")
        return
    state = digest(root)
    if state is None or seen.get(name) == state:
        return
    started = time.monotonic()
    client.call("index_repository", {"repo_path": root, "name": name})
    if digest(root) == state:
        seen[name] = state
    else:
        seen.pop(name, None)  # changed while indexing: index again next cycle
    log(f"refreshed {name} in {time.monotonic() - started:.1f}s")


def cycle(client, seen):
    client.open()
    try:
        listed = set()
        for proj in client.projects():
            name, root = proj.get("name"), (proj.get("root_path") or "").rstrip("/")
            if not name or not root:
                continue
            listed.add(name)
            # One failing project (for example an upstream resource limit) must
            # not starve the rest; its marker stays, so it is retried next cycle.
            try:
                refresh_project(client, seen, name, root)
            except (RuntimeError, ValueError, subprocess.SubprocessError) as err:
                log(f"{name}: {str(err)[:300]}")
        for name in set(seen) - listed:
            seen.pop(name, None)
    finally:
        client.close()


def main():
    if INTERVAL <= 0:
        log("disabled (CODE_INDEX_REFRESH_SECONDS=0)")
        return 0
    if not TOKEN:
        log("no MCP_PROXY_AUTH_TOKEN; not starting")
        return 1
    seen = {}
    while True:
        time.sleep(INTERVAL)
        try:
            cycle(Client(), seen)
        except (urllib.error.URLError, OSError, ValueError, RuntimeError, subprocess.SubprocessError) as err:
            log(f"cycle skipped: {str(err)[:300]}")


if __name__ == "__main__":
    sys.exit(main())
