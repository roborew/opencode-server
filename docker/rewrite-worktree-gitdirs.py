#!/usr/bin/env python3
"""Rewrite git worktree links to host paths, and finish deletes for Tower/local Git.

Create: OpenCode writes container paths (/var/opencode-xdg, /workspace/apps).
  We rewrite those to OPENCODE_WORKTREES_DIR / OPENCODE_APPS_DIR so Tower works.

Delete: OpenCode removes the checkout dir but often leaves .git/worktrees metadata
  (path mismatch after rewrite) → Tower still shows the worktree as prunable.
  `remove` / `prune` finishes git worktree remove + branch delete + prune.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
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


def to_host_worktree(path: str) -> str:
    if not HOST_WT:
        return path
    path = path.rstrip("/")
    if path.startswith(f"{CONTAINER_WT}/"):
        return f"{HOST_WT}/{path[len(CONTAINER_WT) + 1 :]}"
    if path == CONTAINER_WT:
        return HOST_WT
    return path


def to_container_worktree(path: str) -> str:
    if not HOST_WT:
        return path
    path = path.rstrip("/")
    if path.startswith(f"{HOST_WT}/"):
        return f"{CONTAINER_WT}/{path[len(HOST_WT) + 1 :]}"
    if path == HOST_WT:
        return CONTAINER_WT
    return path


def to_host_apps(text: str) -> str:
    if not HOST_APPS:
        return text
    if CONTAINER_APPS in text:
        return text.replace(CONTAINER_APPS, HOST_APPS)
    return text


def _run_git(repo: Path, args: list[str]) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            ["git", "-C", str(repo), *args],
            check=False,
            capture_output=True,
            text=True,
            timeout=60,
        )
        out = (proc.stdout or "") + (proc.stderr or "")
        return proc.returncode, out.strip()
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 1, str(exc)


def _iter_repos() -> list[Path]:
    apps_root = Path(CONTAINER_APPS)
    if not apps_root.is_dir() and HOST_APPS:
        apps_root = Path(HOST_APPS)
    if not apps_root.is_dir():
        return []
    repos: list[Path] = []
    try:
        for p in apps_root.iterdir():
            if not p.is_dir():
                continue
            repos.append(p)
            try:
                repos.extend([c for c in p.iterdir() if c.is_dir()])
            except OSError:
                pass
    except OSError as exc:
        print(f"rewrite-worktree-gitdirs: apps list failed: {exc}", file=sys.stderr)
        return []
    return [r for r in repos if (r / ".git").exists()]


def rewrite_gitdirs() -> int:
    if not HOST_WT and not HOST_APPS:
        return 0
    changed = 0

    for repo in _iter_repos():
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
                print(f"rewrite-worktree-gitdirs: gitdir -> {new}", file=sys.stderr)
            except OSError as exc:
                print(
                    f"rewrite-worktree-gitdirs: gitdir skip {gitdir_file}: {exc}",
                    file=sys.stderr,
                )

    wt_root = Path(CONTAINER_WT)
    if not wt_root.is_dir() and HOST_WT:
        wt_root = Path(HOST_WT)
    if wt_root.is_dir() and HOST_APPS:
        for git_file in wt_root.glob("*/*/.git"):
            if not git_file.is_file():
                continue
            try:
                content = git_file.read_text(encoding="utf-8")
            except OSError:
                continue
            new_content = to_host_apps(content)
            if CONTAINER_WT in new_content and HOST_WT:
                new_content = new_content.replace(CONTAINER_WT, HOST_WT)
            if new_content == content:
                continue
            try:
                git_file.write_text(new_content, encoding="utf-8")
                changed += 1
                print(
                    f"rewrite-worktree-gitdirs: worktree .git -> host ({git_file.parent.name})",
                    file=sys.stderr,
                )
            except OSError as exc:
                print(
                    f"rewrite-worktree-gitdirs: worktree .git skip {git_file}: {exc}",
                    file=sys.stderr,
                )

    return changed


def _infer_repo_for_name(name: str, project: str | None) -> Path | None:
    if project:
        p = Path(project)
        if (p / ".git").exists():
            return p
        # project may be container apps path
        if HOST_APPS and str(p).startswith(CONTAINER_APPS):
            mapped = Path(HOST_APPS + str(p)[len(CONTAINER_APPS) :])
            if (mapped / ".git").exists():
                return mapped
    marker = f"/.git/worktrees/{name}"
    for repo in _iter_repos():
        if (repo / ".git" / "worktrees" / name).is_dir():
            return repo
        # Also match via gitdir contents
        gitdir = repo / ".git" / "worktrees" / name / "gitdir"
        if gitdir.is_file():
            return repo
    # Scan worktree .git pointing at this name
    for root in (Path(CONTAINER_WT), Path(HOST_WT) if HOST_WT else Path()):
        if not root.is_dir():
            continue
        for git_file in root.glob(f"*/{name}/.git"):
            try:
                content = git_file.read_text(encoding="utf-8")
            except OSError:
                continue
            if marker in content or f"/worktrees/{name}" in content:
                # gitdir: /path/to/repo/.git/worktrees/name
                for line in content.splitlines():
                    if line.startswith("gitdir:"):
                        g = line.split(":", 1)[1].strip()
                        if marker in g:
                            repo = Path(g[: g.index("/.git/worktrees/")])
                            if (repo / ".git").exists():
                                return repo
    return None


def _is_worktree_root(path: str) -> bool:
    """True if path is under the OpenCode worktree store (safe to delete)."""
    path = path.rstrip("/")
    for root in (CONTAINER_WT, HOST_WT):
        if root and (path == root or path.startswith(root + "/")):
            return True
    return False


def _is_protected_project_root(path: str) -> bool:
    """Refuse to delete main app checkouts (dual /workspace + host mounts).

    OpenCode sometimes lists `/workspace/apps/<repo>` as a "sandbox" of the
    host-path project. Both paths are the same inode — deleting that
    "sandbox" wipes the real repo.
    """
    path = (path or "").rstrip("/")
    if not path or _is_worktree_root(path):
        return False
    for root in (CONTAINER_APPS, HOST_APPS):
        if not root:
            continue
        if path == root:
            return True
        if path.startswith(root + "/"):
            # Any path under apps that is not a worktree store is a project root
            # (or nested app). Never rm -rf these from our cleanup helpers.
            return True
    return False


def _delete_branch(repo: Path, branch: str) -> bool:
    code, out = _run_git(repo, ["branch", "-D", branch])
    if code == 0:
        print(
            f"rewrite-worktree-gitdirs: git branch -D {branch} -> {out}",
            file=sys.stderr,
        )
        return True
    return False


def _active_worktree_branches(repo: Path) -> set[str]:
    """Branch names currently checked out in any worktree (porcelain)."""
    code, out = _run_git(repo, ["worktree", "list", "--porcelain"])
    if code != 0:
        return set()
    branches: set[str] = set()
    for line in out.splitlines():
        if line.startswith("branch "):
            ref = line[len("branch ") :].strip()
            if ref.startswith("refs/heads/"):
                branches.add(ref[len("refs/heads/") :])
            elif ref and ref != "(detached)":
                branches.add(ref)
    return branches


def gc_orphan_opencode_branches(repo: Path | None = None) -> int:
    """Delete local opencode/* branches that no longer have a worktree.

    OpenCode/git worktree remove leaves the branch behind. Workspace delete
    often finishes the checkout before our prune sees an orphan admin dir,
    so we sweep by branch name instead.
    """
    repos = [repo] if repo is not None else _iter_repos()
    deleted = 0
    for r in repos:
        if r is None or not (r / ".git").exists():
            continue
        active = _active_worktree_branches(r)
        code, out = _run_git(r, ["branch", "--list", "opencode/*"])
        if code != 0:
            continue
        for line in out.splitlines():
            branch = line.strip().lstrip("* ").strip()
            if not branch.startswith("opencode/"):
                continue
            if branch in active:
                continue
            if _delete_branch(r, branch):
                deleted += 1
        # Also drop bare workspace-name branches if they match a gone worktree
        # admin name under .git/worktrees (no checkout left).
        wt_admin = r / ".git" / "worktrees"
        if wt_admin.is_dir():
            try:
                admin_names = {e.name for e in wt_admin.iterdir() if e.is_dir()}
            except OSError:
                admin_names = set()
        else:
            admin_names = set()
        # Names of missing checkouts already handled in prune; for branches
        # named exactly like a former worktree dir with no admin left, we
        # only auto-delete the opencode/ prefix above (safer).
        _ = admin_names
    return deleted


def remove_worktree(directory: str, project: str | None = None) -> int:
    directory = (directory or "").rstrip("/")
    if not directory:
        print("rewrite-worktree-gitdirs: remove requires --directory", file=sys.stderr)
        return 1

    if _is_protected_project_root(directory):
        print(
            f"rewrite-worktree-gitdirs: refuse remove of project root {directory}",
            file=sys.stderr,
        )
        return 2

    cont_dir = to_container_worktree(directory)
    host_dir = to_host_worktree(cont_dir if cont_dir.startswith(CONTAINER_WT) else directory)
    # If directory was already host path, keep it
    if HOST_WT and directory.startswith(HOST_WT):
        host_dir = directory
        cont_dir = to_container_worktree(directory)

    for candidate in (directory, host_dir, cont_dir):
        if _is_protected_project_root(candidate):
            print(
                f"rewrite-worktree-gitdirs: refuse remove of project root {candidate}",
                file=sys.stderr,
            )
            return 2

    name = Path(host_dir).name or Path(cont_dir).name
    if not name:
        print("rewrite-worktree-gitdirs: remove: empty name", file=sys.stderr)
        return 1

    repo = _infer_repo_for_name(name, project)
    if repo is None:
        print(
            f"rewrite-worktree-gitdirs: remove: cannot locate repo for {name}",
            file=sys.stderr,
        )
        # Still try to delete leftover dirs
        for path in {host_dir, cont_dir}:
            p = Path(path)
            if p.is_dir():
                shutil.rmtree(p, ignore_errors=True)
                print(f"rewrite-worktree-gitdirs: rmdir {path}", file=sys.stderr)
        return 1

    for path in (host_dir, cont_dir, directory):
        code, out = _run_git(repo, ["worktree", "remove", "--force", path])
        print(
            f"rewrite-worktree-gitdirs: git worktree remove {path} -> {code} {out}",
            file=sys.stderr,
        )

    code, out = _run_git(repo, ["worktree", "prune"])
    print(f"rewrite-worktree-gitdirs: git worktree prune -> {code} {out}", file=sys.stderr)

    # Drop OpenCode-managed branch if present
    for branch in (f"opencode/{name}", name):
        _delete_branch(repo, branch)

    for path in {host_dir, cont_dir, directory}:
        p = Path(path)
        if p.is_dir():
            shutil.rmtree(p, ignore_errors=True)
            print(f"rewrite-worktree-gitdirs: rmdir {path}", file=sys.stderr)

    # Remove stale admin dir if prune left anything
    admin = repo / ".git" / "worktrees" / name
    if admin.exists():
        shutil.rmtree(admin, ignore_errors=True)
        print(f"rewrite-worktree-gitdirs: rmdir admin {admin}", file=sys.stderr)

    return 0


def prune_orphans() -> int:
    """Remove prunable / missing-checkout worktree admin entries across apps."""
    cleaned = 0
    for repo in _iter_repos():
        code, out = _run_git(repo, ["worktree", "list", "--porcelain"])
        if code != 0:
            # Still try branch GC — list can fail while branches remain.
            cleaned += gc_orphan_opencode_branches(repo)
            continue
        # Also force-prune anything git already marks prunable
        _run_git(repo, ["worktree", "prune", "--verbose"])

        # Find admin dirs whose checkout path is missing
        wt_admin = repo / ".git" / "worktrees"
        if wt_admin.is_dir():
            try:
                entries = list(wt_admin.iterdir())
            except OSError:
                entries = []
            for entry in entries:
                gitdir_file = entry / "gitdir"
                if not gitdir_file.is_file():
                    continue
                try:
                    target = gitdir_file.read_text(encoding="utf-8").strip()
                except OSError:
                    continue
                # gitdir points at worktree/.git file — parent is checkout
                if Path(target).name == ".git":
                    checkout = Path(target).parent
                else:
                    checkout = Path(target)
                if checkout.exists():
                    continue
                # Missing checkout → finish remove by name
                print(
                    f"rewrite-worktree-gitdirs: prune orphan {entry.name} (missing {checkout})",
                    file=sys.stderr,
                )
                remove_worktree(str(checkout), str(repo))
                cleaned += 1

        # Branch GC lives in `scrub` (delayed) so we do not race OpenCode's own
        # `git branch -D` during DELETE and surface WorktreeRemoveFailedError.
    return cleaned


def scrub_sandboxes_db() -> int:
    """Drop dual-mount project roots from project.sandboxes in the OpenCode DB.

    OpenCode sometimes records `/workspace/apps/<repo>` as a sandbox of the
    host-path project (same inode). That makes Desktop offer a delete that
    would wipe the real checkout. We cannot stop OpenCode from writing it,
    but we can scrub it out of the DB so the UI stops listing it.
    """
    candidates = [
        Path("/var/lib/opencode-data/opencode.db"),
        Path("/var/opencode-xdg/opencode/opencode.db"),
    ]
    db_path = next((p for p in candidates if p.is_file()), None)
    if db_path is None:
        return 0

    try:
        import sqlite3
    except ImportError:
        return 0

    cleaned = 0
    try:
        con = sqlite3.connect(str(db_path), timeout=5)
        con.execute("PRAGMA busy_timeout=5000")
        rows = con.execute("SELECT id, worktree, sandboxes FROM project").fetchall()
        for pid, worktree, raw in rows:
            try:
                sandboxes = json.loads(raw or "[]")
            except json.JSONDecodeError:
                continue
            if not isinstance(sandboxes, list) or not sandboxes:
                continue
            kept = [s for s in sandboxes if not _is_protected_project_root(str(s))]
            # Also drop sandboxes that are the same path identity as the project
            # worktree (string twin), even if mapping missed.
            wt = (worktree or "").rstrip("/")
            twin = None
            if HOST_APPS and wt.startswith(HOST_APPS + "/"):
                twin = CONTAINER_APPS + wt[len(HOST_APPS) :]
            elif wt.startswith(CONTAINER_APPS + "/"):
                if HOST_APPS:
                    twin = HOST_APPS + wt[len(CONTAINER_APPS) :]
            if twin:
                kept = [s for s in kept if str(s).rstrip("/") != twin]

            # Drop sandboxes whose checkout no longer exists (workspace delete
            # often clears git but leaves the path in project.sandboxes).
            existing: list[str] = []
            for s in kept:
                p = Path(str(s))
                # Resolve twin mount: container WT ↔ host WT
                candidates = [p]
                sp = str(s).rstrip("/")
                if HOST_WT and sp.startswith(CONTAINER_WT + "/"):
                    candidates.append(Path(HOST_WT + sp[len(CONTAINER_WT) :]))
                elif HOST_WT and sp.startswith(HOST_WT + "/"):
                    candidates.append(Path(CONTAINER_WT + sp[len(HOST_WT) :]))
                if any(c.exists() for c in candidates):
                    existing.append(str(s))
            kept = existing

            if kept == sandboxes:
                continue
            con.execute(
                "UPDATE project SET sandboxes=?, time_updated=? WHERE id=?",
                (json.dumps(kept), int(time.time() * 1000), pid),
            )
            cleaned += 1
            print(
                f"rewrite-worktree-gitdirs: scrub sandboxes {pid[:12]} "
                f"{sandboxes} -> {kept}",
                file=sys.stderr,
            )
        if cleaned:
            con.commit()
        con.close()
    except OSError as exc:
        print(f"rewrite-worktree-gitdirs: scrub db skip: {exc}", file=sys.stderr)
        return 0
    except Exception as exc:  # noqa: BLE001 — best-effort; never crash plugin
        print(f"rewrite-worktree-gitdirs: scrub db error: {exc}", file=sys.stderr)
        return 0
    return cleaned


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        nargs="?",
        default="rewrite",
        choices=["rewrite", "remove", "prune", "scrub"],
    )
    parser.add_argument("--directory", default="")
    parser.add_argument("--project", default="")
    args = parser.parse_args()

    t0 = time.time()
    if args.command == "remove":
        rc = remove_worktree(args.directory, args.project or None)
        print(
            f"rewrite-worktree-gitdirs: remove done in {time.time() - t0:.2f}s",
            file=sys.stderr,
        )
        return rc

    if args.command == "prune":
        n = prune_orphans()
        scrub_sandboxes_db()
        print(
            f"rewrite-worktree-gitdirs: prune orphans={n} in {time.time() - t0:.2f}s",
            file=sys.stderr,
        )
        return 0

    if args.command == "scrub":
        n = scrub_sandboxes_db()
        # Scrub often runs right after workspace delete — also GC branches.
        branches = gc_orphan_opencode_branches()
        print(
            f"rewrite-worktree-gitdirs: scrub projects={n} branches={branches} "
            f"in {time.time() - t0:.2f}s",
            file=sys.stderr,
        )
        return 0

    n = rewrite_gitdirs()
    # Always sweep orphans after rewrite (covers failed OpenCode deletes)
    orphans = prune_orphans()
    scrub_sandboxes_db()
    print(
        f"rewrite-worktree-gitdirs: rewrites={n} orphans={orphans} in {time.time() - t0:.2f}s",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
