"""Scout: file deletion tool — what does the result look like?"""
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


def _pretty(v):
    return json.dumps(v, indent=2, default=str, ensure_ascii=False)


def main():
    client = DevClient.with_user(
        email="admin",
        password="admin1234admin",
        daemon_url="http://127.0.0.1:8000",
    )
    app_id = "fs-tester"
    sandbox = r"C:\Users\ASUS\Documents\digitorn_client\scout\_sandbox"
    os.makedirs(sandbox, exist_ok=True)
    # Seed a file so there's something to delete.
    open(os.path.join(sandbox, "to_delete.txt"), "w").write("x")
    sid = f"scout-del-{uuid.uuid4().hex[:8]}"
    session = SessionHandle(
        session_id=sid,
        app_id=app_id,
        daemon_url=client.daemon_url,
        workspace=sandbox,
    )
    print(f"\n=== Delete scout app={app_id} session={sid} ===\n")
    stream = client.send_live(
        session,
        "Delete the file to_delete.txt. Reply 'done' in one word.",
        total_timeout=60,
    )
    try:
        deadline = time.time() + 60
        while time.time() < deadline:
            if any(e.get("type") == "message_done"
                   for e in stream.events()):
                break
            time.sleep(0.25)
        envs = stream.events()
        hide = {"token", "out_token", "in_token", "thinking_delta",
                "assistant_stream_snapshot", "hook"}
        for env in envs:
            t = env.get("type", "?")
            if t in hide:
                continue
            pl = env.get("payload") or env.get("data") or {}
            if isinstance(pl, dict):
                display = pl.get("display") or {}
                if display.get("hidden"):
                    continue
            print(f"\n[seq={env.get('seq')}] {t}")
            print(_pretty(pl))
    finally:
        stream.stop(timeout=2.0)


if __name__ == "__main__":
    main()
