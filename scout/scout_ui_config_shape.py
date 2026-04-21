"""Scout: dump the full shape of `GET /api/apps/{id}/ui-config`.

The brief says the response has THREE top-level blocks:
  * workspace_config  (auto_approve, sync_to_disk, lint, …)
  * preview_config    (enabled, port)
  * workspace         (render_mode, entry_file, title)

My earlier scout run saw only the first two. Re-verify against the
live daemon so the Flutter `AppUiConfig.fromJson` knows exactly what
to parse.
"""
import json
import os
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

sys.path.insert(0, r"C:\Users\ASUS\Documents\digitorn-bridge\packages")
from digitorn.testing import DevClient  # noqa: E402


def main():
    client = DevClient.with_user(
        email="admin", password="admin1234admin",
        daemon_url="http://127.0.0.1:8000",
    )

    # Two apps we already deployed in the validation scout; probe both.
    # Falls back to `digitorn-builder` when the fixtures aren't there.
    for app_id in [
        "ws-validate-manual",
        "ws-validate-auto",
        "digitorn-builder",
    ]:
        print(f"\n== GET /api/apps/{app_id}/ui-config ==")
        r = client._get(f"/api/apps/{app_id}/ui-config")
        print(f"  HTTP {r.status_code}")
        if r.status_code != 200:
            continue
        body = r.json()
        data = body.get("data") or body
        print("  top-level keys:", sorted(data.keys()))
        for k in ("workspace_config", "preview_config", "workspace"):
            v = data.get(k)
            if v is None:
                print(f"    {k}: <missing>")
            elif isinstance(v, dict):
                print(f"    {k}: keys={sorted(v.keys())}")
            else:
                print(f"    {k}: {type(v).__name__} {v!r}")
        print("  full payload:")
        print(json.dumps(data, indent=2, ensure_ascii=False, default=str))


if __name__ == "__main__":
    main()
