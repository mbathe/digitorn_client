"""Where does the workspace meta (render_mode / entry_file / title)
actually come from on `digitorn-builder`?

The canvas router needs this signal to fire. Let's find the source.
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


def _pretty(v):
    return json.dumps(v, indent=2, default=str, ensure_ascii=False)


def main():
    client = DevClient.with_user(
        email="admin", password="admin1234admin",
        daemon_url="http://127.0.0.1:8000",
    )
    app_id = "digitorn-builder"
    sandbox = r"C:\Users\ASUS\Documents\digitorn_client\scout\_sandbox_meta"
    os.makedirs(sandbox, exist_ok=True)
    sid = f"scout-mt-{uuid.uuid4().hex[:6]}"
    session = SessionHandle(
        session_id=sid, app_id=app_id,
        daemon_url=client.daemon_url, workspace=sandbox,
    )
    print(f"\n=== Meta source scout  session={sid} ===\n")

    # Open a live stream first so we capture the session-bootstrap
    # preview events.
    stream = client.send_live(
        session,
        "Hello — just init the session, don't write anything. Reply 'hi'.",
        total_timeout=40,
    )
    deadline = time.time() + 40
    while time.time() < deadline:
        if any(e.get("type") == "message_done" for e in stream.events()):
            break
        time.sleep(0.3)
    envs = stream.events()
    stream.stop(timeout=1.0)

    # ─ HTTP endpoint variants ─────────────────────────────────────
    print("▶ HTTP endpoint variants")
    for path in [
        f"/api/apps/{app_id}/sessions/{sid}/workspace",
        f"/api/apps/{app_id}/sessions/{sid}/workspace/",
        f"/api/apps/{app_id}/workspace",
        f"/api/apps/{app_id}/sessions/{sid}",
        f"/api/apps/{app_id}",
        f"/api/apps/{app_id}/manifest",
    ]:
        try:
            r = client._get(path)
            text = r.text[:140].replace("\n", " ")
            print(f"  {r.status_code}  {path}")
            if r.status_code == 200:
                try:
                    body = r.json()
                    data = body.get("data") or body
                    # Look for workspace / render_mode / entry_file
                    for k in ("render_mode", "entry_file", "title",
                              "workspace"):
                        if isinstance(data, dict) and k in data:
                            print(f"       {k}: {data[k]}")
                except Exception:
                    pass
        except Exception as ex:
            print(f"  ERR   {path}   {ex!r}")

    # ─ Event histogram ────────────────────────────────────────────
    print(f"\n▶ Event histogram ({len(envs)} envelopes)")
    types = {}
    for env in envs:
        t = env.get("type", "?")
        types[t] = types.get(t, 0) + 1
    for t, n in sorted(types.items(), key=lambda x: -x[1]):
        print(f"    {n:3d}  {t}")

    # ─ Full preview:snapshot payload ──────────────────────────────
    print("\n▶ preview:snapshot payload (raw)")
    for env in envs:
        if env.get("type") == "preview:snapshot":
            pl = env.get("payload") or {}
            # Print top-level keys + state subtree
            print("  keys:", list(pl.keys()))
            state = pl.get("state") or {}
            print("  state keys:", list(state.keys()))
            if state:
                print("  state full:")
                print(_pretty(state))
            else:
                print("  (state is empty)")
            resources = pl.get("resources") or {}
            print(f"  resources channels: {list(resources.keys())}")
            for ch, items in resources.items():
                if isinstance(items, dict):
                    print(f"    {ch}: {len(items)} items")
            break
    else:
        print("  no preview:snapshot event received")

    # ─ preview:state_changed detail ───────────────────────────────
    print("\n▶ preview:state_changed events (all)")
    count = 0
    for env in envs:
        if env.get("type") == "preview:state_changed":
            pl = env.get("payload") or {}
            print(f"  seq={env.get('seq')}  key={pl.get('key')!r}")
            print(_pretty(pl))
            count += 1
    if count == 0:
        print("  (none)")


if __name__ == "__main__":
    main()
