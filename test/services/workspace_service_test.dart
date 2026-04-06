import 'package:flutter_test/flutter_test.dart';
import 'package:digitorn_client/services/workspace_service.dart';

void main() {
  late WorkspaceService ws;

  setUp(() {
    ws = WorkspaceService();
    ws.clearAll();
  });

  group('WorkspaceService', () {
    group('buffers', () {
      test('workbench_read creates buffer', () {
        ws.handleEvent('workbench_read', {
          'buffer': '/tmp/test.py',
          'type': 'code',
          'content': 'print("hello")\nprint("world")',
        });
        expect(ws.buffers.length, 1);
        expect(ws.buffers.first.filename, 'test.py');
        expect(ws.buffers.first.extension, 'py');
        expect(ws.buffers.first.lines, 2);
        expect(ws.activeBufferPath, '/tmp/test.py');
      });

      test('workbench_write creates buffer', () {
        ws.handleEvent('workbench_write', {
          'buffer': '/tmp/new.js',
          'type': 'code',
          'content': 'const x = 1;',
        });
        expect(ws.buffers.length, 1);
        expect(ws.buffers.first.filename, 'new.js');
      });

      test('workbench_edit creates buffer with previous content', () {
        // First read
        ws.handleEvent('workbench_read', {
          'buffer': '/tmp/edit.py',
          'type': 'code',
          'content': 'old content',
        });

        // Then edit
        ws.handleEvent('workbench_edit', {
          'buffer': '/tmp/edit.py',
          'type': 'code',
          'content': 'new content',
          'previous_content': 'old content',
        });
        expect(ws.buffers.length, 1);
        expect(ws.buffers.first.content, 'new content');
        expect(ws.buffers.first.previousContent, 'old content');
        expect(ws.buffers.first.isEdited, true);
      });

      test('multiple buffers with different paths', () {
        ws.handleEvent('workbench_read', {'buffer': '/a.py', 'type': 'code', 'content': 'a'});
        ws.handleEvent('workbench_read', {'buffer': '/b.js', 'type': 'code', 'content': 'b'});
        expect(ws.buffers.length, 2);
        expect(ws.activeBufferPath, '/b.js'); // last opened
      });

      test('setActiveBuffer changes active', () {
        ws.handleEvent('workbench_read', {'buffer': '/a.py', 'type': 'code', 'content': 'a'});
        ws.handleEvent('workbench_read', {'buffer': '/b.js', 'type': 'code', 'content': 'b'});
        ws.setActiveBuffer('/a.py');
        expect(ws.activeBufferPath, '/a.py');
      });

      test('closeBuffer removes buffer', () {
        ws.handleEvent('workbench_read', {'buffer': '/a.py', 'type': 'code', 'content': 'a'});
        ws.closeBuffer('/a.py');
        expect(ws.buffers, isEmpty);
      });
    });

    group('WorkbenchBuffer', () {
      test('filename extracts from path', () {
        final buf = WorkbenchBuffer(
          path: '/home/user/project/src/main.py',
          type: 'code', content: '', lines: 0, chars: 0,
        );
        expect(buf.filename, 'main.py');
        expect(buf.extension, 'py');
      });

      test('directory extracts from path', () {
        final buf = WorkbenchBuffer(
          path: '/home/user/project/src/main.py',
          type: 'code', content: '', lines: 0, chars: 0,
        );
        expect(buf.directory, '/home/user/project/src');
      });

      test('diffStats counts insertions and deletions', () {
        final buf = WorkbenchBuffer(
          path: '/test.py', type: 'code',
          content: 'line1\nline2\nnew_line',
          previousContent: 'line1\nold_line\nline2',
          lines: 3, chars: 20, isEdited: true,
        );
        final stats = buf.diffStats;
        expect(stats.insertions, greaterThan(0));
        expect(stats.deletions, greaterThan(0));
      });

      test('diffStats zero when not edited', () {
        final buf = WorkbenchBuffer(
          path: '/test.py', type: 'code',
          content: 'content', lines: 1, chars: 7,
        );
        expect(buf.diffStats.insertions, 0);
        expect(buf.diffStats.deletions, 0);
      });
    });

    group('terminal', () {
      test('terminal_output creates entry', () {
        ws.handleEvent('terminal_output', {
          'stdout': 'hello world\n',
          'stderr': '',
        });
        expect(ws.terminal.length, 1);
        expect(ws.terminal.first.stdout, 'hello world\n');
        expect(ws.activeTab, 'terminal');
      });

      test('setPendingCommand is used by terminal_output', () {
        ws.setPendingCommand('ls -la');
        ws.handleEvent('terminal_output', {
          'stdout': 'file1\nfile2',
          'stderr': '',
        });
        expect(ws.terminal.first.command, 'ls -la');
      });

      test('terminal max 200 entries', () {
        for (int i = 0; i < 210; i++) {
          ws.handleEvent('terminal_output', {
            'stdout': 'output $i',
            'stderr': '',
          });
        }
        expect(ws.terminal.length, 200);
      });
    });

    group('clearAll', () {
      test('resets everything', () {
        ws.handleEvent('workbench_read', {'buffer': '/a.py', 'type': 'code', 'content': 'a'});
        ws.handleEvent('terminal_output', {'stdout': 'x', 'stderr': ''});
        ws.clearAll();
        expect(ws.buffers, isEmpty);
        expect(ws.terminal, isEmpty);
        expect(ws.activeBufferPath, isNull);
      });
    });
  });
}
