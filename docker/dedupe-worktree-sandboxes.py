#!/usr/bin/env python3
"""Normalize sandboxes + rewrite git worktree metadata to host paths for local Git.

Server-canonical worktree path: OPENCODE_CONTAINER_WORKTREE
  (/var/opencode-xdg/opencode/worktree) — bind of OPENCODE_WORKTREES_DIR

Host paths (also bind-mounted same-path into the container):
  OPENCODE_WORKTREES_DIR  — worktree checkouts (host-visible for local Git)
  OPENCODE_APPS_DIR       — main repos (replaces /workspace/apps in .git files)

OpenCode registers only the container worktree path (no duplicate sandboxes).
Git metadata is rewritten to host paths so local `git worktree` / Git GUIs can
resolve linked worktrees on the Mac. Same-path binds keep git working inside
the container after that rewrite.
"""
from __future__ import annotations

import json
import os
import sqlite3
import sys
import time
from pathlib import Path


CONTAINER_WT = (
    os.environ.get("OPENCODE_CONTAINER_WORKTREE", "").rstrip("/")
    or "/var/opencode-xdg/opencode/worktree"
)
HOST_WT = os.environ.get("OPENCODE_WORKTREES_DIR", "").rstrip("/")
CONTAINER_APPS = "/workspace/apps"
HOST_APPS = os.environ.get("OPENCODE_APPS_DIR", "").rstrip("/")
LEGACY_ROOT = "/root/.local/share/opencode/worktree"


def to_container(path: str) -> str:
    if HOST_WT and path.startswith(f"{HOST_WT}/"):
        return f"{CONTAINER_WT}/{path[len(HOST_WT) + 1 :]}"
    if HOST_WT and path == HOST_WT:
        return CONTAINER_WT
    if path.startswith(f"{LEGACY_ROOT}/"):
        return f"{CONTAINER_WT}/{path[len(LEGACY_ROOT) + 1 :]}"
    if path == LEGACY_ROOT:
        return CONTAINER_WT
    return path


def to_host_worktree(path: str) -> str:
    if not HOST_WT:
        return path
    if path.startswith(f"{CONTAINER_WT}/"):
        return f"{HOST_WT}/{path[len(CONTAINER_WT) + 1 :]}"
    if path == CONTAINER_WT:
        return HOST_WT
    if path.startswith(f"{LEGACY_ROOT}/"):
        return f"{HOST_WT}/{path[len(LEGACY_ROOT) + 1 :]}"
    if path == LEGACY_ROOT:
        return HOST_WT
    return path


def to_host_apps(path: str) -> str:
    if not HOST_APPS:
        return path
    if path.startswith(f"{CONTAINER_APPS}/"):
        return f"{HOST_APPS}/{path[len(CONTAINER_APPS) + 1 :]}"
    if path == CONTAINER_APPS:
        return HOST_APPS
    return path


def normalize_sandboxes(paths: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for path in paths:
        canon = to_container(path)
        if canon in seen:
            continue
        seen.add(canon)
        out.append(canon)
    return out


def rewrite_git_metadata() -> int:
    """Point git worktree links at host paths (local Git + same-path binds in container)."""
    if not HOST_WT:
        return 0
    changed = 0

    # 1) Main-repo .git/worktrees/*/gitdir → host worktree/.git
    apps = Path(CONTAINER_APPS)
    if apps.is_dir():
        try:
            repos = [p for p in apps.iterdir() if p.is_dir()]
            # Also one level deeper (org/repo layout like lap-mapper/lap-mapper-web)
            nested = []
            for repo in repos:
                try:
                    nested.extend([p for p in repo.iterdir() if p.is_dir()])
                except OSError:
                    pass
            repos = repos + nested
        except OSError as exc:
            print(f"dedupe-worktree-sandboxes: apps list failed: {exc}", file=sys.stderr)
            repos = []

        for repo in repos:
            wt_root = repo / ".git" / "worktrees"
            if not wt_root.is_dir():
                continue
            try:
                children = list(wt_root.iterdir())
            except OSError:
                continue
            for entry in children:
                gitdir_file = entry / "gitdir"
                if not gitdir_file.is_file():
                    continue
                try:
                    current = gitdir_file.read_text(encoding="utf-8").strip()
                except OSError:
                    continue
                new = to_host_worktree(current)
                if new == current:
                    continue
                try:
                    gitdir_file.write_text(new + "\n", encoding="utf-8")
                    changed += 1
                    print(f"dedupe-worktree-sandboxes: gitdir -> {new}", file=sys.stderr)
                except OSError as exc:
                    print(
                        f"dedupe-worktree-sandboxes: gitdir skip {gitdir_file}: {exc}",
                        file=sys.stderr,
                    )

    # 2) Each worktree's .git file → host apps .git/worktrees/<name>
    container_wt = Path(CONTAINER_WT)
    if container_wt.is_dir() and HOST_APPS:
        for git_file in container_wt.glob("*/*/.git"):
            if not git_file.is_file():
                continue
            try:
                content = git_file.read_text(encoding="utf-8")
            except OSError:
                continue
            new_content = content
            # Replace container apps prefix inside gitdir: lines
            if CONTAINER_APPS in new_content:
                new_content = new_content.replace(CONTAINER_APPS, HOST_APPS)
            if new_content == content:
                continue
            try:
                git_file.write_text(new_content, encoding="utf-8")
                changed += 1
                print(f"dedupe-worktree-sandboxes: worktree .git -> host apps ({git_file.parent.name})", file=sys.stderr)
            except OSError as exc:
                print(f"dedupe-worktree-sandboxes: worktree .git skip {git_file}: {exc}", file=sys.stderr)

    return changed


def find_db() -> Path | None:
    candidates = [
        Path("/var/lib/opencode-data/opencode.db"),
        Path(f"{os.environ.get('OPENCODE_CONTAINER_XDG', '/var/opencode-xdg')}/opencode/opencode.db"),
        Path("/root/.local/share/opencode/opencode.db"),
    ]
    for path in candidates:
        try:
            if path.exists():
                return path.resolve() if path.is_symlink() else path
        except OSError:
            continue
    return None


def _run_git(repo: str, args: list[str]) -> tuple[int, str]:
    import subprocess

    try:
        proc = subprocess.run(
            ["git", "-C", repo, *args],
            check=False,
            capture_output=True,
            text=True,
            timeout=60,
        )
        out = (proc.stdout or "") + (proc.stderr or "")
        return proc.returncode, out.strip()
    except Exception as exc:  # noqa: BLE001
        return 1, str(exc)


def remove_worktree(directory: str, project_dir: str | None = None) -> int:
    """Finish git cleanup after OpenCode delete.

    OpenCode matches container paths; git worktree list uses host paths (local Git).
    That miss leaves prunable worktrees + branches behind. Clean both up here.
    """
    import shutil

    cont_dir = to_container(directory)
    host_dir = to_host_worktree(cont_dir)
    name = Path(cont_dir.rstrip("/")).name
    if not name:
        print("dedupe-worktree-sandboxes: remove: empty name", file=sys.stderr)
        return 1

    branch = f"opencode/{name}"
    repo = (project_dir or "").rstrip("/")
    if repo.startswith(HOST_APPS + "/") and HOST_APPS:
        # Prefer container apps path for git -C inside the container
        repo = f"{CONTAINER_APPS}/{repo[len(HOST_APPS) + 1 :]}"
    if not repo:
        # Infer from any still-present worktree .git file, else scan apps
        for candidate in (host_dir, cont_dir):
            gitfile = Path(candidate) / ".git"
            if gitfile.is_file():
                try:
                    text = gitfile.read_text(encoding="utf-8").strip()
                except OSError:
                    text = ""
                if text.startswith("gitdir:"):
                    gitdir = text.split(":", 1)[1].strip()
                    # .../repo/.git/worktrees/name -> repo
                    marker = "/.git/worktrees/"
                    if marker in gitdir:
                        repo = gitdir.split(marker, 1)[0]
                        if repo.startswith(HOST_APPS + "/") and HOST_APPS:
                            repo = f"{CONTAINER_APPS}/{repo[len(HOST_APPS) + 1 :]}"
                        break
    if not repo or not Path(repo).is_dir():
        print(
            f"dedupe-worktree-sandboxes: remove: cannot locate repo for {name}",
            file=sys.stderr,
        )
        # Still try to delete directories
        for path in {cont_dir, host_dir}:
            p = Path(path)
            if p.exists():
                shutil.rmtree(p, ignore_errors=True)
        return 1

    # Try remove with whatever path git knows (usually host after our rewrite)
    removed = False
    for path in (host_dir, cont_dir):
        code, out = _run_git(repo, ["worktree", "remove", "--force", path])
        print(
            f"dedupe-worktree-sandboxes: git worktree remove {path} -> {code} {out}",
            file=sys.stderr,
        )
        if code == 0:
            removed = True
            break

    if not removed:
        code, out = _run_git(repo, ["worktree", "prune"])
        print(
            f"dedupe-worktree-sandboxes: git worktree prune -> {code} {out}",
            file=sys.stderr,
        )

    # Delete branch even if worktree remove only pruned
    code, out = _run_git(repo, ["branch", "-D", branch])
    print(
        f"dedupe-worktree-sandboxes: git branch -D {branch} -> {code} {out}",
        file=sys.stderr,
    )

    for path in {cont_dir, host_dir}:
        p = Path(path)
        if p.exists():
            shutil.rmtree(p, ignore_errors=True)
            print(f"dedupe-worktree-sandboxes: rmdir {path}", file=sys.stderr)

    return 0


def normalize_db() -> int:
    db_path = find_db()
    if not db_path or not db_path.is_file():
        return 0

    conn = sqlite3.connect(str(db_path), timeout=5)
    changed = 0
    try:
        rows = conn.execute("SELECT id, sandboxes FROM project").fetchall()
        for project_id, raw in rows:
            try:
                sandboxes = json.loads(raw or "[]")
            except json.JSONDecodeError:
                continue
            if not isinstance(sandboxes, list):
                continue
            paths = [s for s in sandboxes if isinstance(s, str)]
            next_boxes = normalize_sandboxes(paths)
            if next_boxes == sandboxes:
                continue
            conn.execute(
                "UPDATE project SET sandboxes = ?, time_updated = ? WHERE id = ?",
                (json.dumps(next_boxes), int(time.time() * 1000), project_id),
            )
            changed += 1
            print(
                f"dedupe-worktree-sandboxes: {project_id}: {sandboxes} -> {next_boxes}",
                file=sys.stderr,
            )

        # Normalize session.directory path variants to the container worktree path
        # so lookups via the proxy (host → container) always hit.
        sess_changed = 0
        try:
            sessions = conn.execute(
                "SELECT id, directory FROM session WHERE directory LIKE ? OR directory LIKE ?",
                (f"{HOST_WT}/%", f"{LEGACY_ROOT}/%"),
            ).fetchall()
        except sqlite3.Error:
            sessions = []
        for sid, directory in sessions:
            if not isinstance(directory, str):
                continue
            new_dir = to_container(directory)
            if new_dir == directory:
                continue
            conn.execute("UPDATE session SET directory = ? WHERE id = ?", (new_dir, sid))
            sess_changed += 1
        if sess_changed:
            print(
                f"dedupe-worktree-sandboxes: rewrote {sess_changed} session directories",
                file=sys.stderr,
            )
            changed += sess_changed

        if changed:
            conn.commit()
    finally:
        conn.close()
    return changed


def main(argv: list[str] | None = None) -> int:
    args = list(argv if argv is not None else sys.argv[1:])
    if args and args[0] == "remove":
        # remove --directory PATH [--project PATH]
        directory = os.environ.get("OPENCODE_REMOVE_DIRECTORY", "")
        project = os.environ.get("OPENCODE_REMOVE_PROJECT", "")
        i = 1
        while i < len(args):
            if args[i] == "--directory" and i + 1 < len(args):
                directory = args[i + 1]
                i += 2
            elif args[i] == "--project" and i + 1 < len(args):
                project = args[i + 1]
                i += 2
            else:
                i += 1
        if not directory:
            print("dedupe-worktree-sandboxes: remove requires --directory", file=sys.stderr)
            return 1
        return remove_worktree(directory, project or None)

    t0 = time.time()
    n = rewrite_git_metadata()
    print(
        f"dedupe-worktree-sandboxes: git metadata rewrites={n} in {time.time() - t0:.2f}s",
        file=sys.stderr,
    )
    normalize_db()
    print(
        f"dedupe-worktree-sandboxes: finished in {time.time() - t0:.2f}s",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
