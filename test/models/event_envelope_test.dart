/// Contract parity tests — anchored against a real daemon payload
/// captured by `scout/explore_events.py`.
library;

import 'package:digitorn_client/models/event_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _userMessageSample() => {
      // Top-level transport fields (scout-verified).
      'type': 'user_message',
      'kind': 'session',
      'seq': 1,
      'ts': '2026-04-20T18:29:28.510187Z',
      'session_id': 'explore-d-d8750689',
      'payload': {
        // Contract fields live here in the canonical shape.
        'event_id': 'ev-a1b2c3d4e5f6',
        'op_id': 'fp-c0ff2bd99e46',
        'op_type': 'turn',
        'op_state': 'running',
        'correlation_id': 'fp-c0ff2bd99e46',
        'session_id': 'explore-d-d8750689',
        // Type-specific.
        'content': 'hi',
        'role': 'user',
        'client_message_id': 'ck-123',
        'pending': false,
      },
    };

void main() {
  group('EventEnvelope.fromJson', () {
    test('parses the daemon payload-first shape (scout sample)', () {
      final e = EventEnvelope.fromJson(_userMessageSample());
      expect(e.type, 'user_message');
      expect(e.kind, 'session');
      expect(e.seq, 1);
      expect(e.sessionId, 'explore-d-d8750689');
      expect(e.eventId, 'ev-a1b2c3d4e5f6');
      expect(e.opId, 'fp-c0ff2bd99e46');
      expect(e.opType, OpType.turn);
      expect(e.opState, OpState.running);
      expect(e.correlationId, 'fp-c0ff2bd99e46');
      expect(e.opParentId, isNull);
      expect(e.payload['content'], 'hi');
      expect(e.isTerminal, isFalse);
      expect(e.isEphemeral, isFalse);
      expect(e.isSnapshot, isFalse);
    });

    test('accepts contract fields at top level (future-proof)', () {
      final raw = {
        'type': 'tool_start',
        'kind': 'session',
        'seq': 42,
        'ts': '2026-04-20T18:29:28.510187Z',
        'session_id': 'sid-1',
        'event_id': 'ev-TOP',
        'op_id': 'op-tool-xxx',
        'op_type': 'tool',
        'op_state': 'running',
        'correlation_id': 'fp-abc',
        'payload': {
          'tool_name': 'workspace.write',
        },
      };
      final e = EventEnvelope.fromJson(raw);
      expect(e.eventId, 'ev-TOP');
      expect(e.opType, OpType.tool);
    });

    test('payload wins over top-level on shared keys (canonical)', () {
      final raw = _userMessageSample();
      // Put a stale value at top level; payload should still win.
      raw['event_id'] = 'ev-STALE-TOPLEVEL';
      final e = EventEnvelope.fromJson(raw);
      expect(e.eventId, 'ev-a1b2c3d4e5f6');
    });

    test('throws ContractError on missing event_id', () {
      final raw = _userMessageSample();
      (raw['payload'] as Map).remove('event_id');
      expect(() => EventEnvelope.fromJson(raw),
          throwsA(isA<ContractError>()));
    });

    test('throws ContractError on missing op_id', () {
      final raw = _userMessageSample();
      (raw['payload'] as Map).remove('op_id');
      expect(() => EventEnvelope.fromJson(raw),
          throwsA(isA<ContractError>()));
    });

    test('throws ContractError on missing op_state', () {
      final raw = _userMessageSample();
      (raw['payload'] as Map).remove('op_state');
      expect(() => EventEnvelope.fromJson(raw),
          throwsA(isA<ContractError>()));
    });

    test('throws ContractError on unknown op_type', () {
      final raw = _userMessageSample();
      (raw['payload'] as Map)['op_type'] = 'alien';
      expect(() => EventEnvelope.fromJson(raw),
          throwsA(isA<ContractError>()));
    });

    test('throws ContractError on unknown op_state', () {
      final raw = _userMessageSample();
      (raw['payload'] as Map)['op_state'] = 'exploded';
      expect(() => EventEnvelope.fromJson(raw),
          throwsA(isA<ContractError>()));
    });

    test('throws ContractError on missing seq', () {
      final raw = _userMessageSample();
      raw.remove('seq');
      expect(() => EventEnvelope.fromJson(raw),
          throwsA(isA<ContractError>()));
    });

    test('throws on unparseable ts', () {
      final raw = _userMessageSample();
      raw['ts'] = 'not-a-timestamp';
      expect(() => EventEnvelope.fromJson(raw),
          throwsA(isA<ContractError>()));
    });

    test('correlation_id MAY be null (system events)', () {
      final raw = _userMessageSample();
      (raw['payload'] as Map).remove('correlation_id');
      final e = EventEnvelope.fromJson(raw);
      expect(e.correlationId, isNull);
    });

    test('reads op_parent_id when daemon ships it', () {
      final raw = _userMessageSample();
      (raw['payload'] as Map)['op_parent_id'] = 'parent-agent-xxx';
      final e = EventEnvelope.fromJson(raw);
      expect(e.opParentId, 'parent-agent-xxx');
    });
  });

  group('EventEnvelope.tryFromJson (routing at the socket boundary)',
      () {
    test('returns null for ephemeral types', () {
      for (final t in ephemeralEventTypes) {
        expect(
          EventEnvelope.tryFromJson({'type': t, 'payload': {}}),
          isNull,
          reason: 'ephemeral $t must not produce an envelope',
        );
      }
    });

    test('returns null for snapshot types', () {
      for (final t in snapshotEventTypes) {
        expect(
          EventEnvelope.tryFromJson({'type': t, 'payload': {}}),
          isNull,
          reason: 'snapshot $t must not produce an envelope',
        );
      }
    });

    test('returns null for malformed envelopes (swallowed by route)',
        () {
      final bad = _userMessageSample();
      (bad['payload'] as Map).remove('op_id');
      expect(EventEnvelope.tryFromJson(bad), isNull);
    });

    test('returns a valid envelope for well-formed durable events',
        () {
      expect(EventEnvelope.tryFromJson(_userMessageSample()),
          isA<EventEnvelope>());
    });
  });

  group('OpState.isTerminal', () {
    test('completed/failed/cancelled/timeout are terminal', () {
      expect(OpState.completed.isTerminal, isTrue);
      expect(OpState.failed.isTerminal, isTrue);
      expect(OpState.cancelled.isTerminal, isTrue);
      expect(OpState.timeout.isTerminal, isTrue);
    });
    test('pending/running/waitingApproval are non-terminal', () {
      expect(OpState.pending.isTerminal, isFalse);
      expect(OpState.running.isTerminal, isFalse);
      expect(OpState.waitingApproval.isTerminal, isFalse);
    });
  });

  group('OpState.fromString', () {
    test('parses every known value', () {
      expect(OpState.fromString('pending'), OpState.pending);
      expect(OpState.fromString('running'), OpState.running);
      expect(OpState.fromString('waiting_approval'),
          OpState.waitingApproval);
      expect(OpState.fromString('completed'), OpState.completed);
      expect(OpState.fromString('failed'), OpState.failed);
      expect(OpState.fromString('cancelled'), OpState.cancelled);
      expect(OpState.fromString('timeout'), OpState.timeout);
    });
    test('rejects unknown values', () {
      expect(() => OpState.fromString('running_maybe'),
          throwsA(isA<ContractError>()));
    });
  });
}
