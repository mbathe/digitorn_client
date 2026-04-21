"""Scout: compaction events.

Goal — characterise the exact wire contract for `hook/context_status`,
compaction-start, compaction-end, and the `context` block carried on
`result` envelopes. Specifically:

  * When does `compactions` increment?
  * Are `pressure` drops ALWAYS accompanied by a `compactions` bump?
  * What's the shape of a compaction-start / compaction-end envelope?
  * Does the daemon send one `context` block per turn or several?
  * Does the hook's `estimated_tokens` ever disagree with the
    result's `total_estimated_tokens`?

The scout pushes long messages on a small-context app (digitorn-chat)
to force the daemon into compaction range.
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


def _ctx_summary(ctx: dict | None) -> str:
    if not ctx:
        return "ctx=None"
    parts = []
    for k in (
        "pressure",
        "compactions",
        "total_estimated_tokens",
        "estimated_tokens",
        "effective_max",
        "max_tokens",
        "message_history_tokens",
    ):
        if k in ctx:
            parts.append(f"{k}={ctx[k]}")
    return " ".join(parts) or f"keys={list(ctx.keys())}"


def _pretty(value: object) -> str:
    return json.dumps(value, indent=2, default=str, ensure_ascii=False)


def main() -> None:
    client = DevClient.with_user(
        email="admin",
        password="admin1234admin",
        daemon_url="http://127.0.0.1:8000",
    )
    app_id = "digitorn-chat"
    sid = f"scout-compact-{uuid.uuid4().hex[:8]}"
    session = SessionHandle(
        session_id=sid,
        app_id=app_id,
        daemon_url=client.daemon_url,
        workspace="",
    )
    print(f"\n=== Compaction scout — session={sid} ===\n")

    # Long, structured prompts that accumulate context.  The goal is to
    # burn through the window fast so compaction triggers naturally.
    base = (
        "Please explain in detail: "
        "1) the history of the printing press, 2) the invention of the "
        "telephone, 3) the space race in the 1960s, 4) the origins of "
        "the internet, 5) the rise of smartphones. Give dates, people, "
        "places. Write at least 400 words total."
    )
    prompts = [
        base,
        "Great. Now do the same for: agriculture, the wheel, writing "
        "systems, the steam engine, electricity. 400 words.",
        "Now do the same for: vaccines, penicillin, DNA discovery, "
        "heart transplants, mRNA vaccines. 400 words.",
        "Now do the same for: jazz, rock n roll, hip hop, electronic "
        "music, K-pop. 400 words.",
        "Now do the same for: Ancient Egypt, Roman Empire, Tang Dynasty, "
        "Mongol Empire, Ottoman Empire. 400 words.",
    ]

    stream = client.send_live(session, prompts[0], total_timeout=240)
    try:
        # Drain message 1, then push the rest one by one, waiting for
        # each `message_done` between sends so we stay in a linear
        # turn-by-turn mode.
        def count_dones() -> int:
            return sum(
                1 for e in stream.events()
                if e.get("type") == "message_done"
            )

        expected = 1
        for p in prompts[1:]:
            deadline = time.time() + 180
            while time.time() < deadline and count_dones() < expected:
                time.sleep(0.2)
            print(f"\n>>> sending follow-up turn #{expected + 1}")
            client.post_message_raw(session, p)
            expected += 1

        # Wait for the final turn.
        deadline = time.time() + 240
        while time.time() < deadline and count_dones() < expected:
            time.sleep(0.3)

        envelopes = stream.events()
        print(f"\n--- {len(envelopes)} envelopes total ---\n")

        # Walk the timeline, print only ctx-relevant events.
        interesting = {
            "hook", "result", "message_done", "message_started",
            "context", "context_status", "usage", "compaction",
            "compaction_start", "compaction_end",
        }
        print("--- timeline (ctx-relevant) ---")
        prev_pressure: float | None = None
        prev_compactions: int | None = None
        for env in envelopes:
            t = env.get("type", "?")
            seq = env.get("seq")
            pl = env.get("payload") or env.get("data") or {}
            if t not in interesting:
                # `hook/context_status` lands with type="hook" + kind detail
                # in payload. Also inspect `result.context`.
                if t != "hook":
                    continue
            name = pl.get("name") or pl.get("hook")
            ctx = (
                pl.get("context")
                or pl.get("details")
                or (pl if "pressure" in pl else None)
            )
            if ctx is None and t in {"result", "message_done"}:
                # Result envelopes sometimes nest context deeper.
                ctx = (pl.get("data") or {}).get("context")
            summary = _ctx_summary(ctx)

            # Flag pressure drops / compaction bumps loudly.
            flags = []
            pressure = (ctx or {}).get("pressure")
            compactions = (ctx or {}).get("compactions")
            if isinstance(pressure, (int, float)):
                if prev_pressure is not None and pressure < prev_pressure - 0.005:
                    bumped = (
                        isinstance(compactions, int)
                        and prev_compactions is not None
                        and compactions > prev_compactions
                    )
                    if bumped:
                        flags.append(f"↓PRESS ({prev_pressure:.3f}→{pressure:.3f}) ✓compacted")
                    else:
                        flags.append(f"↓PRESS UNEXPLAINED ({prev_pressure:.3f}→{pressure:.3f})")
                prev_pressure = pressure
            if isinstance(compactions, int):
                if prev_compactions is not None and compactions > prev_compactions:
                    flags.append(f"↑COMPACT {prev_compactions}→{compactions}")
                prev_compactions = compactions

            tag = " ".join(flags)
            line = f"[seq={seq}] type={t}"
            if name:
                line += f" name={name}"
            line += f"  {summary}"
            if tag:
                line += f"   << {tag} >>"
            print(line)

        # Now dump raw context blocks and any compaction-specific events
        # fully, to characterise wire shape.
        print("\n--- FULL context payloads (dedup by seq) ---")
        seen = set()
        for env in envelopes:
            t = env.get("type", "?")
            seq = env.get("seq")
            pl = env.get("payload") or env.get("data") or {}
            ctx = None
            source = None
            if t == "hook":
                name = pl.get("name") or pl.get("hook")
                if name == "context_status":
                    ctx = pl.get("details") or pl
                    source = f"hook/{name}"
            elif t in {"result", "message_done"}:
                ctx = pl.get("context") or (pl.get("data") or {}).get("context")
                source = f"{t}.context"
            if ctx and seq not in seen:
                seen.add(seq)
                print(f"\n[{source}] seq={seq}:")
                print(_pretty(ctx))

        # Also print anything that looks like a compaction marker.
        print("\n--- compaction-looking envelopes ---")
        for env in envelopes:
            t = env.get("type", "?")
            pl = env.get("payload") or env.get("data") or {}
            blob = json.dumps(pl, default=str).lower()
            if "compact" in t.lower() or "compact" in blob[:500]:
                print(f"\nseq={env.get('seq')} type={t}")
                print(_pretty(pl))
    finally:
        stream.stop(timeout=2.0)


if __name__ == "__main__":
    main()
