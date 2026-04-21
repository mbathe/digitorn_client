/// Anti-regression guards for the universal event contract.
///
/// These tests walk the actual `lib/` source code and fail the build
/// when a forbidden pattern slips in:
///
///   * Contract fields (`event_id`, `op_id`, `op_type`, `op_state`)
///     read with a silent fallback (`?? ''`, `?? 'system'`, …).
///     A missing field must surface as [ContractError], never as a
///     degraded event.
///
///   * Any call to `OpRegistry.ingest(...)` outside of
///     [SessionEventRouter] — the router is the single point of
///     policy (session filter, ephemeral rejection, event_id
///     dedup). Direct ingest bypasses those checks.
///
///   * Ephemeral event types hard-coded in durable paths — e.g. a
///     `switch(type) { case 'token': ... }` that writes to a
///     chat_messages store. Detected via a targeted grep.
///
/// Runtime invariants are ALSO covered by [OpRegistry] itself
/// ([EphemeralInRegistryError], [ContractError] from
/// [EventEnvelope.fromJson]). These tests are the compile-time
/// side — they catch misuse before it ever reaches a binary.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Iterable<File> _dartFilesUnder(String dir) sync* {
  final d = Directory(dir);
  if (!d.existsSync()) return;
  for (final entity in d.listSync(recursive: true, followLinks: false)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      yield entity;
    }
  }
}

/// Contract field names whose absence must crash, not default to
/// something silently. Any line that combines one of these names
/// with `?? '` or `?? "` is flagged.
const _contractFieldNames = [
  'event_id',
  'op_id',
  'op_type',
  'op_state',
];

void main() {
  group('universal event contract guards', () {
    test(
        'no silent default on contract fields — a missing value must '
        'throw ContractError, never degrade to ""', () {
      final offenders = <String>[];
      final rx = RegExp(
        r'''\[\s*['"](event_id|op_id|op_type|op_state)['"]\s*\][^\n]*\?\?\s*['"]''',
      );
      for (final f in _dartFilesUnder('lib')) {
        // The model itself uses explicit null handling — whitelist.
        if (f.path.endsWith('event_envelope.dart')) continue;
        final text = f.readAsStringSync();
        for (final (i, line) in text.split('\n').indexed) {
          if (rx.hasMatch(line)) {
            offenders.add('${f.path}:${i + 1}  $line');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            "Contract fields (${_contractFieldNames.join(', ')}) must "
            "fail loudly when missing. Use the typed EventEnvelope "
            "accessors — don't read the raw map with '?? \"\"'.",
      );
    });

    test(
        'OpRegistry.ingest is only called from SessionEventRouter + '
        'tests — anything else bypasses the routing policy', () {
      final rx = RegExp(r'\b\w*[Rr]egistry\.ingest\s*\(');
      final offenders = <String>[];
      for (final f in _dartFilesUnder('lib')) {
        if (f.path.endsWith('session_event_router.dart')) continue;
        if (f.path.endsWith('op_registry.dart')) continue;
        final text = f.readAsStringSync();
        for (final (i, line) in text.split('\n').indexed) {
          if (rx.hasMatch(line)) {
            offenders.add('${f.path}:${i + 1}  ${line.trim()}');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'Production code must route durable events through '
            'SessionEventRouter.dispatch() — direct OpRegistry.ingest '
            'calls skip the session filter, ephemeral rejection and '
            'event_id dedup. Offenders:\n${offenders.join('\n')}',
      );
    });

    test(
        'no ephemeral type name is hardcoded in durable event '
        'switches (a sign of misrouting)', () {
      // We look for the suspicious combination: a `case 'token':` (or
      // similar) in the same file that calls into a MODEL / STATE
      // service — e.g. ChatMessage.appendText, OpRegistry.ingest.
      // The clean pattern is to dispatch through the router.
      final ephemerals = [
        'thinking_delta',
        'streaming_frame',
        'preview:delta',
        'agent_progress',
        'assistant_stream_snapshot',
      ];
      final offenders = <String>[];
      for (final f in _dartFilesUnder('lib')) {
        if (f.path.endsWith('event_envelope.dart')) continue;
        if (f.path.endsWith('session_event_router.dart')) continue;
        if (f.path.endsWith('op_registry.dart')) continue;
        final text = f.readAsStringSync();
        for (final eph in ephemerals) {
          // A bare string literal of an ephemeral event name deep
          // in a service file is the suspect pattern.
          if (RegExp(r"['\x22]" +
                  RegExp.escape(eph) +
                  r"['\x22]")
              .hasMatch(text)) {
            // Whitelist legitimate references (legacy chat panel
            // handles them via the streaming buffer — not ideal
            // but that migration is staged separately).
            if (f.path.endsWith('chat_panel.dart') ||
                f.path.endsWith('chat_panel_logic.dart') ||
                f.path.endsWith('preview_store.dart') ||
                f.path.endsWith('session_service.dart') ||
                f.path.endsWith('socket_service.dart') ||
                // Legacy streaming-handler path — still decodes
                // per-type deltas for the live ticker. Migration
                // to the router is staged; the whitelist will be
                // trimmed down as call-sites switch over.
                f.path.endsWith('api_client.dart')) {
              continue;
            }
            offenders.add('${f.path} references ephemeral "$eph"');
          }
        }
      }
      expect(offenders, isEmpty);
    });
  });
}
