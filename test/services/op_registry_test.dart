/// OpRegistry — unit tests covering the ordering fix, dedup, and
/// active_ops reconciliation. Scout-derived shapes only; no mocks.
library;

import 'package:digitorn_client/models/event_envelope.dart';
import 'package:digitorn_client/services/op_registry.dart';
import 'package:flutter_test/flutter_test.dart';

EventEnvelope _ev({
  required int seq,
  required String opId,
  OpType opType = OpType.tool,
  OpState opState = OpState.running,
  String type = 'tool_start',
  String? eventId,
  String sessionId = 'S',
  String? correlationId,
}) {
  return EventEnvelope(
    eventId: eventId ?? 'ev-$opId-$seq',
    type: type,
    kind: 'session',
    seq: seq,
    ts: DateTime.utc(2026, 4, 20, 12, 0, seq),
    appId: 'A',
    sessionId: sessionId,
    userId: 'U',
    correlationId: correlationId ?? 'cid-$opId',
    opId: opId,
    opType: opType,
    opState: opState,
    opParentId: null,
    payload: const {},
  );
}

void main() {
  late OpRegistry reg;

  setUp(() {
    reg = OpRegistry(sessionId: 'S');
  });

  group('ordering (the fix)', () {
    test(
        'inOrder returns events by seq regardless of arrival order '
        '(core bug repro)', () {
      // Arrival order: 5, 3, 7, 4, 1 — simulating a reconnect where
      // replay events interleave with live events. The fix is to
      // sort by seq, never by arrival.
      final arrivals = [5, 3, 7, 4, 1]
          .map((s) => _ev(seq: s, opId: 'op-$s'))
          .toList();
      for (final e in arrivals) {
        reg.ingest(e);
      }
      expect(reg.inOrder().map((e) => e.seq).toList(),
          [1, 3, 4, 5, 7]);
    });

    test(
        'late tool_call updates existing chip without creating a '
        'duplicate', () {
      // tool_start at seq=10, then tool_call at seq=12 (completed).
      // latestFor(opId) must return the completed state; the chat
      // iteration must still show both in order.
      reg.ingest(_ev(
        seq: 10,
        opId: 'op-tool-X',
        type: 'tool_start',
        opState: OpState.running,
      ));
      reg.ingest(_ev(
        seq: 12,
        opId: 'op-tool-X',
        type: 'tool_call',
        opState: OpState.completed,
      ));
      final latest = reg.latestFor('op-tool-X')!;
      expect(latest.opState, OpState.completed,
          reason: 'the op chip must reflect the terminal state.');
      expect(reg.inOrder(), hasLength(2),
          reason: 'both events must be visible in the chat feed.');
    });

    test('out-of-order completion still flips the op to terminal', () {
      // tool_call at seq=8 arrives BEFORE tool_start at seq=5 (wire
      // reordering). latestFor must still be the seq=8 / completed
      // event because 8 > 5.
      reg.ingest(_ev(
        seq: 8,
        opId: 'op-tool-Y',
        type: 'tool_call',
        opState: OpState.completed,
      ));
      reg.ingest(_ev(
        seq: 5,
        opId: 'op-tool-Y',
        type: 'tool_start',
        opState: OpState.running,
      ));
      expect(reg.latestFor('op-tool-Y')!.opState, OpState.completed);
    });
  });

  group('dedup', () {
    test('same event_id delivered twice is absorbed (room fanout)',
        () {
      final e1 = _ev(seq: 5, opId: 'op-A', eventId: 'ev-approval');
      // Simulated fanout: same event, same event_id, potentially
      // different seqs would still collapse. Even with identical
      // seqs the dedup works on event_id.
      reg.ingest(e1);
      final duplicate = _ev(seq: 5, opId: 'op-A', eventId: 'ev-approval');
      final was = reg.ingest(duplicate);
      expect(was, isFalse, reason: 'dedup must reject the copy.');
      expect(reg.length, 1);
    });

    test('different event_id but same seq: first wins, second logged',
        () {
      // Rare — would indicate a daemon restart / seq reset; we keep
      // the first insert to preserve the existing UI.
      reg.ingest(_ev(seq: 5, opId: 'op-A', eventId: 'ev-FIRST'));
      final was = reg.ingest(
          _ev(seq: 5, opId: 'op-A', eventId: 'ev-SECOND'));
      expect(was, isFalse);
      expect(reg.inOrder().single.eventId, 'ev-FIRST');
    });
  });

  group('session filter', () {
    test('events from another session are dropped silently', () {
      final other = _ev(seq: 42, opId: 'op-other', sessionId: 'OTHER');
      final stored = reg.ingest(other);
      expect(stored, isFalse);
      expect(reg.length, 0);
    });

    test('events with empty sessionId still ingest (legacy envelope)',
        () {
      final legacy = _ev(seq: 1, opId: 'op-L')
        ..sessionId;
      // Re-forge with empty sessionId to mimic a pre-contract event.
      final legacyMut = EventEnvelope(
        eventId: legacy.eventId,
        type: legacy.type,
        kind: legacy.kind,
        seq: legacy.seq,
        ts: legacy.ts,
        appId: legacy.appId,
        sessionId: '',
        userId: legacy.userId,
        correlationId: legacy.correlationId,
        opId: legacy.opId,
        opType: legacy.opType,
        opState: legacy.opState,
        opParentId: legacy.opParentId,
        payload: legacy.payload,
      );
      expect(reg.ingest(legacyMut), isTrue);
    });
  });

  group('ephemeral rejection', () {
    test(
        'ingesting an ephemeral type throws '
        'EphemeralInRegistryError', () {
      // Craft an ephemeral-typed envelope via the constructor so we
      // can verify the registry blocks it even when the caller
      // bypasses tryFromJson.
      final bad = EventEnvelope(
        eventId: 'ev-x', type: 'token', kind: 'session', seq: 1,
        ts: DateTime.utc(2026), appId: 'A', sessionId: 'S',
        userId: 'U', correlationId: null, opId: 'op-x',
        opType: OpType.turn, opState: OpState.running,
        opParentId: null, payload: const {},
      );
      expect(() => reg.ingest(bad),
          throwsA(isA<EphemeralInRegistryError>()));
    });
  });

  group('activeOps', () {
    test('returns only non-terminal ops, _system excluded by default',
        () {
      reg.ingest(_ev(
        seq: 1, opId: 'op-turn', opType: OpType.turn,
        opState: OpState.running,
      ));
      reg.ingest(_ev(
        seq: 2, opId: 'op-done', opType: OpType.tool,
        opState: OpState.completed,
      ));
      reg.ingest(_ev(
        seq: 3, opId: '_system', opType: OpType.system,
        opState: OpState.running,
      ));
      expect(
          reg.activeOps().map((e) => e.opId).toSet(), {'op-turn'});
      expect(
          reg.activeOps(includeSystem: true)
              .map((e) => e.opId)
              .toSet(),
          {'op-turn', '_system'});
    });
  });

  group('reconcileActiveOps', () {
    test(
        'injects a synthetic envelope for ops the registry missed '
        'during a disconnect', () {
      // Registry was empty during the dropout — snapshot now
      // reports a running tool at seq=42. The reconciler synthesises
      // an entry so the UI can show it.
      reg.reconcileActiveOps([
        {
          'op_id': 'op-ghost-tool',
          'op_type': 'tool',
          'op_state': 'running',
          'last_seq': 42,
          'last_ts': '2026-04-20T12:00:42Z',
          'last_type': 'tool_start',
          'correlation_id': 'fp-ghost',
          'first_seq': 40,
        },
      ]);
      final latest = reg.latestFor('op-ghost-tool');
      expect(latest, isNotNull);
      expect(latest!.opState, OpState.running);
      expect(latest.seq, 42);
      expect(latest.payload['_reconciled'], isTrue);
      expect(latest.payload['source'], 'active_ops:snapshot');
      // The chat ordering surfaces the synthetic event in place.
      expect(reg.inOrder().map((e) => e.seq), contains(42));
    });

    test(
        'does NOT overwrite when the registry already has a more '
        'recent event', () {
      reg.ingest(_ev(
        seq: 50, opId: 'op-live',
        opState: OpState.completed,
        type: 'tool_call',
      ));
      reg.reconcileActiveOps([
        {
          'op_id': 'op-live',
          'op_type': 'tool',
          'op_state': 'running',
          'last_seq': 42, // older than what we have
        },
      ]);
      expect(reg.latestFor('op-live')!.opState, OpState.completed,
          reason: 'stale snapshot must not clobber a fresher local '
              'event.');
    });

    test('ignores snapshot entries with unknown op_type / op_state',
        () {
      reg.reconcileActiveOps([
        {
          'op_id': 'op-bad',
          'op_type': 'alien', // unknown — must not crash
          'op_state': 'running',
          'last_seq': 7,
        },
      ]);
      expect(reg.latestFor('op-bad'), isNull);
    });

    test(
        'real tool_start later overrides the synthetic reconciled '
        'entry', () {
      reg.reconcileActiveOps([
        {
          'op_id': 'op-T',
          'op_type': 'tool',
          'op_state': 'running',
          'last_seq': 10,
          'last_type': 'tool_start',
        },
      ]);
      // Live event for the same op with a later seq.
      reg.ingest(_ev(
        seq: 14, opId: 'op-T', opType: OpType.tool,
        opState: OpState.completed, type: 'tool_call',
      ));
      expect(reg.latestFor('op-T')!.opState, OpState.completed);
      expect(reg.latestFor('op-T')!.seq, 14);
    });
  });

  group('maxSeq + reset', () {
    test('maxSeq reflects the largest seq ingested', () {
      expect(reg.maxSeq, 0);
      reg.ingest(_ev(seq: 3, opId: 'a'));
      reg.ingest(_ev(seq: 8, opId: 'b'));
      reg.ingest(_ev(seq: 5, opId: 'c'));
      expect(reg.maxSeq, 8);
    });

    test('reset clears the indices and notifies listeners', () {
      reg.ingest(_ev(seq: 1, opId: 'x'));
      var notified = 0;
      reg.addListener(() => notified++);
      reg.reset();
      expect(reg.length, 0);
      expect(reg.maxSeq, 0);
      expect(notified, 1);
    });
  });
}
