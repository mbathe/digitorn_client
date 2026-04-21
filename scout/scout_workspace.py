"""Scout: workspace + preview + file-change events.

Pins down the wire contract for:
  * `tool_call` Write / Edit / Bash → do they carry workspace side-
    effects (new file path, diff, exit code)?
  * `workspace_status` — payload shape, when it fires (inline per
    tool, end-of-turn, both?)
  * `file_event` / `file_changed` / `manifest_update` — does the
    daemon push them at all?
  * `preview:resource_set`, `preview:url`, `preview:ready` — shape?
  * Any terminal/shell-specific envelopes we're missing.

Strategy: run ONE simple, fast tool call (Write a 3-line text file)
so we don't hit the model's balance cap.
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


def _pretty(v: object) -> str:
    return json.dumps(v, indent=2, default=str, ensure_ascii=False)


def main() -> None:
    client = DevClient.with_user(
        email="admin",
        password="admin1234admin",
        daemon_url="http://127.0.0.1:8000",
    )
    app_id = sys.argv[1] if len(sys.argv) > 1 else "digitorn-code"
    sandbox = r"C:\Users\ASUS\Documents\digitorn_client\scout\_sandbox"
    os.makedirs(sandbox, exist_ok=True)

    sid = f"scout-ws-{uuid.uuid4().hex[:8]}"
    session = SessionHandle(
        session_id=sid,
        app_id=app_id,
        daemon_url=client.daemon_url,
        workspace=sandbox,
    )
    print(f"\n=== Workspace scout app={app_id} session={sid} ===\n")
    print(f"sandbox = {sandbox}\n")

    prompt = (
        "Use the Write tool to create a file hello.txt with the "
        "single line 'hi'. Reply in one word when done."
    )

    stream = client.send_live(session, prompt, total_timeout=60)
    try:
        deadline = time.time() + 60
        while time.time() < deadline:
            if any(e.get("type") == "message_done"
                   for e in stream.events()):
                break
            time.sleep(0.25)

        envelopes = stream.events()

        # Emit ALL unique event types so we don't miss anything novel.
        type_counts: dict[str, int] = {}
        for env in envelopes:
            t = env.get("type", "?")
            type_counts[t] = type_counts.get(t, 0) + 1
        print(f"--- {len(envelopes)} envelopes, type histogram ---")
        for t, n in sorted(type_counts.items(), key=lambda x: -x[1]):
            print(f"  {n:4d}  {t}")

        # Full dump of each non-token, non-hook envelope — those
        # carry the interesting wire data.
        hide = {
            "token", "out_token", "in_token", "thinking_delta",
            "assistant_stream_snapshot",
        }
        print("\n--- interesting envelopes ---")
        for env in envelopes:
            t = env.get("type", "?")
            if t in hide:
                continue
            pl = env.get("payload") or env.get("data") or {}
            if isinstance(pl, dict):
                display = pl.get("display") or {}
                if isinstance(display, dict) and display.get("hidden"):
                    # skip plumbing tools — we already know their shape
                    continue
            print(f"\n[seq={env.get('seq')}] {t}")
            print(_pretty(pl))

        # Extra: grep for ANY key that whispers "workspace" / "preview"
        # / "file" / "git" in any envelope.
        print("\n--- keys hinting at workspace state ---")
        seen: set[str] = set()
        for env in envelopes:
            pl = env.get("payload") or env.get("data") or {}
            if not isinstance(pl, dict):
                continue
            for k in pl.keys():
                lk = k.lower()
                if any(w in lk for w in (
                        "workspace", "preview", "file",
                        "git", "terminal", "shell", "manifest")):
                    seen.add(f"{env.get('type')}/{k}")
        for s in sorted(seen):
            print(f"  {s}")

        # And: raw sandbox inspection — did the Write actually
        # land on disk?
        print("\n--- sandbox contents after turn ---")
        try:
            for root, _, files in os.walk(sandbox):
                rel = os.path.relpath(root, sandbox)
                for f in files:
                    print(f"  {rel}/{f}")
        except Exception as ex:
            print(f"  scan failed: {ex!r}")
    finally:
        stream.stop(timeout=2.0)


if __name__ == "__main__":
    main()
