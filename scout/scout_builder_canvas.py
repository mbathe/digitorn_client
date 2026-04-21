"""Scout: end-to-end canvas pipeline for `render_mode: builder`.

Goal — confirm the client has everything it needs to render the
BuilderCanvas when a user opens a digitorn-builder session:

  1. `GET /sessions/{sid}/workspace`  → meta.render_mode == 'builder'
  2. `preview:snapshot` / `preview:state_changed` carries
     state.workspace.{render_mode, entry_file, title}
  3. `preview:resource_set` / `resource_patched` on channel 'files':
     * app.yaml         — the YAML the canvas parses
     * _state/progress.json — phase indicator
     * _state/compile.json  — compile errors
     * _state/deploy.json   — deploy status
     * _state/tests.json    — tests status
  4. `workspace.entry_file` points at app.yaml.
  5. app.yaml parses cleanly into triggers / agents / modules /
     capabilities.grant — the fields the canvas derives nodes from.
"""
import json
import os
import sys
import time
import uuid

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

sys.path.insert(0, r"C:\Users\ASUS\Documents\digitorn-bridge\packages")

from digitorn.testing import DevClient  # noqa: E402
from digitorn.testing.models import SessionHandle  # noqa: E402


def _pretty(v):
    return json.dumps(v, indent=2, default=str, ensure_ascii=False)


def _short(v, n=180):
    s = json.dumps(v, default=str, ensure_ascii=False)
    return s if len(s) <= n else f"{s[:n]}… ({len(s)}B)"


def _ok(msg):
    print(f"  \u2713 {msg}")


def _fail(msg):
    print(f"  \u2717 {msg}")


def main():
    client = DevClient.with_user(
        email="admin", password="admin1234admin",
        daemon_url="http://127.0.0.1:8000",
    )
    app_id = "digitorn-builder"
    sandbox = r"C:\Users\ASUS\Documents\digitorn_client\scout\_sandbox_canvas"
    os.makedirs(sandbox, exist_ok=True)
    sid = f"scout-cv-{uuid.uuid4().hex[:6]}"
    session = SessionHandle(
        session_id=sid, app_id=app_id,
        daemon_url=client.daemon_url, workspace=sandbox,
    )
    print(f"\n\u2554\u2550\u2550\u2550 Builder canvas scout  session={sid} \u2550\u2550\u2550\u2557\n")

    # ── STEP 1a — PRE-bootstrap probe (expected 404) ──────────────────
    #
    # The daemon doesn't know about a session until the first message
    # lands. The client handles this by fetching meta from
    # `_onSessionChange`, which fires AFTER `createAndSetSession` has
    # completed — so in practice the client never hits this race.
    print("\u25b6 STEP 1a: GET /sessions/{sid}/workspace  (before bootstrap)")
    r0 = client._get(f"/api/apps/{app_id}/sessions/{sid}/workspace")
    print(f"  HTTP {r0.status_code}  (expected 404 — session doesn't exist yet)")

    # ── STEP 2 — prompt the builder to draft an app ────────────────────
    print("\n\u25b6 STEP 2: ask the builder to scaffold a minimal app")
    stream = client.send_live(
        session,
        "Create a minimal Digitorn app called 'canvas-probe'. It should "
        "have one manual trigger, one agent named 'coordinator' using any "
        "LLM brain, and two modules: filesystem and shell. Grant the "
        "coordinator read/write access to filesystem and exec to shell. "
        "Write app.yaml only, reply 'ok' in one word when done.",
        total_timeout=180,
    )
    deadline = time.time() + 180
    while time.time() < deadline:
        if any(e.get("type") == "message_done" for e in stream.events()):
            break
        time.sleep(0.3)
    envs = stream.events()
    stream.stop(timeout=1.0)

    # ── STEP 1b — POST-bootstrap probe (what the client actually sees) ─
    print("\n\u25b6 STEP 1b: GET /sessions/{sid}/workspace  (after bootstrap)")
    r = client._get(f"/api/apps/{app_id}/sessions/{sid}/workspace")
    print(f"  HTTP {r.status_code}")
    meta = None
    try:
        body = r.json()
        data = (body.get("data") or body)
        print(_pretty({k: data.get(k) for k in
                       ("render_mode", "entry_file", "title", "workspace")}))
        meta = data
    except Exception as ex:
        _fail(f"JSON decode: {ex!r}")
        print(r.text[:300])

    if meta:
        if meta.get("render_mode") == "builder":
            _ok("render_mode == 'builder'  (triggers BuilderCanvas)")
        else:
            _fail(f"render_mode = {meta.get('render_mode')!r} "
                  f"(client would NOT mount canvas)")
        if meta.get("entry_file") == "app.yaml":
            _ok("entry_file == 'app.yaml'")
        else:
            print(f"  ? entry_file = {meta.get('entry_file')!r}")

    # ── STEP 3 — inspect preview events ────────────────────────────────
    print("\n\u25b6 STEP 3: preview event histogram")
    preview_types = {}
    for env in envs:
        t = env.get("type", "?")
        if t.startswith("preview:"):
            preview_types[t] = preview_types.get(t, 0) + 1
    for t, n in sorted(preview_types.items(), key=lambda x: -x[1]):
        print(f"    {n:3d}  {t}")

    # Track files that landed via preview:resource_set / _patched
    files_seen = {}
    workspace_state = None
    for env in envs:
        t = env.get("type", "?")
        pl = env.get("payload") or env.get("data") or {}
        if t == "preview:state_changed":
            if pl.get("key") == "workspace":
                workspace_state = pl.get("value")
        if t == "preview:snapshot":
            snap_state = pl.get("state") or {}
            if isinstance(snap_state.get("workspace"), dict):
                workspace_state = snap_state["workspace"]
            resources = pl.get("resources") or {}
            for path, meta_ in (resources.get("files") or {}).items():
                files_seen[path] = meta_
        if t in ("preview:resource_set", "preview:resource_patched"):
            if pl.get("channel") == "files":
                files_seen[pl.get("id")] = pl.get("payload") or {}

    print("\n\u25b6 STEP 4: workspace state (from preview:state_changed / snapshot)")
    if workspace_state:
        print(_pretty(workspace_state))
        for k in ("render_mode", "entry_file", "title"):
            v = workspace_state.get(k)
            print(f"  {'\u2713' if v else '\u2717'} state.workspace.{k} = {v!r}")
    else:
        _fail("no workspace state received — canvas would wait forever")

    print(f"\n\u25b6 STEP 5: files pushed in preview events ({len(files_seen)})")
    for path in sorted(files_seen.keys()):
        pl = files_seen[path] or {}
        content = pl.get("content") or ""
        length = len(content) if isinstance(content, str) else 0
        print(f"    {path:<40}  {length:>5}B  validation={pl.get('validation')}")

    # ── STEP 6 — fetch the authoritative app.yaml ─────────────────────
    print("\n\u25b6 STEP 6: GET app.yaml (authoritative, ?include_baseline=true)")
    r = client._get(
        f"/api/apps/{app_id}/sessions/{sid}/workspace/files/app.yaml"
        "?include_baseline=true"
    )
    yaml_body = None
    try:
        body = r.json()
        data = (body.get("data") or body)
        pl = data.get("payload") or {}
        yaml_body = pl.get("content") or ""
        print(f"  HTTP {r.status_code}  content={len(yaml_body)}B  "
              f"validation={pl.get('validation')}")
        if yaml_body:
            print("\n  --- preview ---")
            for line in yaml_body.split("\n")[:25]:
                print(f"    {line}")
            if yaml_body.count("\n") > 25:
                print(f"    ... {yaml_body.count(chr(10)) - 25} more lines")
    except Exception as ex:
        _fail(f"fetch failed: {ex!r}")

    # ── STEP 7 — parse app.yaml the way the Dart canvas would ─────────
    print("\n\u25b6 STEP 7: parse app.yaml as the client does")
    if yaml_body:
        try:
            import yaml  # noqa: WPS433
        except Exception:
            _fail("python `pyyaml` not installed in env — skipping parse")
            yaml = None
        if yaml is not None:
            try:
                doc = yaml.safe_load(yaml_body)
            except Exception as ex:
                _fail(f"YAML parse error: {ex!r}")
                doc = None
            if doc is not None and isinstance(doc, dict):
                triggers = (
                    (doc.get("execution") or {}).get("triggers") or []
                )
                agents = doc.get("agents") or []
                modules = doc.get("modules") or {}
                grants = (
                    (doc.get("capabilities") or {}).get("grant") or []
                )

                print(f"    triggers: {len(triggers)}")
                for t in triggers:
                    print(f"      - {t if not isinstance(t, dict) else _short(t, 120)}")
                print(f"    agents:   {len(agents)}")
                for a in agents:
                    if isinstance(a, dict):
                        print(f"      - id={a.get('id')!r:<20} "
                              f"role={a.get('role')!r:<18} "
                              f"brain={a.get('brain') or a.get('model')!r}")
                    else:
                        print(f"      - {a}")
                print(f"    modules:  {len(modules) if hasattr(modules, '__len__') else '?'}")
                if isinstance(modules, dict):
                    for name in modules.keys():
                        print(f"      - {name}")
                elif isinstance(modules, list):
                    for m in modules:
                        print(f"      - {m}")
                print(f"    grants:   {len(grants)}")
                for g in grants:
                    if isinstance(g, dict):
                        print(f"      - agent={g.get('agent')!r} \u2192 "
                              f"module={g.get('module')!r}  "
                              f"actions={g.get('actions')}")

                print()
                if triggers:
                    _ok(f"triggers derivable \u2192 {len(triggers)} nodes left column")
                else:
                    _fail("no triggers — left column would render 'No triggers defined'")
                if agents:
                    _ok(f"agents derivable \u2192 {len(agents)} nodes center column")
                else:
                    _fail("no agents — center column empty")
                if modules:
                    n = len(modules) if hasattr(modules, '__len__') else 0
                    _ok(f"modules derivable \u2192 {n} nodes right column")
                else:
                    _fail("no modules — right column empty")
                if grants:
                    by_agent = {}
                    for g in grants:
                        if isinstance(g, dict):
                            by_agent.setdefault(
                                g.get("agent"), []
                            ).append(g.get("module"))
                    edges = sum(len(v) for v in by_agent.values())
                    _ok(f"edges derivable \u2192 {edges} agent\u2192module connections")
                else:
                    _fail("no capabilities.grant \u2192 no edges rendered")

    # ── STEP 8 — state overlays ────────────────────────────────────────
    print("\n\u25b6 STEP 8: _state/*.json overlays (phase / compile / deploy / tests)")
    overlay_paths = [
        "_state/progress.json",
        "_state/compile.json",
        "_state/deploy.json",
        "_state/tests.json",
    ]
    for p in overlay_paths:
        meta = files_seen.get(p)
        if meta:
            content = (meta.get("content") or "").strip()
            if content:
                try:
                    parsed = json.loads(content)
                    print(f"  \u2713 {p:<28}  {_short(parsed, 140)}")
                except Exception:
                    print(f"  ? {p:<28}  not JSON  ({len(content)}B)")
            else:
                print(f"  - {p:<28}  empty")
        else:
            print(f"  - {p:<28}  not pushed yet (canvas overlays stay empty)")


if __name__ == "__main__":
    main()
