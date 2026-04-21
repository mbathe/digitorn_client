import 'package:flutter_test/flutter_test.dart';
import 'package:digitorn_client/services/preview_store.dart';
import 'package:digitorn_client/services/workspace_module.dart';

// WorkspaceModule is populated entirely from PreviewStore delta
// events. These tests verify that:
//   • files appear via preview:resource_set on the `files` channel
//   • diagnostics appear via preview:resource_set on `diagnostics`
//   • the module notifies listeners (drives UI rebuilds)
//   • reset() clears everything

void _injectEvent(String type, Map<String, dynamic> payload) {
  PreviewStore().applyHistoryEvent(type, payload);
}

Future<void> _settleModule() async {
  // WorkspaceModule defers rebuilds to a microtask to avoid
  // notifying listeners mid-frame. Tests must pump a microtask
  // before asserting.
  await Future<void>.delayed(Duration.zero);
}

void main() {
  late WorkspaceModule mod;

  setUp(() {
    PreviewStore().reset();
    mod = WorkspaceModule();
    mod.reset();
  });

  tearDown(() {
    mod.reset();
    PreviewStore().reset();
  });

  group('files', () {
    test('resource_set populates files', () async {
      _injectEvent('preview:resource_set', {
        'channel': 'files',
        'id': 'src/main.py',
        'payload': {
          'content': 'print("hello")',
          'language': 'python',
          'lines': 1,
          'status': 'added',
        },
      });
      await _settleModule();

      expect(mod.hasFiles, true);
      expect(mod.files.containsKey('src/main.py'), true);
      expect(mod.files['src/main.py']!.content, 'print("hello")');
      expect(mod.files['src/main.py']!.language, 'python');
    });

    test('resource_deleted removes files', () async {
      _injectEvent('preview:resource_set', {
        'channel': 'files',
        'id': 'a.py',
        'payload': {'content': 'a'},
      });
      _injectEvent('preview:resource_set', {
        'channel': 'files',
        'id': 'b.py',
        'payload': {'content': 'b'},
      });
      await _settleModule();
      expect(mod.files.length, 2);

      _injectEvent('preview:resource_deleted', {
        'channel': 'files',
        'id': 'a.py',
      });
      await _settleModule();

      expect(mod.files.length, 1);
      expect(mod.files.containsKey('b.py'), true);
    });

    test('notifies listeners on file change', () async {
      var notified = 0;
      mod.addListener(() => notified++);
      _injectEvent('preview:resource_set', {
        'channel': 'files',
        'id': 'src/main.py',
        'payload': {'content': 'x'},
      });
      await _settleModule();
      expect(notified, greaterThan(0));
    });

    test('reset clears files, diagnostics, reveal', () async {
      _injectEvent('preview:resource_set', {
        'channel': 'files',
        'id': 'a.py',
        'payload': {'content': 'a'},
      });
      await _settleModule();
      expect(mod.hasFiles, true);

      mod.reset();

      expect(mod.hasFiles, false);
      expect(mod.files, isEmpty);
      expect(mod.diagnostics, isEmpty);
    });

    test('snapshot hydrates files in one shot', () async {
      PreviewStore().applySnapshot({
        'state': {},
        'resources': {
          'files': {
            'a.py': {'content': 'a'},
            'b.py': {'content': 'b'},
          },
        },
      });
      await _settleModule();

      expect(mod.files.length, 2);
      expect(mod.files['a.py']!.content, 'a');
      expect(mod.files['b.py']!.content, 'b');
    });
  });

  group('diagnostics', () {
    test('resource_set populates diagnostics per path', () async {
      _injectEvent('preview:resource_set', {
        'channel': 'diagnostics',
        'id': 'src/app.ts',
        'payload': {
          'items': [
            {
              'severity': 'error',
              'message': 'Cannot find name',
              'range': {
                'start': {'line': 3, 'character': 4},
                'end': {'line': 3, 'character': 7},
              },
              'source': 'ts',
            },
          ],
          'generation': 1,
          'severity_max': 'error',
        },
      });
      await _settleModule();

      expect(mod.diagnostics.containsKey('src/app.ts'), true);
      expect(mod.diagnostics['src/app.ts']!.items.length, 1);
      expect(mod.totalErrors, 1);
      expect(mod.filesWithErrors, 1);
    });

    test('generation guard rejects stale payloads', () async {
      _injectEvent('preview:resource_set', {
        'channel': 'diagnostics',
        'id': 'app.ts',
        'payload': {
          'items': [
            {'severity': 'error', 'message': 'new', 'range': {}}
          ],
          'generation': 5,
        },
      });
      await _settleModule();
      expect(mod.diagnostics['app.ts']!.generation, 5);

      // Stale replay arrives after.
      _injectEvent('preview:resource_set', {
        'channel': 'diagnostics',
        'id': 'app.ts',
        'payload': {
          'items': [],
          'generation': 2,
        },
      });
      await _settleModule();

      // Should keep the newer generation.
      expect(mod.diagnostics['app.ts']!.generation, 5);
      expect(mod.diagnostics['app.ts']!.items.length, 1);
    });

    test('resource_deleted removes the entry', () async {
      _injectEvent('preview:resource_set', {
        'channel': 'diagnostics',
        'id': 'app.ts',
        'payload': {
          'items': [
            {'severity': 'error', 'message': 'x', 'range': {}}
          ],
          'generation': 1,
        },
      });
      await _settleModule();
      expect(mod.diagnostics.isNotEmpty, true);

      _injectEvent('preview:resource_deleted', {
        'channel': 'diagnostics',
        'id': 'app.ts',
      });
      await _settleModule();
      expect(mod.diagnostics, isEmpty);
    });
  });

  group('revealAt', () {
    test('bumps request counter and sets coordinates', () {
      final start = mod.revealRequest;
      mod.revealAt('src/app.ts', 42, column: 4);
      expect(mod.revealRequest, start + 1);
      expect(mod.revealPath, 'src/app.ts');
      expect(mod.revealLine, 42);
      expect(mod.revealColumn, 4);
    });

    test('selects the target file automatically', () {
      mod.revealAt('src/other.ts', 10);
      expect(mod.selectedPath, 'src/other.ts');
    });
  });

  // Regression lock for the "+N -M on file names only reflects the
  // last edit" bug. Scout-verified contract (daemon-side):
  //   insertions_pending / deletions_pending are delta-vs-baseline
  //   and aggregate EVERY write since the last approve.
  // The previous client impl parsed `unified_diff` (per-op) as a
  // shortcut, which hid the aggregate. Fix: trust the daemon's
  // numbers.
  group('pending counter aggregation (BUG #1 fix)', () {
    test('uses daemon insertions_pending, not per-op unified_diff',
        () async {
      // Simulate the exact shape daemon ships after 3 consecutive
      // writes vs baseline (scout ran: write#3 → ins=3 del=3 while
      // unified_diff shows only THE LAST write = 1 added + 1 removed).
      _injectEvent('preview:resource_set', {
        'channel': 'files',
        'id': 'agg.txt',
        'payload': {
          'content': 'one\nONE\nTHREE\nFOUR\n',
          'lines': 4,
          'status': 'modified',
          'operation': 'edit',
          'validation': 'pending',
          // Cumulative delta vs baseline (daemon BUG #1 fix)
          'insertions_pending': 3,
          'deletions_pending': 3,
          // Per-op diff from the LAST write only — DON'T use this
          // for the gutter badge. 1 added + 1 removed would mislead.
          'unified_diff': '--- a/agg.txt\n+++ b/agg.txt\n'
              '@@ -4,1 +4,1 @@\n-four\n+FOUR\n',
          // Pending diff IS vs-baseline — also correct.
          'unified_diff_pending': '--- a/agg.txt\n+++ b/agg.txt\n'
              '@@ -1,4 +1,4 @@\n one\n-two\n-three\n-four\n'
              '+ONE\n+THREE\n+FOUR\n',
        },
      });
      await _settleModule();

      final f = mod.files['agg.txt']!;
      expect(f.pendingInsertionsEffective, 3,
          reason: 'Must mirror daemon insertions_pending aggregate, '
              'not the 1 from per-op unified_diff.');
      expect(f.pendingDeletionsEffective, 3,
          reason: 'Must mirror daemon deletions_pending aggregate.');
      expect(f.hasPendingChanges, isTrue);
      expect(f.pendingSummary, '+3 -3');
    });

    test('approve resets pending counters to 0', () async {
      _injectEvent('preview:resource_set', {
        'channel': 'files',
        'id': 'x.txt',
        'payload': {
          'content': 'a',
          'validation': 'approved',
          'insertions_pending': 0,
          'deletions_pending': 0,
          'total_insertions': 5,
          'total_deletions': 2,
        },
      });
      await _settleModule();
      final f = mod.files['x.txt']!;
      expect(f.pendingInsertionsEffective, 0);
      expect(f.pendingDeletionsEffective, 0);
      expect(f.hasPendingChanges, isFalse);
      // Session-level totals are unaffected — they're a separate
      // counter that never resets on approve.
      expect(f.totalInsertions, 5);
      expect(f.totalDeletions, 2);
    });

    test('approve clears pending — listeners fire even though '
        'content bytes are unchanged (change-detection bug fix)',
        () async {
      // Seed a pending file.
      _injectEvent('preview:resource_set', {
        'channel': 'files',
        'id': 'live.txt',
        'payload': {
          'content': 'hi',
          'validation': 'pending',
          'insertions_pending': 2,
          'deletions_pending': 0,
          'updated_at': 1000.0,
        },
      });
      await _settleModule();
      expect(mod.files['live.txt']!.insertionsPending, 2);

      // Agent writes again — same content, but validation flips to
      // approved and pending counters clear. The previous bug: the
      // module compared only `content`, decided nothing changed,
      // skipped notify — gutter stayed frozen at +2 / -0.
      var notifies = 0;
      void bump() => notifies++;
      mod.addListener(bump);
      _injectEvent('preview:resource_set', {
        'channel': 'files',
        'id': 'live.txt',
        'payload': {
          'content': 'hi', // unchanged bytes
          'validation': 'approved',
          'insertions_pending': 0,
          'deletions_pending': 0,
          'updated_at': 1001.0, // fresh write bump
        },
      });
      await _settleModule();
      mod.removeListener(bump);

      expect(notifies, greaterThan(0),
          reason: 'Signature-diff MUST fire a notify so explorer '
              'gutter, Changes panel, and Monaco rebuild.');
      expect(mod.files['live.txt']!.insertionsPending, 0);
      expect(mod.files['live.txt']!.validation, 'approved');
    });

    test('aggregate diff growth refreshes listeners even when the '
        'buffer content coincidentally matches', () async {
      // Edge case from the aggregation scout: the user edits a file
      // back to its pre-last-write state (content unchanged vs our
      // cached copy) but the aggregate vs-baseline pending diff
      // keeps growing. Without the fix the UI would show a stale
      // "1 hunk" badge while the real pending was 3 hunks.
      _injectEvent('preview:resource_set', {
        'channel': 'files',
        'id': 'agg.txt',
        'payload': {
          'content': 'same',
          'validation': 'pending',
          'insertions_pending': 1,
          'deletions_pending': 1,
          'unified_diff_pending': '@@ -1,1 +1,1 @@\n-old\n+same\n',
        },
      });
      await _settleModule();

      var notifies = 0;
      void bump() => notifies++;
      mod.addListener(bump);
      _injectEvent('preview:resource_set', {
        'channel': 'files',
        'id': 'agg.txt',
        'payload': {
          'content': 'same', // exact same bytes
          'validation': 'pending',
          'insertions_pending': 3,
          'deletions_pending': 3,
          'unified_diff_pending':
              '@@ -1,4 +1,4 @@\n-a\n-b\n-c\n+A\n+B\n+C\n same\n',
        },
      });
      await _settleModule();
      mod.removeListener(bump);

      expect(notifies, greaterThan(0));
      expect(mod.files['agg.txt']!.insertionsPending, 3);
      expect(mod.files['agg.txt']!.deletionsPending, 3);
      expect(mod.files['agg.txt']!.unifiedDiffPending!.contains('+C'),
          isTrue);
    });

    test('defensive fallback to parsing unified_diff_pending when '
        'daemon ships 0/0 alongside a non-empty pending diff', () async {
      // Real payloads never do this, but a misconfigured daemon
      // release could. We parse the pending diff (NOT the per-op
      // one) so the badge still matches the diff the user sees.
      _injectEvent('preview:resource_set', {
        'channel': 'files',
        'id': 'fallback.txt',
        'payload': {
          'content': 'x',
          'validation': 'pending',
          'insertions_pending': 0,
          'deletions_pending': 0,
          'unified_diff_pending':
              '@@ -1,1 +1,2 @@\n a\n+b\n+c\n-removed\n',
        },
      });
      await _settleModule();
      final f = mod.files['fallback.txt']!;
      expect(f.pendingInsertionsEffective, 2);
      expect(f.pendingDeletionsEffective, 1);
    });
  });
}
