"""Scout: verify insertions_pending / deletions_pending semantics.

Sequence:
  1. Write file (3 lines)       → pending?=3
  2. Approve                    → pending=0
  3. Edit 1 line                → pending=? (should be 1i/1d, not 4i/1d)
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


def _get(client, app_id, sid, path):
    r = client._get(
        f"/api/apps/{app_id}/sessions/{sid}/workspace/files/{path}"
        "?include_baseline=true"
    )
    data = r.json().get("data") or {}
    pl = data.get("payload") or {}
    return {
        "insertions": pl.get("insertions"),
        "deletions": pl.get("deletions"),
        "total_insertions": pl.get("total_insertions"),
        "total_deletions": pl.get("total_deletions"),
        "insertions_pending": pl.get("insertions_pending"),
        "deletions_pending": pl.get("deletions_pending"),
        "unified_diff_pending": (
            (data.get("unified_diff_pending") or "")[:200]
        ),
    }


def _approve(client, app_id, sid, path):
    client._post(
        f"/api/apps/{app_id}/sessions/{sid}/workspace/files/approve",
        json={"path": path},
    )


def _drain(stream, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if any(e.get("type") == "message_done" for e in stream.events()):
            break
        time.sleep(0.25)
    stream.stop(timeout=1.0)


def main():
    client = DevClient.with_user(
        email="admin", password="admin1234admin",
        daemon_url="http://127.0.0.1:8000",
    )
    app_id = "digitorn-builder"
    sandbox = r"C:\Users\ASUS\Documents\digitorn_client\scout\_sandbox_pending"
    os.makedirs(sandbox, exist_ok=True)
    sid = f"scout-pc-{uuid.uuid4().hex[:6]}"
    session = SessionHandle(
        session_id=sid, app_id=app_id,
        daemon_url=client.daemon_url, workspace=sandbox,
    )

    print(f"\n╔═══ Pending counts scout session={sid} ═══╗\n")

    # 1. Write — 3 lines
    print("▶ STEP 1: write notes.txt with 3 lines")
    stream = client.send_live(
        session,
        "Use the WsWrite tool to create notes.txt with these 3 lines "
        "then reply 'ok':\nline one\nline two\nline three",
        total_timeout=60,
    )
    _drain(stream)
    print(json.dumps(_get(client, app_id, sid, "notes.txt"), indent=2))

    # 2. Approve
    print("\n▶ STEP 2: approve notes.txt")
    _approve(client, app_id, sid, "notes.txt")
    print(json.dumps(_get(client, app_id, sid, "notes.txt"), indent=2))

    # 3. Edit ONE line
    print("\n▶ STEP 3: edit 1 line (replace 'line two' → 'LINE TWO')")
    stream = client.send_live(
        session,
        "Use the WsEdit tool on notes.txt to replace 'line two' with "
        "'LINE TWO'. Reply 'ok' in one word.",
        total_timeout=60,
    )
    _drain(stream)
    print(json.dumps(_get(client, app_id, sid, "notes.txt"), indent=2))

    # 4. Second edit — add a new line at end
    print("\n▶ STEP 4: append a 4th line via WsEdit")
    stream = client.send_live(
        session,
        "Use the WsEdit tool on notes.txt to add the line "
        "'line four' at the end of the file. Reply 'ok'.",
        total_timeout=60,
    )
    _drain(stream)
    print(json.dumps(_get(client, app_id, sid, "notes.txt"), indent=2))


if __name__ == "__main__":
    main()
