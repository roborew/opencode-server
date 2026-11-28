"""In-container smoke client for the code-index image (run with python3 -I).

Usage: code-index-smoke.py <repo_path> <symbol>      full smoke (auth, tools, index, search)
       code-index-smoke.py find <repo_path> <symbol> exit 0 if the indexed repo has the symbol
       code-index-smoke.py projects                  print indexed project roots
Talks to mcp-proxy on 127.0.0.1:8080 with the token from CODE_INDEX_TOKEN and
prints one `ok <check>` line per passing check; exits non-zero on the first failure.
"""
import json
import os
import sys
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8080"
TOKEN = os.environ["CODE_INDEX_TOKEN"]
MODE = sys.argv[1] if sys.argv[1] in ("find", "projects") else "smoke"
ARGS = sys.argv[2:] if MODE != "smoke" else sys.argv[1:]
EXPECTED_TOOLS = {"index_repository", "search_graph", "search_code", "trace_path", "list_projects", "delete_project"}


def request(method, path, body=None, sid=None, token=TOKEN):
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if token:
        headers["Authorization"] = "Bearer " + token
    if sid:
        headers["Mcp-Session-Id"] = sid
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        resp = urllib.request.urlopen(req, timeout=120)
    except urllib.error.HTTPError as err:
        return err.code, None, None
    raw = resp.read().decode()
    payload = None
    for line in raw.splitlines():
        if line.startswith("data:"):
            payload = json.loads(line[5:])
    if payload is None and raw.strip().startswith("{"):
        payload = json.loads(raw)
    return resp.status, resp.headers.get("Mcp-Session-Id") or sid, payload


def check(name, condition, detail=""):
    if not condition:
        sys.exit(f"FAIL {name} {detail}")
    print(f"ok {name}")


INIT = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "image-preflight", "version": "0"}}}

def session():
    status, sid, _ = request("POST", "/mcp", INIT)
    check("mcp accepts the token", status == 200 and sid, f"status={status}")
    request("POST", "/mcp", {"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    return sid


def call(sid, call_id, name, arguments):
    _, _, reply = request("POST", "/mcp", {"jsonrpc": "2.0", "id": call_id, "method": "tools/call",
                                           "params": {"name": name, "arguments": arguments}}, sid)
    if not reply or "result" not in reply:
        sys.exit(f"FAIL {name} returned {reply}")
    return reply["result"]["content"][0]["text"]


def project_roots(sid):
    listing = json.loads(call(sid, 10, "list_projects", {"format": "json", "limit": 500}))
    return {p["root_path"].rstrip("/"): p["name"] for p in listing.get("projects") or []}


if MODE == "projects":
    print("\n".join(sorted(project_roots(session()))))
    sys.exit(0)
if MODE == "find":
    repo, symbol = ARGS
    sid = session()
    name = project_roots(sid).get(repo.rstrip("/"))
    sys.exit(0 if name and symbol in call(sid, 11, "search_graph", {"project": name, "name_pattern": symbol}) else 1)

REPO, SYMBOL = ARGS
check("healthz rejects a missing token", request("GET", "/healthz", token="")[0] == 401)
check("mcp rejects a missing token", request("POST", "/mcp", INIT, token="")[0] == 401)
check("mcp rejects a wrong token", request("POST", "/mcp", INIT, token="x" * 48)[0] == 401)
sid = session()

_, _, listing = request("POST", "/mcp", {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, sid)
names = {tool["name"] for tool in listing["result"]["tools"]}
check("tools/list has the expected tools", EXPECTED_TOOLS <= names, f"missing={sorted(EXPECTED_TOOLS - names)}")


indexed = json.loads(call(sid, 3, "index_repository", {"repo_path": REPO, "mode": "full"}))
check("index_repository indexes the read-only fixture", indexed.get("status") == "indexed", json.dumps(indexed)[:200])
project = indexed["project"]
check("search_graph finds the fixture symbol by name", SYMBOL in call(sid, 4, "search_graph", {"project": project, "name_pattern": SYMBOL}))
check("search_graph finds it from a natural-language query", SYMBOL in call(sid, 5, "search_graph", {"project": project, "query": "invoice total"}))
