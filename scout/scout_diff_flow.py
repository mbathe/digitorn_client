"""Scout: full diff / approval workflow on digitorn-builder.

Exercises the cycle described in the daemon contract:
  1. Agent writes a file (WsWrite) → resource_patched + mirror
  2. GET /workspace/files/{path}?include_baseline=true
     → { path, payload, baseline, unified_diff_pending }
  3. POST /workspace/files/approve → baseline := content, diff clears
  4. Agent edits again → new diff
  5. POST /workspace/files/reject → restores baseline
  6. GET /workspace/code-snapshot → per-file counters + git_status

Captures every shape so the client can be wired without guessing.
"""
import json
import os
import sys
import time
import uuid

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

sys.path.insert(0, r"C:\Users\ASUS\Documents\digitorn-bridge\packages")

from digitorn.testing import DevClient  # noqa: E402
from digitorn.testing.models import SessionHandle  # noqa: E402


def _p(v):
    return json.dumps(v, indent=2, default=str, ensure_ascii=False)


def _fetch_file(client, app_id, sid, path, include_baseline=True):
    q = "?include_baseline=true" if include_baseline else ""
    r = client._get(
        f"/api/apps/{app_id}/sessions/{sid}/workspace/files/{path}{q}"
    )
    print(f"\n[HTTP {r.status_code}] GET /workspace/files/{path}"
          f"{q}")
    try:
        data = r.json()
        # Truncate giant content fields for readability
        if isinstance(data, dict) and "data" in data:
            d = data["data"]
            if isinstance(d, dict):
                payload = d.get("payload")
                if isinstance(payload, dict) and "content" in payload:
                    c = payload["content"]
                    if isinstance(c, str) and len(c) > 200:
                        payload["content"] = c[:200] + f"... (truncated {len(c)}B)"
                if "baseline" in d and isinstance(d["baseline"], str) and len(d["baseline"]) > 200:
                    d["baseline"] = d["baseline"][:200] + f"... (truncated {len(d['baseline'])}B)"
        print(_p(data))
        return data
    except Exception:
        print(r.text[:500])
        return None


def _snapshot(client, app_id, sid):
    r = client._get(
        f"/api/apps/{app_id}/sessions/{sid}/workspace/code-snapshot"
    )
    print(f"\n[HTTP {r.status_code}] GET /workspace/code-snapshot")
    try:
        data = r.json()
        # Trim enormous trees
        if isinstance(data, dict) and "data" in data:
            d = data["data"]
            if isinstance(d, dict) and "files" in d:
                files = d["files"]
                if isinstance(files, dict) and len(files) > 5:
                    keys = list(files.keys())[:5]
                    d["files"] = {k: files[k] for k in keys}
                    d["__truncated__"] = f"{len(files) - 5} more"
        print(_p(data))
        return data
    except Exception:
        print(r.text[:500])
        return None


def _approve(client, app_id, sid, path):
    r = client._post(
        f"/api/apps/{app_id}/sessions/{sid}/workspace/files/approve",
        json={"path": path},
    )
    print(f"\n[HTTP {r.status_code}] POST /workspace/files/approve {{path={path}}}")
    try:
        print(_p(r.json()))
    except Exception:
        print(r.text[:500])


def _reject(client, app_id, sid, path):
    r = client._post(
        f"/api/apps/{app_id}/sessions/{sid}/workspace/files/reject",
        json={"path": path},
    )
    print(f"\n[HTTP {r.status_code}] POST /workspace/files/reject {{path={path}}}")
    try:
        print(_p(r.json()))
    except Exception:
        print(r.text[:500])


def _git_status(client, app_id, sid):
    r = client._post(
        f"/api/apps/{app_id}/sessions/{sid}/workspace/git-status"
    )
    print(f"\n[HTTP {r.status_code}] POST /workspace/git-status")
    try:
        print(_p(r.json()))
    except Exception:
        print(r.text[:500])


def _drain(stream, timeout=40):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if any(e.get("type") == "message_done" for e in stream.events()):
            break
        time.sleep(0.25)


def _emit_preview_events(envs, title):
    print(f"\n--- {title} ---")
    seen = 0
    for env in envs:
        t = env.get("type", "?")
        if not t.startswith("preview:"):
            continue
        pl = env.get("payload") or {}
        # Trim content
        if isinstance(pl, dict):
            for k in ("content",):
                if k in pl.get("payload", {}) and isinstance(pl["payload"][k], str):
                    c = pl["payload"][k]
                    if len(c) > 120:
                        pl["payload"][k] = c[:120] + "..."
        print(f"\n[seq={env.get('seq')}] {t}")
        print(_p(pl))
        seen += 1
        if seen >= 8:
            print("... (more events truncated)")
            break


def main():
    client = DevClient.with_user(
        email="admin", password="admin1234admin",
        daemon_url="http://127.0.0.1:8000",
    )
    app_id = "digitorn-builder"  # has workspace + preview
    sandbox = r"C:\Users\ASUS\Documents\digitorn_client\scout\_sandbox_diff"
    os.makedirs(sandbox, exist_ok=True)
    sid = f"scout-diff-{uuid.uuid4().hex[:8]}"
    session = SessionHandle(
        session_id=sid, app_id=app_id,
        daemon_url=client.daemon_url, workspace=sandbox,
    )
    print(f"\n╔═══ DIFF FLOW SCOUT  app={app_id} session={sid} ═══╗\n")

    # Phase 1 — write a file via the agent.
    print("\n▶ PHASE 1: initial write")
    stream = client.send_live(
        session,
        "Use the WsWrite tool to create notes.txt with the content:\n"
        "line one\nline two\nline three\n"
        "Reply 'ok' in one word.",
        total_timeout=60,
    )
    try:
        _drain(stream, 60)
        _emit_preview_events(stream.events(), "phase-1 preview events")
    finally:
        stream.stop(timeout=1.0)

    # Phase 1 — fetch the file. baseline should be empty (never approved).
    print("\n▶ PHASE 1 — GET file (no baseline yet)")
    _fetch_file(client, app_id, sid, "notes.txt")

    # Phase 1 — snapshot.
    _snapshot(client, app_id, sid)

    # Phase 2 — approve. Baseline := content, diff clears.
    print("\n▶ PHASE 2 — approve")
    _approve(client, app_id, sid, "notes.txt")
    _fetch_file(client, app_id, sid, "notes.txt")

    # Phase 3 — agent edits. diff should re-populate.
    print("\n▶ PHASE 3 — edit")
    stream = client.send_live(
        session,
        "Use the WsEdit tool on notes.txt to replace 'line two' "
        "with 'LINE TWO'. Reply 'ok' in one word.",
        total_timeout=60,
    )
    try:
        _drain(stream, 60)
        _emit_preview_events(stream.events(), "phase-3 preview events")
    finally:
        stream.stop(timeout=1.0)

    _fetch_file(client, app_id, sid, "notes.txt")
    _snapshot(client, app_id, sid)

    # Phase 4 — reject. Restores baseline.
    print("\n▶ PHASE 4 — reject")
    _reject(client, app_id, sid, "notes.txt")
    _fetch_file(client, app_id, sid, "notes.txt")
    _snapshot(client, app_id, sid)

    # Phase 5 — git status.
    print("\n▶ PHASE 5 — git-status")
    _git_status(client, app_id, sid)


if __name__ == "__main__":
    main()
