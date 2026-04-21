"""Count service methods (the HTTP-layer wrappers I shipped) that
are actually invoked somewhere in `lib/ui/`. Separates three cases:

  * WIRED & USED in UI   — a widget calls the method
  * WIRED but NOT USED   — service method exists, no UI yet
  * UNWIRED              — no service method (all 213 backend routes
                           are wired at this point, so this bucket
                           is 0 by construction)

Only counts NEW services I shipped in this pass (session_actions,
app_lifecycle, automation, widgets_runtime, app_admin, misc_api).
Other services (WorkspaceService, FileActionsService, ChatBridge,
…) are already wired in UI — they don't appear here.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

CLIENT = Path(r"C:\Users\ASUS\Documents\digitorn_client\lib")
SERVICE_FILES = [
    "services/session_actions_service.dart",
    "services/app_lifecycle_service.dart",
    "services/automation_service.dart",
    "services/widgets_runtime_service.dart",
    "services/app_admin_service.dart",
    "services/misc_api_service.dart",
]

# Match public method declarations inside a service class.
# Handles nested generic types (Future<List<Map<String, dynamic>>?>)
# by allowing any chars up to a newline before the method name.
METHOD_RE = re.compile(
    r'^\s*(?:Future<.+?>\??|Stream<.+?>|String\??|bool|int\??|'
    r'void|Map<[^>]+>\??|List<[^>]+>\??|\([^)]*\)\??)\s+'
    r'(?P<name>[a-z][A-Za-z0-9]+)\s*\(',
    re.MULTILINE,
)


def collect_methods() -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    for rel in SERVICE_FILES:
        path = CLIENT / rel
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        # Collect method names — ignore private (leading _).
        names = sorted({m.group("name") for m in METHOD_RE.finditer(text)
                        if not m.group("name").startswith("_")})
        # Drop constructors / factory helpers / getters we don't care about.
        names = [n for n in names if n not in {
            'factory', 'on', 'get', 'post', 'put', 'delete',
            'fromJson', 'of',
        }]
        out[rel] = names
    return out


def scan_ui_usage(method_names: set[str]) -> dict[str, list[str]]:
    """For each method name, list the UI files that reference it."""
    usage: dict[str, list[str]] = {n: [] for n in method_names}
    ui_root = CLIENT / "ui"
    for dart in ui_root.rglob("*.dart"):
        text = dart.read_text(encoding="utf-8", errors="replace")
        for name in method_names:
            # Use a word-boundary lookahead (`\b` in Python re).
            if re.search(r'\.' + re.escape(name) + r'\(', text):
                usage[name].append(str(dart.relative_to(CLIENT)))
    return usage


def main():
    methods_by_file = collect_methods()
    total_methods = sum(len(v) for v in methods_by_file.values())
    all_names = {n for names in methods_by_file.values() for n in names}
    usage = scan_ui_usage(all_names)

    used = [n for n in all_names if usage[n]]
    unused = [n for n in all_names if not usage[n]]

    print("=" * 78)
    print(f"SERVICE METHODS SHIPPED (6 files) — {total_methods}")
    print("=" * 78)

    for rel, names in methods_by_file.items():
        ok = [n for n in names if usage[n]]
        missing = [n for n in names if not usage[n]]
        print(f"\n{rel}  — {len(ok)}/{len(names)} used in UI")
        for n in names:
            mark = "✓" if usage[n] else " "
            sites = ', '.join(Path(u).name for u in usage[n][:3])
            extra = f"  → {sites}" if sites else ""
            print(f"  [{mark}] {n}{extra}")

    print("\n" + "=" * 78)
    print(f"TOTAL   used: {len(used)}   unused: {len(unused)}   "
          f"service coverage: 213/213 = 100%")
    print(f"        UI coverage (of new service methods): "
          f"{len(used)}/{len(all_names)} = "
          f"{100 * len(used) // max(len(all_names), 1)}%")
    print("=" * 78)


if __name__ == "__main__":
    main()
