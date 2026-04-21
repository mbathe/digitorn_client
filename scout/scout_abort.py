"""Scout: abort flow — what the daemon emits on soft stop.

Goal — characterise the envelopes a client sees when a turn is
aborted mid-stream:

  * Does the daemon send `message_done` with a special status?
  * Any `abort_ack` / `cancelled` markers?
  * Are `token` deltas cut off cleanly or is there a tail?
  * Does `context` still land post-abort (for bookkeeping)?
  * What's the Socket.IO event name for abort? (`abort_message`,
    `stop_session`, something else?)

Strategy:
  1. Send a long-winded prompt.
  2. Sleep ~2s, then call the daemon's abort endpoint.
  3. Capture everything and flag unusual types.
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
    sid = f"scout-abort-{uuid.uuid4().hex[:8]}"
    session = SessionHandle(
        session_id=sid,
        app_id=app_id,
        daemon_url=client.daemon_url,
        workspace="",
    )
    print(f"\n=== Abort scout — session={sid} ===\n")

    prompt = (
        "Write a very long essay (at least 2000 words) about the "
        "history of typography, covering every major movement from "
        "Gutenberg to modern digital type. Include lots of names and "
        "dates. Take your time, be exhaustive."
    )

    stream = client.send_live(session, prompt, total_timeout=60)
    try:
        # Let the model stream for a couple seconds, then abort.
        time.sleep(2.5)
        print(">>> sending abort")
        aborted = False
        for method_name in ("abort", "stop", "cancel", "abort_message"):
            fn = getattr(client, method_name, None)
            if callable(fn):
                try:
                    fn(session)
                    aborted = True
                    print(f"    via client.{method_name}()")
                    break
                except Exception as ex:
                    print(f"    client.{method_name} raised {ex!r}")
        if not aborted:
            # Last resort — raw POST.
            for path in (
                f"/api/apps/{app_id}/sessions/{sid}/abort",
                f"/api/sessions/{sid}/abort",
                f"/api/apps/{app_id}/sessions/{sid}/stop",
            ):
                url = client.daemon_url.rstrip("/") + path
                try:
                    r = client.http.post(url)
                    print(f"    POST {path} -> {r.status_code}")
                    if r.status_code < 400:
                        aborted = True
                        break
                except Exception as ex:
                    print(f"    POST {path} raised {ex!r}")
        print(f"    aborted={aborted}")

        # Wait a few more seconds for final envelopes.
        deadline = time.time() + 20
        last_count = -1
        while time.time() < deadline:
            envs = stream.events()
            if len(envs) == last_count:
                time.sleep(0.4)
                continue
            last_count = len(envs)
            time.sleep(0.3)

        envelopes = stream.events()
        types = sorted({e.get("type") for e in envelopes})
        print(f"\n--- {len(envelopes)} envelopes, types: {types} ---\n")

        # Print non-token events fully.
        for env in envelopes:
            t = env.get("type", "?")
            seq = env.get("seq")
            pl = env.get("payload") or env.get("data") or {}
            if t in {"token", "out_token", "thinking_delta"}:
                continue
            print(f"[seq={seq}] {t}")
            if pl:
                print(_pretty(pl))
            print()

        # Explicitly look for abort / stop / cancel markers anywhere.
        print("\n--- abort markers found ---")
        for env in envelopes:
            blob = json.dumps(env, default=str).lower()
            if any(k in blob for k in (
                    "abort", "cancel", "stop", "interrupt", "halt")):
                print(f"seq={env.get('seq')} type={env.get('type')}")
    finally:
        stream.stop(timeout=2.0)


if __name__ == "__main__":
    main()
