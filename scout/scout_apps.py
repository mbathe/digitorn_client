"""Scout: list apps registered on the daemon + their modules.

digitorn-code stalls on every scout I try — probably needs a
specific setup. Let me discover what apps exist, what modules /
tools they expose, and pick one that actually writes files.
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


def main() -> None:
    client = DevClient.with_user(
        email="admin",
        password="admin1234admin",
        daemon_url="http://127.0.0.1:8000",
    )

    apps = client.list_apps()
    print(f"{len(apps)} apps total\n")
    for app in apps:
        aid = app.get("id") or app.get("app_id") or "?"
        ws = app.get("workspace") or {}
        ws_mode = ws.get("mode") or app.get("workspace_mode") or "?"
        modules = app.get("modules") or []
        print(
            f"  {aid:<30}  ws={ws_mode:<10}  modules="
            f"{modules if isinstance(modules, list) and modules else '[]'}"
        )

    # Full dump of the first 3 apps so we see the raw shape.
    print("\n--- raw shape of first 2 apps ---")
    for app in apps[:2]:
        print(json.dumps(app, indent=2, default=str)[:1500])
        print()


if __name__ == "__main__":
    main()
