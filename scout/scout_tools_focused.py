"""Scout: focus on visible, non-hidden tool_call events only."""
import json
import sys
import uuid

# Force UTF-8 on Windows console so file contents with emoji / accents
# don't blow the scout up with UnicodeEncodeError (cp1252 fallback).
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

sys.path.insert(0, r"C:\Users\ASUS\Documents\digitorn-bridge\packages")

from digitorn.testing import DevClient  # noqa: E402
from digitorn.testing.models import SessionHandle  # noqa: E402


def _pretty(value: object) -> str:
    return json.dumps(value, indent=2, default=str, ensure_ascii=False)


def main() -> None:
    client = DevClient.with_user(
        email="admin",
        password="admin1234admin",
        daemon_url="http://127.0.0.1:8000",
    )
    app_id = "digitorn-code"
    sid = f"scout-focused-{uuid.uuid4().hex[:8]}"
    session = SessionHandle(
        session_id=sid,
        app_id=app_id,
        daemon_url=client.daemon_url,
        workspace=r"C:\Users\ASUS\Documents\digitorn_client",
    )
    print(f"\n=== Focused tools scout — {sid} ===\n")

    stream = client.send_live(
        session,
        "Read pubspec.yaml from the workspace and tell me the version number "
        "in one short sentence.",
        total_timeout=180,
    )
    try:
        envelopes = stream.events()
        for env in envelopes:
            t = env.get("type", "?")
            pl = env.get("payload") or env.get("data") or {}
            if t not in {"tool_start", "tool_call"}:
                continue
            display = pl.get("display") or {}
            if display.get("hidden"):
                continue
            seq = env.get("seq")
            print(f"\n[seq={seq}] {t}")
            print(_pretty(pl))
    finally:
        stream.stop(timeout=2.0)


if __name__ == "__main__":
    main()
