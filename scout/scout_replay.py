"""Scout: replay / join_session — resuming after a disconnect.

Goal — characterise what the daemon sends when a client rejoins an
active session (mid-turn or post-turn) with `since=0`. Specifically:

  * Does the log arrive as one monolithic envelope or many small
    ones?
  * Are `tool_call`, `tool_start`, `token` all replayed with their
    original seq numbers?
  * Does `assistant_stream_snapshot` land after the replay to convey
    "latest known content" for an in-flight turn?
  * Is there a `replay_start` / `replay_done` marker?

Strategy:
  1. Send a first message, let it complete.
  2. Disconnect the stream.
  3. Re-attach with since=0 and dump everything.
  4. Also test re-attaching mid-turn to capture mid-flight state.
"""
import json
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


def _pretty(v: object) -> str:
    return json.dumps(v, indent=2, default=str, ensure_ascii=False)


def main() -> None:
    client = DevClient.with_user(
        email="admin",
        password="admin1234admin",
        daemon_url="http://127.0.0.1:8000",
    )
    app_id = "digitorn-chat"
    sid = f"scout-replay-{uuid.uuid4().hex[:8]}"
    session = SessionHandle(
        session_id=sid,
        app_id=app_id,
        daemon_url=client.daemon_url,
        workspace="",
    )
    print(f"\n=== Replay scout — session={sid} ===\n")

    # Phase 1 — fire a message and wait for completion.
    stream = client.send_live(
        session,
        "Tell me a fun fact about octopuses in two sentences.",
        total_timeout=60,
    )
    try:
        deadline = time.time() + 60
        while time.time() < deadline:
            done = any(
                e.get("type") == "message_done"
                for e in stream.events()
            )
            if done:
                break
            time.sleep(0.2)
        live_envs = list(stream.events())
        print(f"> live turn: {len(live_envs)} envelopes")
    finally:
        stream.stop(timeout=2.0)

    # Phase 2 — rejoin and replay from seq=0.
    print("\n--- rejoining with since=0 ---")
    replay_envs: list[dict] = []
    try:
        rej = client.open_event_stream(session)
        # Trigger the replay now that the fresh stream is attached.
        replayed_count = rej.request_replay(since=0, timeout=10.0)
        print(f"daemon reported replayed={replayed_count}")
        deadline = time.time() + 20
        last_count = -1
        while time.time() < deadline:
            time.sleep(0.4)
            envs = list(rej.events())
            if len(envs) == last_count and len(envs) > 0:
                break
            last_count = len(envs)
        replay_envs = list(rej.events())
        rej.stop(timeout=2.0)
    except Exception as ex:
        print(f"replay failed: {ex!r}")

    print(f"> replay: {len(replay_envs)} envelopes")
    types_live = sorted({e.get("type") for e in live_envs})
    types_replay = sorted({e.get("type") for e in replay_envs})
    print(f"\nlive  types: {types_live}")
    print(f"reply types: {types_replay}")
    only_replay = set(types_replay) - set(types_live)
    only_live = set(types_live) - set(types_replay)
    print(f"types only in replay : {sorted(only_replay)}")
    print(f"types only in live   : {sorted(only_live)}")

    # Show the first ~20 non-token envelopes of the replay
    print("\n--- replay head (non-token) ---")
    shown = 0
    for env in replay_envs:
        t = env.get("type", "?")
        if t in {"token", "out_token", "in_token", "thinking_delta"}:
            continue
        pl = env.get("payload") or env.get("data") or {}
        print(f"\n[seq={env.get('seq')}] {t}")
        if pl:
            print(_pretty(pl))
        shown += 1
        if shown >= 20:
            break


if __name__ == "__main__":
    main()
