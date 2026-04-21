"""Scout: dump the `seq` of every event around a compaction fire to
understand where the compaction bubble SHOULD be anchored.

Bug hypothesis: the client's `_anchorForNewLocalBubble()` picks the
highest seq seen so far — so if the compaction event arrives while
other higher-seq events (tool_call, thinking_delta, out_token) are
already in the stream, the compaction bubble gets anchored ABOVE all
of them and renders at the tail of the chat, regardless of when it
actually happened in the turn.

The fix should anchor the compaction bubble to the `hook` event's
own envelope seq (or the seq at the moment the compaction was
emitted on the daemon side).

Steps:
  1. Deploy an app with a tight context budget so compaction fires
     early.
  2. Send a LONG prompt that forces the daemon to compact mid-turn.
  3. Print every envelope's (seq, type, action_type, phase) so we
     can verify:
       a. The `hook/compact_context` envelope has a seq.
       b. That seq is SMALLER than some subsequent event seqs.
     Both true → the bubble must anchor to THIS seq, not to the
     current max.
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
    # Use the builder which has a real LLM + history enabled.
    app_id = "digitorn-builder"

    ws = Path(tempfile.gettempdir()) / f"compact-scout-{os.urandom(4).hex()}"
    ws.mkdir(parents=True, exist_ok=True)

    # Fresh session so seqs start at 0.
    sid = f"compact-{os.urandom(4).hex()}"
    session = SessionHandle(
        session_id=sid, app_id=app_id,
        daemon_url=client.daemon_url, workspace=str(ws),
    )

    # A prompt that produces a long thought + tool chain. We don't
    # need a real emergency compaction for the anchor-test: a regular
    # context_status hook already carries the seq pattern we need.
    prompt = ("Read packages/digitorn/core/__init__.py AND "
              "packages/digitorn/__init__.py AND list three files "
              "in packages/digitorn/modules. Think step-by-step, "
              "explain your reasoning, then do it.")

    print(f"\n== compaction seq scout  session={sid} ==")
    stream = client.send_live(session, prompt, total_timeout=90)
    deadline = time.time() + 90
    while time.time() < deadline:
        if any(e.get("type") == "message_done" for e in stream.events()):
            break
        time.sleep(0.3)
    envs = stream.events()
    stream.stop(timeout=1.0)

    # Print every envelope with seq + type + (action_type, phase)
    # when it's a hook.
    print(f"\n-- {len(envs)} envelopes --")
    hook_events = []
    for env in envs:
        t = env.get("type", "?")
        seq = env.get("seq")
        extra = ""
        if t == "hook":
            payload = env.get("payload") or env.get("data") or {}
            at = payload.get("action_type") or payload.get("action") or ""
            ph = payload.get("phase") or ""
            extra = f"  action_type={at}  phase={ph}"
            hook_events.append((seq, at, ph))
        print(f"  seq={seq!r:<8}  {t:<20}{extra}")

    # Focused view: seqs of hook events vs their neighbors.
    if hook_events:
        print(f"\n-- {len(hook_events)} hook event(s) --")
        for seq, at, ph in hook_events:
            if at in ("context_status", "compact_context",
                      "emergency_compaction"):
                # find neighbors
                higher = [e for e in envs if (e.get("seq") or 0) > (seq or 0)]
                print(f"  hook seq={seq}  {at}/{ph}")
                print(f"    {len(higher)} envelope(s) have higher seqs — "
                      f"client MUST anchor the compaction bubble to seq={seq}, "
                      f"not to the current max.")


if __name__ == "__main__":
    main()
