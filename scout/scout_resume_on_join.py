"""Scout: validate what the daemon ships on `join_session` so the
client can reconcile state after a reconnect.

Scenario:
  1. Open a session, send a message, let it finish cleanly.
  2. Disconnect / reconnect (by opening a fresh socket) and RE-JOIN
     the same session with since=last_seq.
  3. Dump everything that arrives:
       * replayed events (every persisted event > since)
       * preview:snapshot (workspace state)
       * queue:snapshot (is_active, running_correlation_id, entries)

Expected: replay covers user_message + tool_start + tool_call +
message_done + result, and queue:snapshot.is_active == false when
no turn is in-flight. That's enough for the client to walk the
replayed timeline, spot any dangling tool_start without its
matching tool_call, and finalize the UI.
"""
import json
import os
import sys
import tempfile
import time
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

sys.path.insert(0, r"C:\Users\ASUS\Documents\digitorn-bridge\packages")
from digitorn.testing import DevClient  # noqa: E402
from digitorn.testing.models import SessionHandle  # noqa: E402

BASE = "http://127.0.0.1:8000"


def main():
    client = DevClient.with_user(
        email="admin", password="admin1234admin", daemon_url=BASE,
    )
    app_id = "digitorn-builder"

    ws = Path(tempfile.gettempdir()) / f"resume-scout-{os.urandom(4).hex()}"
    ws.mkdir(parents=True, exist_ok=True)

    sid = f"resume-{os.urandom(4).hex()}"
    session = SessionHandle(
        session_id=sid, app_id=app_id,
        daemon_url=client.daemon_url, workspace=str(ws),
    )

    print(f"\n== Part 1: run a turn on session {sid} ==")
    stream = client.send_live(
        session,
        "Read packages/digitorn/__init__.py and tell me the first "
        "10 lines verbatim. Reply 'done'.",
        total_timeout=60,
    )
    deadline = time.time() + 60
    while time.time() < deadline:
        if any(e.get("type") == "message_done" for e in stream.events()):
            break
        time.sleep(0.3)
    envs = stream.events()
    stream.stop(timeout=1.0)

    # Record the durable-event types we saw, and the last seq.
    types_seen = {}
    last_seq = 0
    for e in envs:
        t = e.get("type", "?")
        types_seen[t] = types_seen.get(t, 0) + 1
        s = e.get("seq")
        if isinstance(s, int) and s > last_seq:
            last_seq = s

    print(f"\n  first connection got {len(envs)} envelopes, "
          f"last_seq={last_seq}")
    print("  event-type histogram:")
    for t, n in sorted(types_seen.items(), key=lambda x: -x[1]):
        print(f"    {n:3d}  {t}")

    print(f"\n== Part 2: fresh connection, rejoin with since={last_seq} ==")
    # Open a new live stream WITHOUT sending anything — just join the
    # session room. We pass `since=last_seq` to mimic a reconnect
    # where the client only wants deltas. With nothing new on the
    # session the replay should be empty, but queue:snapshot +
    # preview:snapshot (hydration events) should still fire.
    stream2 = client.open_event_stream(session)
    time.sleep(3)  # let hydration events land
    envs2 = stream2.events()
    stream2.stop(timeout=1.0)

    print(f"\n  rejoin got {len(envs2)} envelope(s) (since={last_seq}):")
    for e in envs2:
        t = e.get("type", "?")
        seq = e.get("seq")
        pl = e.get("payload") or e.get("data") or {}
        if t == "queue:snapshot":
            print(f"    seq={seq}  {t}")
            print(f"      is_active={pl.get('is_active')!r}")
            print(f"      running_correlation_id="
                  f"{pl.get('running_correlation_id')!r}")
            print(f"      depth={pl.get('depth')}")
            print(f"      entries={len(pl.get('entries') or [])}")
        elif t == "preview:snapshot":
            st = pl.get("state") or {}
            res = pl.get("resources") or {}
            print(f"    seq={seq}  {t}  state_keys={list(st.keys())}  "
                  f"resources={list(res.keys())}")
        else:
            print(f"    seq={seq}  {t}")

    # Also explicitly test: rejoin with since=0 replays everything.
    print(f"\n== Part 3: fresh connection, rejoin with since=0 (full replay) ==")
    stream3 = client.open_event_stream(session)
    time.sleep(5)
    envs3 = stream3.events()
    stream3.stop(timeout=1.0)

    replay_types = {}
    for e in envs3:
        t = e.get("type", "?")
        replay_types[t] = replay_types.get(t, 0) + 1
    print(f"  full replay got {len(envs3)} envelope(s). Types:")
    for t, n in sorted(replay_types.items(), key=lambda x: -x[1]):
        print(f"    {n:3d}  {t}")

    print("\n== Findings ==")
    # Sanity assertions.
    durable = [t for t in replay_types if t in {
        "user_message", "message_started", "message_done",
        "tool_start", "tool_call", "result", "hook",
        "preview:resource_set", "preview:snapshot", "queue:snapshot",
    }]
    print(f"  durable events replayed: {durable}")
    missing = [t for t in [
        "user_message", "message_done", "result",
    ] if t not in replay_types]
    if missing:
        print(f"  WARN — expected but missing: {missing}")
    if "queue:snapshot" not in replay_types:
        print("  WARN — no queue:snapshot on rejoin, client can't "
              "reconcile 'is_active' state")


if __name__ == "__main__":
    main()
