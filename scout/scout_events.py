"""Dump every Socket.IO envelope for a one-turn chat on a simple app.

Goal: characterise the exact shape of `user_message`, `message_started`,
`token`, `result` / `turn_complete`, and especially `context` / `usage`
blocks — so the Flutter client's defensive guards stop being paranoid
and start being informed.
"""
import json
import sys
import uuid

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

sys.path.insert(0, r"C:\Users\ASUS\Documents\digitorn-bridge\packages")

from digitorn.testing import DevClient  # noqa: E402
from digitorn.testing.models import SessionHandle  # noqa: E402


def _pretty(value: object) -> str:
    try:
        return json.dumps(value, indent=2, default=str, ensure_ascii=False)
    except Exception:
        return repr(value)


def scout(app_id: str, prompt: str) -> None:
    client = DevClient.with_user(
        email="admin",
        password="admin1234admin",
        daemon_url="http://127.0.0.1:8000",
    )
    sid = f"scout-{uuid.uuid4().hex[:8]}"
    session = SessionHandle(
        session_id=sid,
        app_id=app_id,
        daemon_url=client.daemon_url,
        workspace="",
    )
    print(f"\n=== Scouting `{app_id}` — session={sid} ===\n")
    print(f"> Prompt: {prompt!r}\n")

    stream = client.send_live(session, prompt, total_timeout=120)
    try:
        envelopes = stream.events()
        print(f"--- {len(envelopes)} envelopes captured ---\n")
        for i, env in enumerate(envelopes):
            t = env.get("type", "?")
            seq = env.get("seq")
            kind = env.get("kind")
            payload = env.get("payload", {}) or env.get("data", {}) or {}
            ts = env.get("ts")
            head = f"[{i:03d}] seq={seq} kind={kind} type={t} ts={ts}"
            # Trim token events so the log stays readable.
            if t in ("token", "out_token", "thinking_delta"):
                delta = payload.get("delta", "")
                delta_str = (delta[:40] + "…") if len(delta) > 40 else delta
                print(f"{head}  delta={delta_str!r}")
                continue
            print(head)
            if payload:
                print(_pretty(payload))
            print()
    finally:
        stream.stop(timeout=2.0)


if __name__ == "__main__":
    # Pass `app_id` + optional prompt on the CLI to tweak runs.
    app = sys.argv[1] if len(sys.argv) > 1 else "digitorn-chat"
    prompt = sys.argv[2] if len(sys.argv) > 2 else "Hello! Reply in one short sentence."
    scout(app, prompt)
