"""Scout: does /workspace/files/{path} accept paths with slashes?"""
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

sys.path.insert(0, r"C:\Users\ASUS\Documents\digitorn-bridge\packages")

from digitorn.testing import DevClient  # noqa: E402
from digitorn.testing.models import SessionHandle  # noqa: E402
import os
import time
import uuid


def main():
    client = DevClient.with_user(
        email="admin", password="admin1234admin",
        daemon_url="http://127.0.0.1:8000",
    )
    app_id = "digitorn-builder"
    sandbox = r"C:\Users\ASUS\Documents\digitorn_client\scout\_sandbox_nested"
    os.makedirs(sandbox, exist_ok=True)
    sid = f"scout-nest-{uuid.uuid4().hex[:6]}"
    session = SessionHandle(
        session_id=sid, app_id=app_id,
        daemon_url=client.daemon_url, workspace=sandbox,
    )
    # Prime — write a nested file via the agent.
    stream = client.send_live(
        session,
        "Use the WsWrite tool to create src/App.tsx with the single line "
        "'export default function App(){}'. Reply 'ok' in one word.",
        total_timeout=60,
    )
    deadline = time.time() + 60
    while time.time() < deadline:
        if any(e.get("type") == "message_done" for e in stream.events()):
            break
        time.sleep(0.2)
    stream.stop(timeout=1.0)

    # Try several URI variants.
    for variant in (
        f"/api/apps/{app_id}/sessions/{sid}/workspace/files/src/App.tsx",
        f"/api/apps/{app_id}/sessions/{sid}/workspace/files/src%2FApp.tsx",
        f"/api/apps/{app_id}/sessions/{sid}/workspace/files/src%2fApp.tsx",
    ):
        try:
            r = client._get(variant)
            text = r.text[:160].replace("\n", " ")
            print(f"{variant}\n  → {r.status_code}  {text}\n")
        except Exception as ex:
            print(f"{variant}\n  → ERR  {ex!r}\n")


if __name__ == "__main__":
    main()
