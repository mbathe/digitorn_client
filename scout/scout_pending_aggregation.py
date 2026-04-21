"""Scout: verify insertions_pending / deletions_pending aggregate
across multiple writes since the last approve.

User report: "the +N -M counters next to files in Monaco only show
the LAST edit, not the sum since approve." Expected behavior per
brief §2: those fields ARE delta-vs-baseline and aggregate every
write since approve() bumped the baseline.

Steps:
  1. PUT initial 4-line file, approve → baseline set.
  2. Three consecutive writes, each changing a DIFFERENT single line.
  3. After each write, GET ?include_baseline=true and print
     (insertions_pending, deletions_pending, diff preview).
  4. Expected after 3rd write:
       ins == 3, del == 3 (NOT 1/1 which would be per-op only).
"""
import os
import sys
import tempfile
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

sys.path.insert(0, r"C:\Users\ASUS\Documents\digitorn-bridge\packages")
from digitorn.testing import DevClient  # noqa: E402

BASE = "http://127.0.0.1:8000"
APP_ID = "ws-validate-manual"

passed = 0
failed = 0


def _ok(label, cond, extra=""):
    global passed, failed
    mark = "PASS" if cond else "FAIL"
    print(f"  [{mark}] {label}  {extra}")
    if cond:
        passed += 1
    else:
        failed += 1


def _put(client, sid, path, content):
    return client._put(
        f"/api/apps/{APP_ID}/sessions/{sid}/workspace/files/{path}",
        json={"content": content, "auto_approve": False, "source": "user"},
    )


def _get(client, sid, path):
    return client._get(
        f"/api/apps/{APP_ID}/sessions/{sid}/workspace/files/{path}"
        "?include_baseline=true"
    )


def main():
    client = DevClient.with_user(
        email="admin", password="admin1234admin", daemon_url=BASE,
    )
    r = client._get(f"/api/apps/{APP_ID}")
    if r.status_code != 200:
        print("  ws-validate-manual not deployed — run scout_workspace_validation.py first")
        return 2

    ws = Path(tempfile.gettempdir()) / f"pending-agg-{os.urandom(4).hex()}"
    ws.mkdir(parents=True, exist_ok=True)
    r = client._post(
        f"/api/apps/{APP_ID}/sessions",
        json={"workspace_path": str(ws)},
    )
    sid = (r.json().get("data") or {}).get("session_id")
    print(f"\n== Pending aggregation  session={sid} ==")

    # 1. baseline of 4 lines
    _put(client, sid, "agg.txt", "one\ntwo\nthree\nfour\n")
    client._post(
        f"/api/apps/{APP_ID}/sessions/{sid}/workspace/files/approve",
        json={"path": "agg.txt"},
    )

    cur = "one\ntwo\nthree\nfour\n"
    expected_ins, expected_del = 0, 0

    # 2-4. three consecutive edits, each touching a different line
    edits = [
        ("one\nONE\nthree\nfour\n", 1, 1, "replace line 2"),
        ("one\nONE\nTHREE\nfour\n", 2, 2, "replace line 2+3"),
        ("one\nONE\nTHREE\nFOUR\n", 3, 3, "replace line 2+3+4"),
    ]
    for i, (new_content, exp_ins, exp_del, label) in enumerate(edits, 1):
        _put(client, sid, "agg.txt", new_content)
        r = _get(client, sid, "agg.txt")
        d = r.json().get("data") or {}
        p = d.get("payload") or {}
        diff = d.get("unified_diff_pending") or ""
        ins = p.get("insertions_pending")
        dele = p.get("deletions_pending")
        print(f"\n-- write #{i}: {label} --")
        print(f"  insertions_pending={ins}  deletions_pending={dele}")
        print(f"  diff preview ({len(diff)}B):")
        for line in diff.splitlines()[:8]:
            print(f"    {line}")
        _ok(
            f"write #{i}: insertions_pending=={exp_ins} (aggregate vs baseline)",
            ins == exp_ins,
            f"(got {ins})",
        )
        _ok(
            f"write #{i}: deletions_pending=={exp_del} (aggregate vs baseline)",
            dele == exp_del,
            f"(got {dele})",
        )

    print(f"\n== RESULT ==  {passed} PASS  {failed} FAIL")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
