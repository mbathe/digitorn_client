"""Phase 1.2 — Live exploration of the universal event contract.

Before touching any Flutter production code, prove that:
  * Every event arriving on Socket.IO carries the full envelope
    (event_id, type, kind, seq, ts, correlation_id, op_id, op_type,
    op_state, op_parent_id, payload).
  * Durable events are replayed on join_session with `since`.
  * Snapshots (session/queue/preview/memory/approvals/active_ops)
    land in the documented order.
  * seq is strictly monotone per user; a single session-filtered
    slice therefore exposes gaps (other sessions' events).
  * tool_start / tool_call for the same op share op_id.
  * Ephemeral types (token, thinking_delta, in/out_token,
    streaming_frame, assistant_stream_snapshot, preview:delta,
    agent_progress) are NOT replayed (never hit the durable log).

Runs four scenarios:
  A. fresh session → send a message → wait done → join fresh
  B. join DURING the turn (before done) → inspect active_ops
  C. inspect op_id parity for tool_start ↔ tool_call pairs
  D. test contract rigor: any replayed event lacking op_id / op_type
     is a server bug → print it

Run::

    py -3.12 scout/explore_events.py
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import time
import uuid
from collections import Counter, defaultdict
from typing import Any

import httpx
from socketio import AsyncClient

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

BASE = os.environ.get("DIGITORN_BASE", "http://127.0.0.1:8000")

# Fields that MUST be present on every real (non-snapshot, non-handshake)
# event. If any of these is missing, we flag the envelope as a contract
# violation in Part D and dump it.
REQUIRED_FIELDS = (
    "event_id", "type", "kind", "seq", "ts",
    "session_id", "correlation_id",
    "op_id", "op_type", "op_state",
)
SNAPSHOT_TYPES = {
    "connected", "preview:snapshot", "queue:snapshot",
    "active_ops:snapshot", "session:snapshot",
    "memory:snapshot", "approvals:snapshot",
    "workspace:snapshot",
}
# Daemon-declared ephemeral types (must NEVER appear in a replay).
EPHEMERAL_TYPES = {
    "token", "thinking_delta", "thinking_started", "thinking",
    "in_token", "out_token", "preview:delta",
    "agent_progress", "streaming_frame", "assistant_stream_snapshot",
}


def _auth(tok: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {tok}"}


def _register(c: httpx.Client) -> tuple[str, str]:
    uname = f"explore{uuid.uuid4().hex[:8]}"
    email = f"{uname}@test.local"
    pwd = "ExploreProd1234!xyz"
    r = c.post(f"{BASE}/auth/register", json={
        "username": uname, "email": email, "password": pwd,
    })
    if r.status_code != 200:
        r = c.post(f"{BASE}/auth/login",
                   json={"email": email, "password": pwd})
    d = r.json()
    return uname, d["access_token"]


def _post_msg(c: httpx.Client, tok: str, app_id: str, sid: str,
              msg: str) -> dict:
    r = c.post(
        f"{BASE}/api/apps/{app_id}/sessions/{sid}/messages",
        headers=_auth(tok), json={"message": msg}, timeout=60.0,
    )
    return r.json()


def _get_events(c: httpx.Client, tok: str, app_id: str, sid: str,
                since: int = 0) -> list[dict]:
    r = c.get(
        f"{BASE}/api/apps/{app_id}/sessions/{sid}/events",
        headers=_auth(tok),
        params={"since_seq": since, "limit": 500},
        timeout=15.0,
    )
    if r.status_code != 200:
        return []
    return (r.json().get("data") or {}).get("events", [])


def _wait_done(c: httpx.Client, tok: str, app_id: str, sid: str,
               cid: str, timeout: float = 120.0) -> bool:
    deadline = time.monotonic() + timeout
    seen = 0
    while time.monotonic() < deadline:
        for ev in _get_events(c, tok, app_id, sid, since=seen):
            if ev["seq"] > seen:
                seen = ev["seq"]
            done_match = ev.get("type") in (
                "message_done", "message_cancelled",
            ) and (ev.get("payload") or {}).get(
                "correlation_id") == cid
            top_corr = ev.get("correlation_id") == cid
            if (done_match or (
                    ev.get("type") == "message_done" and top_corr)):
                return True
        time.sleep(0.8)
    return False


async def _join_and_collect(
    tok: str, app_id: str, sid: str,
    since: int = 0, hold_seconds: float = 3.0,
) -> tuple[dict, list[dict]]:
    """Connect, join_session with `since`, collect every envelope for
    `hold_seconds`. Returns (ack, envelopes_in_arrival_order)."""
    envelopes: list[dict] = []
    sio = AsyncClient()

    @sio.on("event", namespace="/events")
    async def _on(env: dict) -> None:
        envelopes.append(env)

    await sio.connect(
        BASE, namespaces=["/events"],
        auth={"token": tok},
        transports=["websocket"],
        wait=True, wait_timeout=10.0,
    )
    ack: dict = {}
    try:
        raw = await sio.call(
            "join_session",
            {"app_id": app_id, "session_id": sid, "since": since},
            namespace="/events", timeout=10.0,
        )
        if isinstance(raw, dict):
            ack = raw
        await asyncio.sleep(hold_seconds)
    finally:
        await sio.disconnect()
    return ack, envelopes


# ─────────────────────────────────────────────────────────────────
# Reporters
# ─────────────────────────────────────────────────────────────────

def _print_histogram(envs: list[dict], title: str) -> None:
    counts = Counter(e.get("type", "?") for e in envs)
    print(f"\n  ── {title} ({len(envs)} envs) ──")
    for t, n in counts.most_common():
        marker = " ⚡" if t in EPHEMERAL_TYPES else (
            " 📸" if t in SNAPSHOT_TYPES else "")
        print(f"    {n:4d}  {t}{marker}")


def _check_seq_monotonic(envs: list[dict]) -> None:
    # Filter out handshake / snapshot envelopes — they aren't ordered
    # by seq (snapshots are re-synthesized on each join with fresh
    # seqs).
    live = [e for e in envs if e.get("type") not in SNAPSHOT_TYPES]
    seqs = [(e.get("seq"), e.get("type"), e.get("session_id"))
            for e in live if isinstance(e.get("seq"), int)]
    if not seqs:
        print("  seq: no live events to inspect")
        return
    prev = -1
    gaps = 0
    dupes = 0
    cross_session = 0
    for seq, t, s in seqs:
        if prev >= 0 and seq <= prev:
            dupes += 1
            print(f"    non-monotonic: seq={seq} <= prev={prev} "
                  f"type={t} sid={s}")
        if prev >= 0 and seq > prev + 1:
            gaps += 1
        prev = seq
    print(f"  seq span: [{seqs[0][0]}..{seqs[-1][0]}] "
          f"count={len(seqs)}  gaps={gaps}  dupes={dupes}")
    sessions = {s for _, _, s in seqs if s}
    if len(sessions) > 1:
        cross_session = len(sessions)
    print(f"  distinct session_ids in stream: {len(sessions)} "
          f"{'(SHARED seq space with other sessions)' if cross_session > 1 else ''}")


def _check_contract(envs: list[dict]) -> list[tuple[str, int, list[str]]]:
    """Return a list of (type, seq, missing_fields) for every live event
    that's missing a contract field. Accepts either top-level OR
    `payload[...]` — the daemon's canonical shape ships contract fields
    inside `payload` (`session_event_contract_v2`)."""
    violations: list[tuple[str, int, list[str]]] = []
    for e in envs:
        t = e.get("type", "")
        if t in SNAPSHOT_TYPES:
            continue
        if t in EPHEMERAL_TYPES:
            continue  # ephemeral — contract is lighter
        payload = e.get("payload") or {}
        missing = []
        for f in REQUIRED_FIELDS:
            v = e.get(f)
            if v in (None, ""):
                v = payload.get(f)
            if v in (None, ""):
                if f == "correlation_id":
                    continue  # system events legitimately have no cid
                missing.append(f)
        if missing:
            violations.append((t, e.get("seq", -1), missing))
    return violations


def _op_parity(envs: list[dict]) -> None:
    """Look at tool_start / tool_call pairs: same op_id? Same op?"""
    per_op = defaultdict(list)
    for e in envs:
        t = e.get("type", "")
        if t not in ("tool_start", "tool_call"):
            continue
        opid = e.get("op_id") or (e.get("payload") or {}).get("op_id")
        per_op[opid].append((e.get("seq"), t, e.get("op_state")))
    if not per_op:
        print("  no tool events in this window")
        return
    print("  tool_* groups by op_id:")
    for opid, evs in per_op.items():
        evs.sort(key=lambda x: (x[0] or 0))
        types = [x[1] for x in evs]
        states = [x[2] for x in evs]
        paired = "tool_start" in types and "tool_call" in types
        mark = "✓" if paired else "!"
        print(f"    {mark}  op_id={opid!r:<30}  events={types}  "
              f"states={states}")


def _ephemeral_in_replay(envs: list[dict]) -> None:
    leaked = [(e.get("seq"), e.get("type")) for e in envs
              if e.get("type") in EPHEMERAL_TYPES]
    if not leaked:
        print("  ephemeral-in-replay check: PASS "
              "(no ephemeral types in this window)")
    else:
        print(f"  ephemeral-in-replay check: FAIL — "
              f"{len(leaked)} ephemeral events seen")
        for seq, t in leaked[:10]:
            print(f"    seq={seq}  {t}")


def _snapshot_order(envs: list[dict]) -> None:
    """Where do the snapshots land vs real events?"""
    arrival_index = {t: i for i, e in enumerate(envs)
                     for t in [e.get("type", "")]
                     if t not in arrival_index} if False else None
    # Track first-arrival index of each snapshot type.
    first: dict[str, int] = {}
    for i, e in enumerate(envs):
        t = e.get("type", "")
        if t in SNAPSHOT_TYPES and t not in first:
            first[t] = i
    print("  snapshot arrival index (in arrival order):")
    for t in sorted(first, key=lambda x: first[x]):
        print(f"    [{first[t]:4d}]  {t}")


# ─────────────────────────────────────────────────────────────────
# Scenarios
# ─────────────────────────────────────────────────────────────────

async def scenario_a_fresh_then_join() -> None:
    print("\n══ A. fresh session → send → wait done → join ══")
    with httpx.Client(timeout=30.0) as c:
        _, tok = _register(c)
        app_id = "digitorn-chat"
        sid = f"explore-a-{uuid.uuid4().hex[:8]}"
        post = _post_msg(c, tok, app_id, sid,
                         "Reply 'hi' in one word.")
        cid = (post.get("data") or {}).get("correlation_id")
        print(f"  POST /messages  cid={cid}")
        ok = _wait_done(c, tok, app_id, sid, cid, timeout=90.0)
        print(f"  turn completed: {ok}")

    ack, envs = await _join_and_collect(tok, app_id, sid, since=0)
    print(f"  join ack: {json.dumps(ack)[:200]}")
    _print_histogram(envs, "A: full join after done")
    _snapshot_order(envs)
    _check_seq_monotonic(envs)
    _ephemeral_in_replay(envs)
    _op_parity(envs)
    v = _check_contract(envs)
    print(f"  contract violations on durable events: {len(v)}")
    for t, s, m in v[:10]:
        print(f"    type={t}  seq={s}  missing={m}")


async def scenario_b_join_mid_turn() -> None:
    print("\n══ B. join DURING the turn (mid-flight) ══")
    with httpx.Client(timeout=60.0) as c:
        _, tok = _register(c)
        app_id = "digitorn-chat"
        sid = f"explore-b-{uuid.uuid4().hex[:8]}"
        # Long-ish prompt so the turn is still live when we join.
        post = _post_msg(
            c, tok, app_id, sid,
            "Write a 10-line poem about replay and reconnection. "
            "Take your time; each line on its own.",
        )
        cid = (post.get("data") or {}).get("correlation_id")
        print(f"  POST /messages  cid={cid}")
        # No wait — join IMMEDIATELY.
        ack, envs = await _join_and_collect(
            tok, app_id, sid, since=0, hold_seconds=5.0,
        )

    print(f"  join ack: {json.dumps(ack)[:200]}")
    _print_histogram(envs, "B: join mid-turn")
    _snapshot_order(envs)
    active_snaps = [e for e in envs
                    if e.get("type") == "active_ops:snapshot"]
    for s in active_snaps:
        p = s.get("payload") or {}
        ops = p.get("active_ops") or []
        turn_ops = [o for o in ops if o.get("op_type") == "turn"]
        tool_ops = [o for o in ops if o.get("op_type") == "tool"]
        print(f"  active_ops: count={p.get('count')} "
              f"turn={len(turn_ops)}  tool={len(tool_ops)}")
        for o in ops:
            print(f"    op_id={o.get('op_id')!r:<30} "
                  f"type={o.get('op_type'):<10} "
                  f"state={o.get('op_state')}")
    sess_snaps = [e for e in envs
                  if e.get("type") == "session:snapshot"]
    for s in sess_snaps:
        p = s.get("payload") or {}
        print(f"  session:snapshot turn_running={p.get('turn_running')}"
              f"  message_count={p.get('message_count')}")


async def scenario_c_incremental_since() -> None:
    print("\n══ C. join with since=N (incremental replay) ══")
    with httpx.Client(timeout=90.0) as c:
        _, tok = _register(c)
        app_id = "digitorn-chat"
        sid = f"explore-c-{uuid.uuid4().hex[:8]}"
        # Turn 1 — establish a baseline.
        post = _post_msg(c, tok, app_id, sid, "Hello.")
        cid = (post.get("data") or {}).get("correlation_id")
        _wait_done(c, tok, app_id, sid, cid, timeout=90.0)
        # Pick the last seq we saw on HTTP.
        baseline = _get_events(c, tok, app_id, sid, since=0)
        last_seq = max((e.get("seq", 0) for e in baseline), default=0)
        print(f"  baseline ended at seq={last_seq} "
              f"({len(baseline)} durable events)")

        # Turn 2 — add more events AFTER `last_seq`.
        post2 = _post_msg(c, tok, app_id, sid, "Say hi again.")
        cid2 = (post2.get("data") or {}).get("correlation_id")
        _wait_done(c, tok, app_id, sid, cid2, timeout=90.0)

    # Join with since=last_seq — we expect only turn-2 events.
    ack, envs = await _join_and_collect(
        tok, app_id, sid, since=last_seq, hold_seconds=3.0,
    )
    print(f"  join ack: {json.dumps(ack)[:200]}")
    _print_histogram(envs, f"C: since={last_seq}")
    # Every replayed event should have seq > last_seq.
    durable = [e for e in envs
               if e.get("type") not in SNAPSHOT_TYPES]
    below = [e for e in durable
             if isinstance(e.get("seq"), int) and e["seq"] <= last_seq]
    print(f"  replay discipline: {len(below)} events with "
          f"seq <= {last_seq}  (should be 0)")


async def scenario_d_contract_rigor() -> None:
    print("\n══ D. contract rigor on replay ══")
    with httpx.Client(timeout=60.0) as c:
        _, tok = _register(c)
        app_id = "digitorn-chat"
        sid = f"explore-d-{uuid.uuid4().hex[:8]}"
        post = _post_msg(c, tok, app_id, sid,
                         "Say hi then stop.")
        cid = (post.get("data") or {}).get("correlation_id")
        _wait_done(c, tok, app_id, sid, cid, timeout=90.0)

    _, envs = await _join_and_collect(tok, app_id, sid, since=0)
    violations = _check_contract(envs)
    if not violations:
        print(f"  ✓ every durable event carries the full contract "
              f"({len([e for e in envs if e.get('type') not in SNAPSHOT_TYPES])} checked)")
    else:
        print(f"  ✗ {len(violations)} contract violation(s):")
        for t, s, m in violations[:15]:
            print(f"    type={t}  seq={s}  missing={m}")
    # Dump one sample live event so we can see exactly what shape the
    # envelope has today (helps write the Dart model).
    sample = next((e for e in envs
                   if e.get("type") not in SNAPSHOT_TYPES
                   and e.get("seq")), None)
    if sample:
        print("\n  sample live envelope:")
        print(json.dumps({k: sample.get(k) for k in REQUIRED_FIELDS
                          if k in sample}, indent=4))
        pl = sample.get("payload")
        if isinstance(pl, dict):
            print(f"    payload keys: {sorted(pl.keys())}")


async def main() -> int:
    try:
        r = httpx.get(f"{BASE}/health", timeout=5.0)
        if r.status_code != 200:
            print(f"FAIL: daemon unreachable (HTTP {r.status_code})")
            return 1
    except Exception as exc:
        print(f"FAIL: daemon unreachable ({exc})")
        return 1

    print(f"daemon OK at {BASE}")
    await scenario_a_fresh_then_join()
    await scenario_b_join_mid_turn()
    await scenario_c_incremental_since()
    await scenario_d_contract_rigor()
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
