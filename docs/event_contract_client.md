# Universal event contract — client-side guide

This doc pairs with the daemon spec (`session_event_contract_v2`). It
documents how the Flutter client consumes the contract, why the
ordering fix matters, and how to add a new event type without
regressing the invariants.

## The wire shape (scout-verified 2026-04-20)

Every durable envelope emitted on the `/events` namespace has this
shape:

```jsonc
{
  // top-level — transport
  "type": "tool_start",
  "kind": "session",
  "seq": 12845,                         // MONOTONE PER USER
  "ts": "2026-04-20T11:03:33.171288Z",
  "session_id": "fp-abc123",

  // payload — contract + type-specific data
  "payload": {
    "event_id": "ev-a1b2c3d4e5f6",      // unique across rooms/fanout
    "op_id": "op-tool-xyz",             // the op this event belongs to
    "op_type": "tool",                  // turn|tool|agent|approval|compact|system
    "op_state": "running",              // pending|running|waiting_approval|
                                        //   completed|failed|cancelled|timeout
    "op_parent_id": null,               // nested ops (tool inside a sub-agent)
    "correlation_id": "fp-abc123",      // the turn this op is part of
    "session_id": "fp-abc123",
    // … type-specific data (tool_name, content, result, …)
  }
}
```

**The contract lives in `payload`**, not at the envelope root — that's
the daemon's canonical shape. [`EventEnvelope.fromJson`](../lib/models/event_envelope.dart)
reads payload first and falls back to top-level for forward-
compatibility if the daemon ever migrates fields upward.

### Top-level (transport)
`type`, `kind`, `seq`, `ts`, `session_id` — always present. Used for
routing, ordering, and filtering. Never holds contract semantics.

### Payload (canonical contract + data)
`event_id`, `op_id`, `op_type`, `op_state` **MUST** be present on
every durable event. A missing field throws [`ContractError`]; the
client never reads contract fields with `??` silent fallbacks. If a
field is genuinely optional (`op_parent_id`, `correlation_id`) the
code checks for null explicitly.

## Invariants

1. **seq is monotone per USER, not per session.** Two concurrent
   sessions of the same user share the seq space. Filter by
   `session_id` before ordering (the registry does this at
   `ingest`).

2. **Events of one op share `op_id`.**
   - `turn` — `op_id == correlation_id` (scout-confirmed for fast-
     path turns; same for queue-ingested turns).
   - `tool` — `op-tool-<hex>`.
   - `agent` — the sub-agent's id.
   - `approval` — approval request id.
   - `compact` — `op-compact-<hex>`.
   - `_system` — always-running session heartbeat; **excluded from
     the UI chat feed** by default (see `activeOps(includeSystem:)`).

3. **Terminal states are final.** `completed / failed / cancelled /
   timeout` — no further event for that `op_id` will arrive. A tool
   chip / agent pill / approval modal can bind to
   [`OpRegistry.latestFor(opId)`] and stop rendering "in-flight"
   UI once the state is terminal.

4. **Ephemeral types never touch the durable log.** `token`,
   `thinking_delta`, `thinking_started`, `thinking`, `in_token`,
   `out_token`, `assistant_stream_snapshot`, `streaming_frame`,
   `preview:delta`, `agent_progress` — they fly on the live socket
   only and are routed to a volatile stream buffer. Feeding them to
   the registry throws [`EphemeralInRegistryError`] to catch
   misrouting in dev.

5. **Dedup is by `event_id`.** A room-fanned-out `approval_request`
   delivers twice (user-room + session-room). The `Set<String>
   _seenEventIds` in the registry absorbs the copy.

## Hydration on `join_session`

The daemon emits, in order, after `socket.emit('join_session',
{app_id, session_id, since})`:

```
1. connected                    (handshake — first event on the socket)
2. [replay]                     (every durable event with seq > since)
3. preview:snapshot             (if app has a preview module)
4. queue:snapshot               (pending messages + is_active + running_correlation_id)
5. active_ops:snapshot          ← the "what was running?" answer
6. session:snapshot             (title, tokens, turn_running, message_count)
7. memory:snapshot              (goal, todos, facts — if memory module)
8. approvals:snapshot           (only emitted when count > 0)
```

`preview:` and `approvals:` are **conditional** — absent when the
app has no preview module or no pending approvals. The client tolerates
both.

### `active_ops:snapshot` is the reconciliation anchor

Payload carries `active_ops: [{op_id, op_type, op_state, last_seq,
first_seq, last_type, correlation_id, op_parent_id?, ...}]` for every
non-terminal op at join time.
[`OpRegistry.reconcileActiveOps`] walks the list and, for every op
whose `last_seq` is ahead of what the registry knows, synthesises an
entry at seq=`last_seq` so the UI resurrects orphaned tool chips /
agent pills / approval modals without waiting for the next live
event.

## Architecture — three layers

```
               ┌───────────────────────────────┐
  Socket.IO ─► │   SessionEventRouter          │
               │                               │
               │   • snapshots  ─► SnapshotSinks
               │   • ephemerals ─► volatile stream
               │   • durables   ─► OpRegistry (strict parse)
               └───────────────────────────────┘
                           │
                           ▼
               ┌───────────────────────────────┐
               │       OpRegistry              │
               │                               │
               │   SplayTreeMap<int, Env>      │  ← seq-sorted (the fix)
               │   Map<opId, Env>              │  ← current state per op
               │   Set<eventId>                │  ← dedup (fanout)
               └───────────────────────────────┘
                           │
                           ▼
               ┌───────────────────────────────┐
               │   ChatLog widget              │
               │   tool chips, agent pills, …  │
               │                               │
               │   ⚠️ MUST read registry.inOrder()
               │      NOT a list in arrival order
               └───────────────────────────────┘
```

## The ordering bug (fixed)

Before this rollout the chat trusted wire arrival order. Three real
failure modes exposed the bug:

- **Reconnect replay** mixing with live events.
- **Room fanout** delivering the same event twice on two rooms.
- **ASGI pipeline asymmetry** — persistence + Socket.IO broadcast
  travel separate paths; a late `tool_start` could land after its
  own `tool_call`.

Fix: `SplayTreeMap<int, EventEnvelope>` keyed on `seq`. The chat
iterates the tree, so a seq=10 event inserted after seq=12 still
renders above it. Regression-locked by
[`test/services/op_registry_test.dart`](../test/services/op_registry_test.dart)
— specifically `ordering (the fix) inOrder returns events by seq
regardless of arrival order`.

## Adding a new event type

1. **Is it durable or ephemeral?** (daemon emits it to the
   `session_events` table = durable.) If ephemeral, add its `type`
   to `ephemeralEventTypes` in `event_envelope.dart` — the router
   will stream it on the volatile channel and the registry will
   refuse to ingest it.

2. **Does it belong to an op?** Every durable event must carry
   `op_id` / `op_type` / `op_state`. If you're adding a NEW op
   type, extend the `OpType` enum — `fromString` will throw on the
   old client until it's rebuilt, which is the intended failure
   mode (one coordinated daemon + client release).

3. **Does the UI need a chip / pill / modal?** Have the widget
   subscribe to `registry.latestFor(opId)` — it will update in
   place as events arrive, including reconciled ops from
   `active_ops:snapshot`.

4. **Test it.**
   - Unit test — inject envelopes out of order, verify
     `inOrder()` still seq-sorts.
   - Live test — add a scenario in
     `test/live/join_session_hydration_test.dart` against the real
     daemon.

## Anti-regression

[`test/services/event_contract_guards_test.dart`](../test/services/event_contract_guards_test.dart)
walks `lib/` and fails on:

- `payload['op_id']` / `payload['op_type']` / `payload['op_state']` /
  `payload['event_id']` with `?? ""` silent fallbacks.
- Any call to `OpRegistry.ingest` outside
  `SessionEventRouter` (which would bypass session filter +
  ephemeral rejection + dedup).
- Ephemeral type names (`thinking_delta`, `streaming_frame`, …)
  hardcoded in new durable paths (existing legacy call-sites are
  whitelisted during migration).

## Known gaps / not covered yet

- **Approval fanout live reproduction** — the router dedups on
  `event_id`, but we haven't run a live scenario where a
  `approval_request` actually fires on both the user-room and
  the session-room. The fix is in place defensively; validation
  waits for an app that gates a tool behind an approval.

- **Sub-agent op correlation** — scout didn't yet trigger an app
  that spawns sub-agents. `op_parent_id` handling in
  `reconcileActiveOps` is implemented but not exercised against
  a live nested-agent tree.

- **Migration of `chat_panel.dart`** — the legacy chat panel still
  processes `thinking_delta` / `out_token` / `message_done` via
  its own switch. Migrating it to consume `registry.inOrder()` +
  `router.ephemeralEvents` is the next PR. Until then the
  ephemeral-type whitelist in the anti-regression guard includes
  `chat_panel.dart`, `chat_panel_logic.dart`, `preview_store.dart`,
  `session_service.dart`, `socket_service.dart`, `api_client.dart`.

## File map

| Concern | File |
|---|---|
| Contract model + enums | `lib/models/event_envelope.dart` |
| Ordered store + reconciliation | `lib/services/op_registry.dart` |
| Routing policy | `lib/services/session_event_router.dart` |
| Typed snapshot sinks | `lib/services/session_snapshot_sinks.dart` |
| Unit tests (model) | `test/models/event_envelope_test.dart` |
| Unit tests (registry) | `test/services/op_registry_test.dart` |
| Unit tests (router) | `test/services/session_event_router_test.dart` |
| Anti-regression guard | `test/services/event_contract_guards_test.dart` |
| Live integration test | `test/live/join_session_hydration_test.dart` |
| Exploration script | `scout/explore_events.py` |

## Running the live tests

```bash
# default port 8000
flutter test test/live/join_session_hydration_test.dart

# custom daemon
flutter test test/live/join_session_hydration_test.dart \
  --dart-define=DIGITORN_BASE=http://some-host:9090
```

The suite skips cleanly if the daemon is unreachable — CI won't go
red because a dev ran `flutter test` without a backend up.
