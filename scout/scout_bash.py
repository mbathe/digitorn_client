"""Scout: Bash / shell tool — what does the daemon emit?

Does it push `terminal_output` envelopes with stdout/stderr, or is
everything stuffed into `tool_call.result`? Is there a live stream
of bash output?
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
    app_id = sys.argv[1] if len(sys.argv) > 1 else "prod-coding-assistant"
    sandbox = r"C:\Users\ASUS\Documents\digitorn_client\scout\_sandbox"
    os.makedirs(sandbox, exist_ok=True)
    sid = f"scout-bash-{uuid.uuid4().hex[:8]}"
    session = SessionHandle(
        session_id=sid,
        app_id=app_id,
        daemon_url=client.daemon_url,
        workspace=sandbox,
    )
    print(f"\n=== Bash scout app={app_id} session={sid} ===\n")

    stream = client.send_live(
        session,
        "Use the Bash tool to run `echo hello world` and tell me the output.",
        total_timeout=60,
    )
    try:
        deadline = time.time() + 60
        while time.time() < deadline:
            if any(e.get("type") == "message_done"
                   for e in stream.events()):
                break
            time.sleep(0.25)

        envelopes = stream.events()

        types: dict[str, int] = {}
        for e in envelopes:
            t = e.get("type", "?")
            types[t] = types.get(t, 0) + 1
        print(f"--- {len(envelopes)} envelopes ---")
        for t, n in sorted(types.items(), key=lambda x: -x[1]):
            print(f"  {n:4d}  {t}")

        hide = {"token", "out_token", "in_token", "thinking_delta"}
        print("\n--- interesting envelopes ---")
        for env in envelopes:
            t = env.get("type", "?")
            if t in hide:
                continue
            pl = env.get("payload") or env.get("data") or {}
            if isinstance(pl, dict):
                display = pl.get("display") or {}
                if isinstance(display, dict) and display.get("hidden"):
                    continue
            print(f"\n[seq={env.get('seq')}] {t}")
            print(_pretty(pl))
    finally:
        stream.stop(timeout=2.0)


if __name__ == "__main__":
    main()
