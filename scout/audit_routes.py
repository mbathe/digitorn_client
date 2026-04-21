"""Systematic audit of backend routes vs client wiring.

1. Walks `digitorn-bridge/packages/digitorn/core/api/*.py` for every
   `@router.<method>("path")` declaration.
2. Walks `digitorn_client/lib/**/*.dart` for every HTTP call that
   matches a path template.
3. Prints the gap: routes the daemon serves but the client never
   hits.

Output is a table sorted by (file, path) so a gap-closing PR can
be scoped file by file.
"""
from __future__ import annotations

import os
import re
import sys
from collections import defaultdict
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

BACKEND = Path(r"C:\Users\ASUS\Documents\digitorn-bridge\packages\digitorn")
CLIENT = Path(r"C:\Users\ASUS\Documents\digitorn_client\lib")

ROUTE_RE = re.compile(
    r'@router\.(?P<method>get|post|put|delete|patch|head|options)\('
    r'\s*["\'](?P<path>[^"\']+)["\']',
)
PREFIX_RE = re.compile(
    r'APIRouter\s*\([^)]*prefix\s*=\s*["\']([^"\']+)["\']',
    re.DOTALL,
)
# All known prefixes in the backend's routing layer. We map file → prefix
# by parsing the APIRouter(...) calls.
PREFIX_OVERRIDES = {
    # Some files are mounted at a different prefix than the APIRouter
    # declares — look them up in the main app wiring.
    "auth": "/auth",
    "config": "/api/config",
    "apps": "/api/apps",
    "modules": "/api/modules",
    "mcp": "/api/mcp",
    "credentials": "/api/credentials",
    "ui": "/api/ui",
    "user": "/api/user",
    "transcribe": "/api/transcribe",
    "packages": "/api/packages",
    "discovery": "/api/discovery",
    "builder": "/api/builder",
    "admin": "/api/admin",
    "triggers": "/api/apps",
    "sessions": "/api/apps",
    "sessions_actions": "/api/apps",
    "workspace": "/api/apps",
    "messages": "/api/apps",
    "tools": "/api/apps",
    "queue_events": "/api/apps",
    "assets": "/api/apps",
    "preview_widgets": "/api/apps",
    "lifecycle": "/api/apps",
}

# Client HTTP call regex — handles:
#   _dio.get('/api/apps/...')
#   c.post(f'{BASE}/api/apps/{appId}/…')
#   http.get(Uri.parse('$_baseUrl/api/...'))
# Catch any string literal containing /api/ OR /auth/ — allowing
# $var, ${expr}, and template tokens. We normalise afterwards.
API_PATH_RE = re.compile(
    r"""['"`]([^'"`\n]*?/(?:api|auth)/[^'"`\n?]*?)['"`]""",
)


def extract_backend_routes():
    routes: list[tuple[str, str, str, int]] = []  # (method, full_path, file, line)
    api_dir = BACKEND / "core" / "api"
    for py in sorted(api_dir.rglob("*.py")):
        if py.name in ("__init__.py", "_imports.py", "_shared.py",
                       "_auth.py", "_errors.py", "security.py",
                       "requires.py"):
            continue
        text = py.read_text(encoding="utf-8", errors="replace")
        stem = py.stem
        prefix = PREFIX_OVERRIDES.get(stem, "")
        # Honour explicit APIRouter(prefix=...) declarations.
        m = PREFIX_RE.search(text)
        if m:
            prefix = m.group(1)
        for i, line in enumerate(text.split("\n"), start=1):
            m = ROUTE_RE.search(line)
            if not m:
                continue
            method = m.group("method").upper()
            path = m.group("path")
            full = prefix + path
            full = re.sub(r"/+", "/", full)
            routes.append((method, full, str(py), i))
    return routes


def normalise(path: str) -> str:
    """Turn `/api/apps/foo-123/sessions/sid-xyz/…` into the template
    form `/api/apps/{}/sessions/{}/…` so client calls match backend
    declarations."""
    out = path.split("?", 1)[0]
    # Dart interpolations.
    out = re.sub(r"\$\{[^}]+\}", "{}", out)
    out = re.sub(r"\$[a-zA-Z_]\w*", "{}", out)
    # Collapse {x:path} / {x} to {}.
    out = re.sub(r"\{[^}]+\}", "{}", out)
    # Trailing concatenations like `{}{}` → the tail {} often
    # represents a query string or optional suffix; strip trailing
    # placeholders for matching.
    out = re.sub(r"(\{\})+$", "", out)
    # Collapse // to /.
    out = re.sub(r"/+", "/", out)
    return out.rstrip("/")


def extract_client_paths():
    called: set[str] = set()
    used_files: dict[str, set[str]] = defaultdict(set)
    for dart in sorted(CLIENT.rglob("*.dart")):
        text = dart.read_text(encoding="utf-8", errors="replace")
        for m in API_PATH_RE.finditer(text):
            raw = m.group(1)
            # Strip any host/base prefix before /api/ or /auth/.
            if "/api/" in raw:
                raw = raw[raw.find("/api/"):]
            elif "/auth/" in raw:
                raw = raw[raw.find("/auth/"):]
            else:
                continue
            norm = normalise(raw)
            if not (norm.startswith("/api/") or norm.startswith("/auth/")):
                continue
            # Drop trailing / and collapse //
            norm = re.sub(r"/+", "/", norm).rstrip("/")
            called.add(norm)
            used_files[norm].add(str(dart))
    return called, used_files


def main():
    print("=" * 80)
    print("Backend routes + client call audit")
    print("=" * 80)

    routes = extract_backend_routes()
    # Dedup: same (method, normalised_path) can appear in both the
    # legacy apps.py and the apps_v2 modular files — keep one entry
    # per signature, prefer apps_v2 as the "active" definition.
    seen_sig: set[tuple[str, str]] = set()
    deduped: list[tuple[str, str, str, int]] = []
    # Second pass prefers apps_v2 files over apps.py.
    for (method, path, file_, line) in sorted(
        routes, key=lambda r: (0 if "apps_v2" in r[2] else 1, r[2]),
    ):
        sig = (method, normalise(path))
        if sig in seen_sig:
            continue
        seen_sig.add(sig)
        deduped.append((method, path, file_, line))
    routes = deduped
    print(f"\nBackend: {len(routes)} unique routes\n")

    called, used_files = extract_client_paths()
    print(f"Client: {len(called)} distinct /api/* paths referenced\n")

    # Group by file for scoped gap reports.
    wired = set()
    wired_hits = defaultdict(list)
    unwired = []
    for method, path, file_, line in routes:
        norm = normalise(path).rstrip("/")
        if norm in called:
            wired.add((method, norm))
            wired_hits[(method, norm)].append((file_, line))
        else:
            unwired.append((method, path, file_, line))

    by_file = defaultdict(list)
    for method, path, file_, line in unwired:
        by_file[Path(file_).name].append((method, path, line))

    # Print unwired routes grouped by file.
    print("=" * 80)
    print(f"UNWIRED ROUTES  ({len(unwired)} / {len(routes)} total)")
    print("=" * 80)
    for fname in sorted(by_file):
        group = by_file[fname]
        print(f"\n── {fname}  ({len(group)} unwired) ──")
        for method, path, line in sorted(group, key=lambda x: x[1]):
            print(f"  {method:6s} {path}  [L{line}]")

    # Wired summary.
    print(f"\n{'=' * 80}")
    print(f"WIRED ROUTES  ({len(wired)}) — already called by the client")
    print("=" * 80)
    for method, path in sorted(wired):
        print(f"  {method:6s} {path}")

    # Unused client calls (sanity — paths that don't match any backend
    # route, probably typos).
    backend_norms = {normalise(p) for _m, p, *_ in routes}
    stray = [p for p in called if p not in backend_norms]
    if stray:
        print(f"\n{'=' * 80}")
        print(f"STRAY CLIENT PATHS  ({len(stray)}) — referenced but no "
              "backend match (possible typo or templated at runtime)")
        print("=" * 80)
        for p in sorted(stray):
            files = sorted(used_files[p])
            for f in files[:3]:
                print(f"  {p}   in {Path(f).name}")
            if len(files) > 3:
                print(f"    … {len(files) - 3} more files")

    print(f"\n{'=' * 80}")
    print(f"SUMMARY — backend {len(routes)}  wired {len(wired)}  "
          f"unwired {len(unwired)}")
    print("=" * 80)


if __name__ == "__main__":
    main()
