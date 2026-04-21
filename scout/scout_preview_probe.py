"""Scout: verify the `/api/apps/{id}/preview/` probe on several apps.

Confirms the user-reported 404 for apps without a static preview and
shows what 200 looks like for apps that do.
"""
import json
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

sys.path.insert(0, r"C:\Users\ASUS\Documents\digitorn-bridge\packages")

from digitorn.testing import DevClient  # noqa: E402


def probe(client: DevClient, app_id: str) -> None:
    try:
        r = client._get(f"/api/apps/{app_id}/preview/")
        ct = r.headers.get("content-type", "")
        first = r.text[:160].replace("\n", " ")
        print(f"  {app_id:<30}  {r.status_code}  {ct:<30}  {first}")
    except Exception as ex:
        print(f"  {app_id:<30}  ERR  {ex!r}")


def main() -> None:
    client = DevClient.with_user(
        email="admin",
        password="admin1234admin",
        daemon_url="http://127.0.0.1:8000",
    )
    print(f"\n=== /preview/ probe ===\n")
    for app_id in [
        "digitorn-chat",          # ws=none
        "fs-tester",              # filesystem only
        "prod-coding-assistant",  # filesystem + shell
        "ws-preview-test",        # workspace + preview
        "digitorn-builder",       # preview + shell + workspace
        "task-manager",           # workspace + preview
        "echo-chatbot",           # ws=none
    ]:
        probe(client, app_id)


if __name__ == "__main__":
    main()
