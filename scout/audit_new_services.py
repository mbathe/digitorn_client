"""Live scout — hits every endpoint the 6 new services expose
against the real daemon. Defensive: each call is wrapped in
try/except with a short timeout, so one hang doesn't kill the
run.

Usage: `python scout/audit_new_services.py`
"""
from __future__ import annotations

import os
import sys
import uuid
import time

import httpx

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

BASE = os.environ.get("DIGITORN_BASE", "http://127.0.0.1:8000")
RESULTS: list[tuple[bool, str, str]] = []


def rec(label: str, status: int | None, accept: list[int] | None = None,
        extra: str = "") -> None:
    accept = accept or [200]
    ok = status in accept
    mark = "PASS" if ok else ("ERR " if status is None else "FAIL")
    stat = f"({status})" if status else "(conn err)"
    print(f"  [{mark}] {label}  {stat}  {extra}")
    RESULTS.append((ok, label, f"{stat} {extra}"))


def sget(c: httpx.Client, url: str, tok: str, **kw) -> int | None:
    try:
        r = c.get(url, headers={"Authorization": f"Bearer {tok}"},
                  timeout=8.0, **kw)
        return r.status_code
    except Exception as e:
        print(f"      [err] {type(e).__name__}: {str(e)[:60]}")
        return None


def spost(c: httpx.Client, url: str, tok: str, body: dict | None = None,
          **kw) -> int | None:
    try:
        r = c.post(url, headers={"Authorization": f"Bearer {tok}"},
                   json=body or {}, timeout=8.0, **kw)
        return r.status_code
    except Exception as e:
        print(f"      [err] {type(e).__name__}: {str(e)[:60]}")
        return None


def register(c: httpx.Client) -> str:
    u = f"audit{uuid.uuid4().hex[:8]}"
    r = c.post(f"{BASE}/auth/register", json={
        "username": u, "email": f"{u}@t.local", "password": "AuditProd12!"},
        timeout=15.0)
    if r.status_code != 200:
        r = c.post(f"{BASE}/auth/login", json={
            "email": f"{u}@t.local", "password": "AuditProd12!"}, timeout=15.0)
    return r.json()["access_token"]


def seed_session(c: httpx.Client, tok: str, app_id: str) -> str:
    sid = f"audit-{uuid.uuid4().hex[:8]}"
    c.post(f"{BASE}/api/apps/{app_id}/sessions/{sid}/messages",
           headers={"Authorization": f"Bearer {tok}"},
           json={"message": "hi"}, timeout=30.0)
    # Let the turn finish.
    deadline = time.monotonic() + 60
    seen = 0
    while time.monotonic() < deadline:
        try:
            r = c.get(
                f"{BASE}/api/apps/{app_id}/sessions/{sid}/events",
                headers={"Authorization": f"Bearer {tok}"},
                params={"since_seq": seen, "limit": 200}, timeout=8.0)
            if r.status_code == 200:
                for ev in (r.json().get("data") or {}).get("events", []):
                    if ev["seq"] > seen:
                        seen = ev["seq"]
                    if ev.get("type") == "message_done":
                        return sid
        except Exception:
            pass
        time.sleep(0.5)
    return sid


def main() -> int:
    try:
        h = httpx.get(f"{BASE}/health", timeout=5.0)
        if h.status_code != 200:
            print(f"daemon unhealthy ({h.status_code})")
            return 1
    except Exception as e:
        print(f"daemon unreachable: {e}")
        return 1
    print(f"daemon OK at {BASE}\n")

    with httpx.Client() as c:
        tok = register(c)
        app_id = "digitorn-chat"
        sid = seed_session(c, tok, app_id)
        print(f"session: {sid}\n")

        APP = f"{BASE}/api/apps/{app_id}"
        SID = f"{APP}/sessions/{sid}"

        # ── SessionActionsService ───────────────────────────
        print("── SessionActionsService ──")
        rec("POST /sessions/{sid}/compact",
            spost(c, f"{SID}/compact", tok), [200])
        rec("GET  /sessions/{sid}/memory",
            sget(c, f"{SID}/memory", tok), [200])
        rec("GET  /sessions/{sid}/preview",
            sget(c, f"{SID}/preview", tok), [200, 404],
            "(404 OK no preview module)")
        rec("GET  /sessions/{sid}/tasks",
            sget(c, f"{SID}/tasks", tok), [200])
        rec("GET  /sessions/{sid}/export",
            sget(c, f"{SID}/export", tok), [200])
        rec("GET  /sessions/search",
            sget(c, f"{APP}/sessions/search", tok,
                 params={"q": "hi", "limit": 5}),
            [200, 404], "(404 OK not deployed)")
        rec("POST /sessions/{sid}/abort",
            spost(c, f"{SID}/abort", tok), [200])

        # ── AppLifecycleService ────────────────────────────
        print("\n── AppLifecycleService ──")
        rec("POST /apps/validate",
            spost(c, f"{BASE}/api/apps/validate", tok,
                  {"yaml_content": "app:\n  app_id: test\n"}),
            [200, 400, 422], "(4xx OK = invalid yaml)")
        rec("GET  /apps/{id}/deploy-status",
            sget(c, f"{APP}/deploy-status", tok), [200])
        rec("GET  /apps/{id}/payload-schema",
            sget(c, f"{APP}/payload-schema", tok), [200, 404])
        rec("GET  /apps/{id}/index",
            sget(c, f"{APP}/index", tok), [200])
        rec("GET  /apps/{id}/errors",
            sget(c, f"{APP}/errors", tok, params={"limit": 5}), [200])
        rec("GET  /apps/{id}/diagnostics",
            sget(c, f"{APP}/diagnostics", tok), [200])
        rec("GET  /apps/{id}/files",
            sget(c, f"{APP}/files", tok), [200])
        rec("GET  /apps/{id}/activations/stats",
            sget(c, f"{APP}/activations/stats", tok), [200])
        rec("GET  /apps/{id}/status",
            sget(c, f"{APP}/status", tok), [200])

        # ── AutomationService ─────────────────────────────
        print("\n── AutomationService ──")
        rec("GET  /apps/{id}/background-tasks",
            sget(c, f"{APP}/background-tasks", tok), [200])
        rec("GET  /apps/{id}/watchers",
            sget(c, f"{APP}/watchers", tok), [200])
        rec("GET  /apps/{id}/background-sessions",
            sget(c, f"{APP}/background-sessions", tok), [200])

        # ── WidgetsRuntimeService ─────────────────────────
        print("\n── WidgetsRuntimeService ──")
        rec("GET  /apps/{id}/widgets/validate",
            sget(c, f"{APP}/widgets/validate", tok),
            [200, 404], "(404 OK no widgets)")
        rec("GET  /apps/{id}/preview-server/status",
            sget(c, f"{APP}/preview-server/status", tok),
            [200, 404], "(404 OK no preview server)")

        # ── AppAdminService ──────────────────────────────
        print("\n── AppAdminService ──")
        rec("GET  /apps/{id}/quota",
            sget(c, f"{APP}/quota", tok),
            [200, 403, 404], "(403 OK for non-admin)")
        rec("GET  /apps/{id}/secrets",
            sget(c, f"{APP}/secrets", tok), [200, 403])
        rec("GET  /apps/{id}/required-secrets",
            sget(c, f"{APP}/required-secrets", tok), [200])
        rec("GET  /apps/{id}/approvals",
            sget(c, f"{APP}/approvals", tok), [200])
        rec("GET  /apps/{id}/mcp/pending-oauth",
            sget(c, f"{APP}/mcp/pending-oauth", tok),
            [200, 404], "(404 OK no MCP servers)")

        # ── MiscApiService ───────────────────────────────
        print("\n── MiscApiService ──")
        rec("GET  /auth/sessions",
            sget(c, f"{BASE}/auth/sessions", tok), [200])
        rec("GET  /api/config/browse",
            sget(c, f"{BASE}/api/config/browse", tok,
                 params={"path": "."}),
            [200, 403, 404], "(4xx OK for non-admin)")
        rec("GET  /api/discovery/templates",
            sget(c, f"{BASE}/api/discovery/templates", tok), [200])
        rec("GET  /api/discovery/triggers",
            sget(c, f"{BASE}/api/discovery/triggers", tok), [200])
        rec("GET  /api/discovery/triggers/configured",
            sget(c, f"{BASE}/api/discovery/triggers/configured", tok),
            [200])
        rec("GET  /api/mcp/pool/health",
            sget(c, f"{BASE}/api/mcp/pool/health", tok),
            [200, 404])
        rec("GET  /api/transcribe/health",
            sget(c, f"{BASE}/api/transcribe/health", tok),
            [200, 404])
        rec("GET  /apps/{id}/notifications/active",
            sget(c, f"{APP}/notifications/active", tok), [200])

    passed = sum(1 for ok, *_ in RESULTS if ok)
    total = len(RESULTS)
    print(f"\n=> {passed}/{total} PASS ({total - passed} FAIL/ERR)")
    if passed < total:
        print("\nFailures:")
        for ok, label, extra in RESULTS:
            if not ok:
                print(f"  {label}  {extra}")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
