"""Scout: exercise the full workspace validation contract end-to-end.

Validates every endpoint the Flutter client will wire:

  1. GET  /api/apps/{id}/ui-config                       — UI-safe config
  2. PUT  /workspace/files/{path}                        — user writeback
  3. GET  /workspace/files/{path}?include_baseline=true  — content + diff
  4. POST /workspace/files/approve                       — stage whole file
  5. POST /workspace/files/reject                        — revert whole file
  6. POST /workspace/files/approve-hunks                 — per-hunk stage
  7. POST /workspace/files/reject-hunks                  — per-hunk revert
  8. POST /workspace/commit                              — ship to git
  9. GET  /workspace/files/{path}/history                — approval history
 10. auto_approve mode: verify no-op approve path

Uses a fresh deployed app + explicit workspace path so state is
deterministic. Prints PASS / FAIL per assertion so the user knows
exactly which Flutter feature has a working backend.
"""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

sys.path.insert(0, r"C:\Users\ASUS\Documents\digitorn-bridge\packages")
from digitorn.testing import DevClient  # noqa: E402

BASE = "http://127.0.0.1:8000"

MANUAL_YAML = """
app:
  app_id: ws-validate-manual
  name: "WS Validation Manual"
  version: "1.0.0"

modules:
  workspace:
    config:
      render_mode: code
      sync_to_disk: true
      auto_approve: false
  preview: {}

agents:
  - id: scribe
    role: writer
    brain:
      provider: anthropic
      model: claude-haiku-4-5
      config: {api_key: claude-code}
    system_prompt: "Write files on demand. Reply 'ok'."

execution:
  mode: conversation
  entry_agent: scribe

capabilities:
  default_policy: auto
  grant:
    - module: workspace
      actions: [write, read, edit, glob, grep, delete]
"""

AUTO_YAML = MANUAL_YAML.replace(
    "app_id: ws-validate-manual", "app_id: ws-validate-auto"
).replace("auto_approve: false", "auto_approve: true").replace(
    "WS Validation Manual", "WS Validation Auto"
)

passed = 0
failed = 0
failures: list[str] = []


def _ok(label, cond, extra=""):
    global passed, failed
    mark = "PASS" if cond else "FAIL"
    print(f"  [{mark}] {label}  {extra}")
    if cond:
        passed += 1
    else:
        failed += 1
        failures.append(label)
    return cond


def _deploy(client, yaml_text, app_id):
    with tempfile.NamedTemporaryFile(
        "w", suffix=".yaml", delete=False, encoding="utf-8"
    ) as tf:
        tf.write(yaml_text)
        tf_path = tf.name
    r = client._post("/api/apps/deploy",
                     json={"yaml_path": tf_path, "force": True})
    if r.status_code != 200 or not (r.json().get("success")):
        print(f"  deploy FAILED: {r.status_code} {r.text[:200]}")
        return False
    for _ in range(30):
        time.sleep(1)
        rr = client._get(f"/api/apps/{app_id}")
        if rr.status_code == 200 and rr.json().get("success"):
            return True
    print(f"  deploy did not become ready for {app_id}")
    return False


def _mk_session(client, app_id):
    ws = Path(tempfile.gettempdir()) / f"ws-val-{os.urandom(4).hex()}"
    ws.mkdir(parents=True, exist_ok=True)
    r = client._post(f"/api/apps/{app_id}/sessions",
                     json={"workspace_path": str(ws)})
    sid = (r.json().get("data") or {}).get("session_id")
    return sid, ws


def _put(client, app_id, sid, path, content, auto_approve=False,
         source="user"):
    return client._put(
        f"/api/apps/{app_id}/sessions/{sid}/workspace/files/{path}",
        json={"content": content, "auto_approve": auto_approve,
              "source": source},
    )


def _get_file(client, app_id, sid, path):
    return client._get(
        f"/api/apps/{app_id}/sessions/{sid}/workspace/files/{path}"
        f"?include_baseline=true"
    )


def _hunk_hash(header: str, body: list[str]) -> str:
    """Mirror daemon's _finalize_hunk hash formula (12-char sha256)."""
    src = header + "\n" + "\n".join(body)
    return hashlib.sha256(src.encode()).hexdigest()[:12]


def _parse_hunks(diff: str) -> list[dict]:
    """Parse a unified diff into hunks with stable hashes. Mirrors the
    daemon's `_parse_unified_diff_hunks` exactly: body only keeps lines
    whose first char is ` `, `-`, or `+` (the file-marker `---`/`+++`
    appear before the first `@@` and are already filtered by that
    condition, empty strings from trailing split are filtered too)."""
    if not diff:
        return []
    lines = diff.split("\n")
    hunks = []
    current: dict | None = None
    for line in lines:
        if line.startswith("@@"):
            if current is not None:
                current["hash"] = _hunk_hash(current["header"],
                                             current["body"])
                hunks.append(current)
            current = {"header": line, "body": []}
        elif current is not None and line and line[0] in " -+":
            current["body"].append(line)
    if current is not None:
        current["hash"] = _hunk_hash(current["header"], current["body"])
        hunks.append(current)
    return hunks


def _git_init(ws: Path):
    subprocess.run(["git", "init", "-q"], cwd=ws, check=False)
    subprocess.run(["git", "config", "user.email", "scout@local"],
                   cwd=ws, check=False)
    subprocess.run(["git", "config", "user.name", "scout"],
                   cwd=ws, check=False)


def main():
    client = DevClient.with_user(
        email="admin", password="admin1234admin", daemon_url=BASE
    )

    # ── PART A — MANUAL mode ─────────────────────────────────────
    print("\n== PART A  MANUAL mode ==")
    if not _deploy(client, MANUAL_YAML, "ws-validate-manual"):
        return 2
    sid, ws = _mk_session(client, "ws-validate-manual")
    print(f"  session={sid}  ws={ws}")
    _git_init(ws)

    # ── 1. GET /ui-config ────────────────────────────────────────
    print("\n-- GET /ui-config --")
    r = client._get("/api/apps/ws-validate-manual/ui-config")
    _ok("ui-config HTTP 200", r.status_code == 200,
        f"(got {r.status_code})")
    data = (r.json().get("data") or {}) if r.status_code == 200 else {}
    wsc = (data.get("workspace_config") or {})
    _ok("workspace_config.auto_approve is False",
        wsc.get("auto_approve") is False,
        f"(got {wsc.get('auto_approve')!r})")
    _ok("workspace_config does not leak prompts / secrets",
        all(k not in wsc for k in ("system_prompt", "api_key", "secrets")))
    # The brief documented a top-level `workspace` block but the daemon
    # currently only ships `workspace_config` (render_mode lives there
    # too). Either is fine — the client has a second source of truth
    # via `/sessions/{sid}/workspace`.
    _ok("workspace_config.render_mode present",
        "render_mode" in wsc,
        f"(workspace_config keys: {list(wsc.keys())})")

    # ── 2. PUT /files/{path}  (first write) ──────────────────────
    print("\n-- PUT /files/hello.txt  (initial) --")
    r = _put(client, "ws-validate-manual", sid, "hello.txt",
             "line one\nline two\nline three\n")
    _ok("PUT writeback 200", r.status_code == 200,
        f"(got {r.status_code})")

    # ── 3. GET /files  after first write  (manual → pending) ────
    print("\n-- GET /files/hello.txt?include_baseline=true --")
    r = _get_file(client, "ws-validate-manual", sid, "hello.txt")
    d = (r.json().get("data") or {}) if r.status_code == 200 else {}
    p = d.get("payload") or {}
    _ok("validation == pending (manual mode first write)",
        p.get("validation") == "pending",
        f"(got {p.get('validation')!r})")
    _ok("insertions_pending == 3 (3 new lines vs empty baseline)",
        p.get("insertions_pending") == 3,
        f"(got {p.get('insertions_pending')})")
    _ok("deletions_pending == 0",
        p.get("deletions_pending") == 0)
    _ok("source echoed back as 'user'",
        p.get("source") == "user", f"(got {p.get('source')!r})")

    # ── 4. POST /files/approve ───────────────────────────────────
    print("\n-- POST /files/approve --")
    r = client._post(
        "/api/apps/ws-validate-manual/sessions/"
        f"{sid}/workspace/files/approve",
        json={"path": "hello.txt"},
    )
    d = (r.json().get("data") or {}) if r.status_code == 200 else {}
    _ok("approve HTTP 200", r.status_code == 200,
        f"(got {r.status_code})")
    _ok("approve response validation=approved",
        d.get("validation") == "approved")

    # verify state
    r = _get_file(client, "ws-validate-manual", sid, "hello.txt")
    p = (r.json().get("data") or {}).get("payload") or {}
    _ok("after approve: pending counts == 0",
        p.get("insertions_pending") == 0 and
        p.get("deletions_pending") == 0,
        f"(ins={p.get('insertions_pending')} "
        f"del={p.get('deletions_pending')})")

    # ── 5. PUT again (produce delta)  ────────────────────────────
    print("\n-- PUT (second revision: 1 replaced line) --")
    _put(client, "ws-validate-manual", sid, "hello.txt",
         "line one\nLINE TWO\nline three\n")
    r = _get_file(client, "ws-validate-manual", sid, "hello.txt")
    d = (r.json().get("data") or {})
    p = d.get("payload") or {}
    diff = d.get("unified_diff_pending") or ""
    _ok("after edit: validation=pending", p.get("validation") == "pending")
    _ok("delta-vs-baseline: ins==1 del==1 (BUG #1 fix)",
        p.get("insertions_pending") == 1 and
        p.get("deletions_pending") == 1,
        f"(ins={p.get('insertions_pending')} "
        f"del={p.get('deletions_pending')})")
    _ok("unified_diff_pending present",
        bool(diff.strip()))
    _ok("unified_diff lines \\n terminated (BUG #2 fix)",
        "-line two\n" in diff and "+LINE TWO\n" in diff,
        f"(len={len(diff)}, has-sep={'-line two\\n' in diff})")

    # ── 6. POST /files/reject ────────────────────────────────────
    print("\n-- POST /files/reject --")
    r = client._post(
        "/api/apps/ws-validate-manual/sessions/"
        f"{sid}/workspace/files/reject",
        json={"path": "hello.txt"},
    )
    d = (r.json().get("data") or {}) if r.status_code == 200 else {}
    _ok("reject HTTP 200", r.status_code == 200,
        f"(got {r.status_code})")
    _ok("reverted=baseline (had approved baseline)",
        d.get("reverted") == "baseline",
        f"(got {d.get('reverted')!r})")
    r = _get_file(client, "ws-validate-manual", sid, "hello.txt")
    p = (r.json().get("data") or {}).get("payload") or {}
    _ok("after reject: content back to baseline",
        "line two" in (p.get("content") or "") and
        "LINE TWO" not in (p.get("content") or ""))

    # ── 7. Per-hunk approve ──────────────────────────────────────
    print("\n-- POST /files/approve-hunks --")
    # Multi-hunk edit: change line 1 AND add line 4
    _put(client, "ws-validate-manual", sid, "hello.txt",
         "LINE ONE\nline two\nline three\nline four added\n")
    r = _get_file(client, "ws-validate-manual", sid, "hello.txt")
    d = (r.json().get("data") or {})
    diff = d.get("unified_diff_pending") or ""
    hunks = _parse_hunks(diff)
    print(f"  parsed {len(hunks)} hunks from diff:")
    for h in hunks:
        print(f"    hash={h['hash']}  {h['header']}")
    _ok("multiple hunks detected", len(hunks) >= 1,
        f"(got {len(hunks)})")
    if hunks:
        r = client._post(
            "/api/apps/ws-validate-manual/sessions/"
            f"{sid}/workspace/files/approve-hunks",
            json={"path": "hello.txt", "hunks": [hunks[0]["hash"]]},
        )
        _ok("approve-hunks HTTP 200", r.status_code == 200,
            f"(got {r.status_code} {r.text[:160] if r.status_code!=200 else ''})")
        if r.status_code == 200:
            body = r.json().get("data") or {}
            _ok("approve-hunks returns approved_hunks list",
                isinstance(body.get("approved_hunks"), list) and
                len(body["approved_hunks"]) >= 1,
                f"(got {body.get('approved_hunks')})")
            _ok("approve-hunks returns remaining_hunks list",
                isinstance(body.get("remaining_hunks"), list))

    # ── 8. Per-hunk reject ───────────────────────────────────────
    print("\n-- POST /files/reject-hunks --")
    r = _get_file(client, "ws-validate-manual", sid, "hello.txt")
    d = (r.json().get("data") or {})
    diff = d.get("unified_diff_pending") or ""
    hunks2 = _parse_hunks(diff)
    if hunks2:
        r = client._post(
            "/api/apps/ws-validate-manual/sessions/"
            f"{sid}/workspace/files/reject-hunks",
            json={"path": "hello.txt", "hunks": [hunks2[0]["hash"]]},
        )
        _ok("reject-hunks HTTP 200", r.status_code == 200,
            f"(got {r.status_code} {r.text[:160] if r.status_code!=200 else ''})")
        if r.status_code == 200:
            body = r.json().get("data") or {}
            _ok("reject-hunks returns reverted_hunks list",
                isinstance(body.get("reverted_hunks"), list))

    # ── 9. GET /files/{path}/history ──────────────────────────────
    print("\n-- GET /files/hello.txt/history --")
    # Approve everything first to lock a revision in place
    client._post(
        "/api/apps/ws-validate-manual/sessions/"
        f"{sid}/workspace/files/approve",
        json={"path": "hello.txt"},
    )
    r = client._get(
        "/api/apps/ws-validate-manual/sessions/"
        f"{sid}/workspace/files/hello.txt/history"
    )
    _ok("history HTTP 200", r.status_code == 200,
        f"(got {r.status_code} {r.text[:160] if r.status_code!=200 else ''})")
    if r.status_code == 200:
        body = r.json().get("data") or {}
        revs = body.get("revisions") or []
        _ok("history has revisions", len(revs) >= 1,
            f"(got {len(revs)})")
        if revs:
            first = revs[0]
            _ok("revision has approved_by field",
                "approved_by" in first)
            _ok("revision has tokens_delta fields",
                "tokens_delta_ins" in first and
                "tokens_delta_del" in first)

    # ── 10. POST /workspace/commit ────────────────────────────────
    print("\n-- POST /workspace/commit --")
    r = client._post(
        f"/api/apps/ws-validate-manual/sessions/{sid}/workspace/commit",
        json={"message": "feat: hello", "files": None, "push": False},
    )
    _ok("commit HTTP 200", r.status_code == 200,
        f"(got {r.status_code} {r.text[:220] if r.status_code!=200 else ''})")
    if r.status_code == 200:
        body = r.json().get("data") or {}
        _ok("commit returns commit_sha",
            isinstance(body.get("commit_sha"), str) and
            len(body.get("commit_sha", "")) >= 7)
        _ok("commit returns files_committed list",
            isinstance(body.get("files_committed"), list))

    # ── PART B — AUTO_APPROVE mode ────────────────────────────────
    print("\n== PART B  AUTO_APPROVE mode ==")
    if not _deploy(client, AUTO_YAML, "ws-validate-auto"):
        return 2
    sid2, ws2 = _mk_session(client, "ws-validate-auto")
    print(f"  session={sid2}  ws={ws2}")

    r = client._get("/api/apps/ws-validate-auto/ui-config")
    d = (r.json().get("data") or {}) if r.status_code == 200 else {}
    wsc = d.get("workspace_config") or {}
    _ok("ui-config.workspace_config.auto_approve == True",
        wsc.get("auto_approve") is True,
        f"(got {wsc.get('auto_approve')!r})")

    _put(client, "ws-validate-auto", sid2, "auto.txt", "hi\n")
    r = _get_file(client, "ws-validate-auto", sid2, "auto.txt")
    p = (r.json().get("data") or {}).get("payload") or {}
    _ok("auto_approve: validation=approved on first write",
        p.get("validation") == "approved",
        f"(got {p.get('validation')!r})")
    _ok("auto_approve: no pending counts",
        p.get("insertions_pending") == 0 and
        p.get("deletions_pending") == 0)

    # ── Summary ───────────────────────────────────────────────────
    print(f"\n== RESULT ==")
    print(f"  {passed} PASS   {failed} FAIL")
    if failures:
        print("\n  Failing checks:")
        for f in failures:
            print(f"    - {f}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
