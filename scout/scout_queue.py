"""Scout: queue behavior when multiple messages are sent rapidly.

Flow:
  1. Create a session.
  2. Send 3 messages back-to-back (before the first completes).
  3. Record every envelope until all 3 turns complete.
  4. Dump the lifecycle for each correlation_id so we can see:
     - queue:snapshot entries (position, status)
     - message_queued / message_started / message_done ordering
     - whether `pending: true` is flagged on user_message for queued
"""
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


def _summary(env: dict) -> str:
    t = env.get("type", "?")
    seq = env.get("seq")
    payload = env.get("payload", {}) or env.get("data", {}) or {}
    cid = payload.get("correlation_id")
    bits = [f"seq={seq}", f"type={t}"]
    if cid:
        bits.append(f"cid={cid[-6:]}")
    if t == "queue:snapshot":
        bits.append(f"depth={payload.get('depth')}")
        bits.append(f"active={payload.get('is_active')}")
        entries = payload.get("entries", []) or []
        if entries:
            bits.append(f"entries={[e.get('status') for e in entries]}")
    if t == "user_message":
        bits.append(f"pending={payload.get('pending')}")
    if t == "message_started":
        bits.append(f"pos={payload.get('position')}")
        bits.append(f"fast={payload.get('fast_path')}")
    if t == "message_done":
        bits.append(f"fast={payload.get('fast_path')}")
    if t == "token":
        bits.append(f"delta={(payload.get('delta') or '')[:20]!r}")
    return " · ".join(bits)


def main() -> None:
    client = DevClient.with_user(
        email="admin",
        password="admin1234admin",
        daemon_url="http://127.0.0.1:8000",
    )
    app_id = "digitorn-chat"
    sid = f"scout-queue-{uuid.uuid4().hex[:8]}"
    session = SessionHandle(
        session_id=sid,
        app_id=app_id,
        daemon_url=client.daemon_url,
        workspace="",
    )
    print(f"\n=== Queue scout — session={sid} ===\n")

    prompts = [
        "A- count from 1 to 3 slowly",
        "B- what colour is the sky",
        "C- say goodbye in one word",
    ]

    # `send_live` creates the session daemon-side and opens a stream
    # attached to it. We then POST the other 2 messages via the raw
    # endpoint while the stream keeps capturing everything.
    stream = client.send_live(session, prompts[0], total_timeout=120)
    try:
        time.sleep(0.05)
        for p in prompts[1:]:
            client.post_message_raw(session, p)
            time.sleep(0.05)

        # Wait until 3 message_done events have landed.
        deadline = time.time() + 120
        while time.time() < deadline:
            dones = [
                e for e in stream.events()
                if e.get("type") == "message_done"
            ]
            if len(dones) >= len(prompts):
                break
            time.sleep(0.3)

        # Replay everything in wire order.
        envelopes = stream.events()
        print(f"--- {len(envelopes)} envelopes total ---\n")
        for i, env in enumerate(envelopes):
            print(f"[{i:03d}] {_summary(env)}")

        # Per-cid lifecycle.
        print("\n--- Per-correlation_id lifecycle ---")
        cids: list[str] = []
        for env in envelopes:
            if env.get("type") == "user_message":
                pl = env.get("payload") or env.get("data") or {}
                cid = pl.get("correlation_id")
                if cid and cid not in cids:
                    cids.append(cid)
        for cid in cids:
            lc = [
                env for env in envelopes
                if ((env.get("payload") or env.get("data") or {})
                    .get("correlation_id") == cid)
            ]
            types = [e.get("type") for e in lc]
            print(f"\n{cid[-6:]}:")
            for t in types:
                print(f"  - {t}")
    finally:
        stream.stop(timeout=2.0)


if __name__ == "__main__":
    main()
