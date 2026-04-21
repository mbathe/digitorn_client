"""Scout: verify pressure math across a real turn.

The user flagged that the client's percentage is wrong.  Hypothesis:
  * Daemon's `pressure` is `estimated_tokens / max_tokens` (raw).
  * Daemon ALSO sends `threshold` in the hook payload — the YAML
    compaction trigger.
  * Client should display `pressure / threshold` so "100 %" means
    "about to compact", which is actionable.

We send one message, dump every `hook`/`result` that carries
context, and check both identities:
  * raw math: estimated_tokens ≈ pressure * max_tokens ?
  * threshold stability: does it change within a turn ?
"""
import json
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


def main() -> None:
    client = DevClient.with_user(
        email="admin",
        password="admin1234admin",
        daemon_url="http://127.0.0.1:8000",
    )
    app_id = sys.argv[1] if len(sys.argv) > 1 else "digitorn-chat"
    sid = f"scout-pressure-{uuid.uuid4().hex[:8]}"
    session = SessionHandle(
        session_id=sid,
        app_id=app_id,
        daemon_url=client.daemon_url,
        workspace="",
    )
    print(f"\n=== Pressure scout app={app_id} session={sid} ===\n")

    stream = client.send_live(
        session,
        "Write a 150-word explanation of how TCP works.",
        total_timeout=90,
    )
    try:
        deadline = time.time() + 90
        while time.time() < deadline:
            if any(e.get("type") == "message_done"
                   for e in stream.events()):
                break
            time.sleep(0.25)

        envs = stream.events()

        print(f"{'seq':>8}  {'src':<24} {'pressure':>9}  "
              f"{'threshold':>9}  {'est':>8}  {'max':>8}  "
              f"{'est/max':>9}  {'pres/thr':>9}")
        print("-" * 105)
        thresholds_seen: set[float] = set()
        for env in envs:
            t = env.get("type", "?")
            pl = env.get("payload") or env.get("data") or {}
            ctx = None
            src = None
            if t == "hook":
                act = pl.get("action_type")
                if act in ("context_status", "compact_context"):
                    ctx = pl.get("details") or {}
                    src = f"hook/{act}"
            elif t in {"result", "turn_complete"}:
                ctx = pl.get("context") or {}
                src = "result.context"
            if not ctx or not src:
                continue
            pressure = ctx.get("pressure")
            threshold = ctx.get("threshold")
            est = ctx.get("estimated_tokens") \
                or ctx.get("total_estimated_tokens")
            mx = ctx.get("max_tokens") or ctx.get("effective_max")
            if threshold is not None:
                thresholds_seen.add(float(threshold))
            raw = (est / mx) if est and mx else None
            display = (pressure / threshold) \
                if (pressure and threshold) else None
            print(
                f"{env.get('seq'):>8}  {src:<24} "
                f"{pressure if pressure is not None else '-':>9}  "
                f"{threshold if threshold is not None else '-':>9}  "
                f"{est if est is not None else '-':>8}  "
                f"{mx if mx is not None else '-':>8}  "
                f"{(f'{raw:.4f}' if raw is not None else '-'):>9}  "
                f"{(f'{display:.4f}' if display is not None else '-'):>9}"
            )

        print(f"\nthresholds observed in session: {sorted(thresholds_seen)}")

        # Dump `result.context` once, in full, since threshold is NOT
        # in it (per the compaction scout) — that's what the client
        # has to stitch together.
        for env in envs:
            if env.get("type") in {"result", "turn_complete"}:
                pl = env.get("payload") or env.get("data") or {}
                ctx = pl.get("context") or {}
                if ctx:
                    print("\n--- result.context (end of turn) ---")
                    print(json.dumps(ctx, indent=2))
                    break
    finally:
        stream.stop(timeout=2.0)


if __name__ == "__main__":
    main()
