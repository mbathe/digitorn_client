"""Scout: tool_call v2 event contract — display block, params,
visible_params, detail_param — all under live conditions.

Requires an app that exposes tools. `digitorn-code` (ws=required)
is ideal; fallback to `my-assistant` if bound.
"""
import json
import sys
import time
import uuid

# UTF-8 on Windows console (tool results often contain non-cp1252 chars).
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


def main() -> None:
    client = DevClient.with_user(
        email="admin",
        password="admin1234admin",
        daemon_url="http://127.0.0.1:8000",
    )
    app_id = sys.argv[1] if len(sys.argv) > 1 else "digitorn-code"
    prompt = sys.argv[2] if len(sys.argv) > 2 else (
        "List the files in the current workspace directory using the "
        "workspace_list tool, then read the first file you find. "
        "Keep your reply under 50 words."
    )
    sid = f"scout-tools-{uuid.uuid4().hex[:8]}"
    session = SessionHandle(
        session_id=sid,
        app_id=app_id,
        daemon_url=client.daemon_url,
        workspace=r"C:\Users\ASUS\Documents\digitorn_client",
    )
    print(f"\n=== Tools scout — app={app_id} session={sid} ===\n")
    print(f"> Prompt: {prompt!r}\n")

    stream = client.send_live(session, prompt, total_timeout=180)
    try:
        envelopes = stream.events()
        # Filter out the noise.
        interesting = [
            e for e in envelopes
            if e.get("type") in {
                "tool_start", "tool_call", "tool_args",
                "tool_use", "tool_result",
                "status", "hook", "result", "message_done",
                "workspace_status", "preview:resource_set",
            }
        ]
        print(f"--- {len(envelopes)} total, {len(interesting)} interesting ---\n")
        for i, env in enumerate(interesting):
            t = env.get("type", "?")
            seq = env.get("seq")
            payload = env.get("payload") or env.get("data") or {}
            print(f"[{i:03d}] seq={seq} type={t}")
            print(_pretty(payload))
            print()
    finally:
        stream.stop(timeout=2.0)


if __name__ == "__main__":
    main()
