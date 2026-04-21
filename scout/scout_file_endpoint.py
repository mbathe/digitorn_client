"""Scout: verify GET /workspace/files/{path} availability per app.

For apps without `preview` or `workspace` modules the route is
unregistered and 404s. The client's FileContentService must fall
back to the in-memory WorkspaceModule copy in that case.
"""
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
import uuid


def main() -> None:
    client = DevClient.with_user(
        email="admin",
        password="admin1234admin",
        daemon_url="http://127.0.0.1:8000",
    )
    sandbox = r"C:\Users\ASUS\Documents\digitorn_client\scout\_sandbox"
    os.makedirs(sandbox, exist_ok=True)
    print(f"\n=== /workspace/files/{{path}} probe ===\n")
    for app_id in (
        "fs-tester",
        "prod-coding-assistant",
        "ws-preview-test",
        "digitorn-builder",
    ):
        sid = f"scout-fep-{uuid.uuid4().hex[:6]}"
        session = SessionHandle(
            session_id=sid, app_id=app_id,
            daemon_url=client.daemon_url, workspace=sandbox,
        )
        # Prime a session + write a file so there's something to fetch.
        try:
            stream = client.send_live(
                session,
                "Use the Write tool to create hello.txt with the "
                "single line 'hi'. Reply 'done' in one word.",
                total_timeout=40,
            )
        except Exception as ex:
            print(f"  {app_id:<25}  skipped (send failed: {ex!r})")
            continue
        import time
        deadline = time.time() + 40
        while time.time() < deadline:
            if any(e.get("type") == "message_done"
                   for e in stream.events()):
                break
            time.sleep(0.25)
        stream.stop(timeout=1.0)

        # Probe the file endpoint.
        try:
            r = client._get(
                f"/api/apps/{app_id}/sessions/{sid}/workspace/files/hello.txt"
            )
            first = r.text[:140].replace("\n", " ")
            print(f"  {app_id:<25}  {r.status_code}  {first}")
        except Exception as ex:
            print(f"  {app_id:<25}  ERR  {ex!r}")


if __name__ == "__main__":
    main()
