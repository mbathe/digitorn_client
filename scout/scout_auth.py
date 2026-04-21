"""Smoke test — can we log in as admin and list apps?"""
import sys

sys.path.insert(0, r"C:\Users\ASUS\Documents\digitorn-bridge\packages")

from digitorn.testing import DevClient  # noqa: E402


def main() -> None:
    client = DevClient.with_user(
        email="admin",
        password="admin1234admin",
        daemon_url="http://127.0.0.1:8000",
    )
    print(f"Token acquired — length={len(client._token or '')}")

    apps = client.list_apps()
    print(f"{len(apps)} apps on the daemon:")
    for a in apps[:20]:
        ws = getattr(a, "workspace_mode", "?") if hasattr(a, "workspace_mode") else a.get("workspace_mode", "?")
        name = getattr(a, "name", None) if hasattr(a, "name") else a.get("name")
        app_id = getattr(a, "app_id", None) if hasattr(a, "app_id") else a.get("app_id")
        print(f"  · {app_id}  — {name}  [ws={ws}]")


if __name__ == "__main__":
    main()
