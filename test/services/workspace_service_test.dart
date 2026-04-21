import 'package:flutter_test/flutter_test.dart';
import 'package:digitorn_client/services/preview_store.dart';
import 'package:digitorn_client/services/workspace_module.dart';
import 'package:digitorn_client/services/workspace_service.dart';

void main() {
  late WorkspaceService ws;

  setUp(() {
    ws = WorkspaceService();
    ws.clearAll();
  });

  group('WorkspaceService (façade)', () {
    test('clearAll resets terminal, diagnostics, git, active', () {
      ws.handleEvent('terminal_output', {
        'command': 'ls',
        'output': 'file1\nfile2',
        'exit_code': 0,
      });
      ws.setActiveBuffer('/some/path');

      ws.clearAll();

      expect(ws.terminal, isEmpty);
      expect(ws.diagnostics, isEmpty);
      expect(ws.gitStatus, isNull);
      expect(ws.activeBufferPath, isNull);
    });

    test('handleEvent ignores unknown types', () {
      // Post-consolidation the service only handles terminal_output +
      // diagnostics. Anything else (including legacy workbench_*)
      // must be a silent no-op.
      ws.handleEvent('workbench_read', {'buffer': '/x', 'content': 'x'});
      ws.handleEvent('workbench_write', {'buffer': '/x', 'content': 'x'});
      ws.handleEvent('unknown', {});
      expect(ws.terminal, isEmpty);
      expect(ws.diagnostics, isEmpty);
    });
  });

  group('WorkbenchBuffer', () {
    test('filename extracts from path', () {
      const buf = WorkbenchBuffer(
        path: '/home/user/project/src/main.py',
        type: 'code',
        content: '',
        lines: 0,
        chars: 0,
      );
      expect(buf.filename, 'main.py');
      expect(buf.extension, 'py');
    });

    test('directory extracts from path', () {
      const buf = WorkbenchBuffer(
        path: '/home/user/project/src/main.py',
        type: 'code',
        content: '',
        lines: 0,
        chars: 0,
      );
      expect(buf.directory, '/home/user/project/src');
    });

    test('diffStats returns cumulative counters', () {
      const buf = WorkbenchBuffer(
        path: '/test.py',
        type: 'code',
        content: 'x',
        lines: 1,
        chars: 1,
        isEdited: true,
        insertions: 5,
        deletions: 2,
      );
      expect(buf.diffStats.insertions, 5);
      expect(buf.diffStats.deletions, 2);
    });

    test('diffStats zero by default', () {
      const buf = WorkbenchBuffer(
        path: '/test.py',
        type: 'code',
        content: 'x',
        lines: 1,
        chars: 1,
      );
      expect(buf.diffStats.insertions, 0);
      expect(buf.diffStats.deletions, 0);
    });

    test(
        'projected buffer carries aggregated pending counters + '
        'unified_diff_pending (ChangesPanel data source)', () async {
      // Regression lock — the previous projection passed
      // previousContent:'' and insertions: totalInsertions, which
      // made the Changes panel render the whole file as "added"
      // and show session-cumulative counts in the header.
      // Fix: project pendingInsertionsEffective / pendingDeletions
      // Effective / unifiedDiffPending so the panel can render the
      // aggregated diff vs the last approved baseline.
      PreviewStore().reset();
      WorkspaceModule().reset();
      PreviewStore().applyHistoryEvent('preview:resource_set', {
        'channel': 'files',
        'id': 'agg.txt',
        'payload': {
          'content': 'one\nONE\nTHREE\nFOUR\n',
          'lines': 4,
          'status': 'modified',
          'validation': 'pending',
          'insertions_pending': 3,
          'deletions_pending': 3,
          'total_insertions': 8,
          'total_deletions': 5,
          'unified_diff': '@@ -4,1 +4,1 @@\n-four\n+FOUR\n',
          'unified_diff_pending': '@@ -1,4 +1,4 @@\n one\n'
              '-two\n-three\n-four\n+ONE\n+THREE\n+FOUR\n',
        },
      });
      await Future<void>.delayed(Duration.zero);

      final bufs = WorkspaceService().buffers;
      final buf = bufs.firstWhere((b) => b.path == 'agg.txt');

      // PENDING counters (delta vs baseline) — the Changes panel
      // header and per-file card render these.
      expect(buf.pendingInsertions, 3,
          reason: 'Must mirror daemon insertions_pending aggregate.');
      expect(buf.pendingDeletions, 3);

      // Session-cumulative counters still available, but kept
      // separate so nobody mixes them with pending.
      expect(buf.insertions, 8);
      expect(buf.deletions, 5);

      // The aggregate diff vs baseline — parsed by `_DiffBody` with
      // `parseUnifiedDiff`. Must NOT equal the per-op `unified_diff`
      // which would only show the last edit (1 line change).
      expect(buf.unifiedDiffPending.contains('-two'), isTrue);
      expect(buf.unifiedDiffPending.contains('-three'), isTrue);
      expect(buf.unifiedDiffPending.contains('+ONE'), isTrue);
      expect(buf.unifiedDiffPending.contains('+THREE'), isTrue);

      PreviewStore().reset();
      WorkspaceModule().reset();
    });
  });

  group('terminal', () {
    test('terminal_output creates entry', () {
      ws.handleEvent('terminal_output', {
        'command': 'pwd',
        'output': '/home',
        'exit_code': 0,
      });
      expect(ws.terminal.length, 1);
      expect(ws.terminal.first.command, 'pwd');
      expect(ws.terminal.first.stdout, '/home');
    });

    test('setPendingCommand fills command on next terminal_output', () {
      ws.setPendingCommand('ls -la');
      ws.handleEvent('terminal_output', {
        'stdout': 'file1\nfile2',
        'exit_code': 0,
      });
      expect(ws.terminal.first.command, 'ls -la');
    });

    test('terminal capped at 200 entries', () {
      for (var i = 0; i < 250; i++) {
        ws.handleEvent('terminal_output', {
          'command': 'cmd$i',
          'output': '',
          'exit_code': 0,
        });
      }
      expect(ws.terminal.length, 200);
      // Oldest entries dropped first.
      expect(ws.terminal.first.command, 'cmd50');
      expect(ws.terminal.last.command, 'cmd249');
    });
  });
}
