// Verifies that `AppState._onWorkspaceModuleChanged` auto-opens the
// workspace panel when the module first receives files.
//
// This is the pipeline:
//   preview:resource_set → PreviewStore.notify → WorkspaceModule
//     → _onStoreChanged (schedules microtask) → _rebuild
//     → notifyListeners → AppState._onWorkspaceModuleChanged
//     → addPostFrameCallback → showWorkspace
//
// Tests must drain microtasks via `tester.runAsync` and then pump a
// frame so the post-frame callback fires.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:digitorn_client/main.dart' show AppState;
import 'package:digitorn_client/services/preview_store.dart';
import 'package:digitorn_client/services/workspace_module.dart';

Future<void> _settle(WidgetTester tester) async {
  // Drain microtasks (WorkspaceModule defers _rebuild via
  // scheduleMicrotask) then pump two frames so both the rebuild
  // notification AND AppState's post-frame callback fire.
  await tester.runAsync(() async {
    // Longer than a single microtask tick — gives the fakeAsync
    // timer queue room to drain.
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PreviewStore().reset();
    WorkspaceModule().reset();
  });

  tearDown(() {
    WorkspaceModule().reset();
    PreviewStore().reset();
  });

  testWidgets('showWorkspace direct call flips isWorkspaceVisible',
      (tester) async {
    final state = AppState();
    expect(state.isWorkspaceVisible, false);
    state.showWorkspace();
    expect(state.isWorkspaceVisible, true);
    state.dispose();
  });

  testWidgets('first file triggers showWorkspace', (tester) async {
    final state = AppState();
    expect(state.isWorkspaceVisible, false);

    PreviewStore().applyHistoryEvent('preview:resource_set', {
      'channel': 'files',
      'id': 'src/hello.py',
      'payload': {'content': 'print("hi")'},
    });
    await _settle(tester);

    expect(WorkspaceModule().hasFiles, true,
        reason: 'module populated from PreviewStore');
    expect(state.isWorkspaceVisible, true,
        reason: '_onWorkspaceModuleChanged should fire showWorkspace');

    state.dispose();
  });

  testWidgets('DIAG: WorkspaceModule notifies listeners on resource_set',
      (tester) async {
    var notified = 0;
    WorkspaceModule().addListener(() => notified++);

    PreviewStore().applyHistoryEvent('preview:resource_set', {
      'channel': 'files',
      'id': 'diag.py',
      'payload': {'content': 'x'},
    });

    // Give microtasks a chance to drain.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    // ignore: avoid_print
    print('DIAG: notified=$notified, hasFiles=${WorkspaceModule().hasFiles}');
    expect(notified, greaterThan(0),
        reason:
            'WorkspaceModule must notify listeners after preview:resource_set');
    expect(WorkspaceModule().hasFiles, true);
  });

  testWidgets('stays hidden when module has no files', (tester) async {
    final state = AppState();
    await _settle(tester);
    expect(state.isWorkspaceVisible, false);
    expect(WorkspaceModule().hasFiles, false);
    state.dispose();
  });

  testWidgets('manual close then new file re-opens the panel',
      (tester) async {
    final state = AppState();
    PreviewStore().applyHistoryEvent('preview:resource_set', {
      'channel': 'files',
      'id': 'a.py',
      'payload': {'content': 'a'},
    });
    await _settle(tester);
    expect(state.isWorkspaceVisible, true);

    state.closeWorkspace();
    expect(state.isWorkspaceVisible, false);

    PreviewStore().applyHistoryEvent('preview:resource_set', {
      'channel': 'files',
      'id': 'b.py',
      'payload': {'content': 'b'},
    });
    await _settle(tester);

    // Post-consolidation, the agent writing another file after the
    // user manually closed should re-surface the workspace. This
    // prevents "je ferme le workspace mais je sais plus ce que fait
    // l'agent".
    expect(state.isWorkspaceVisible, true);
    state.dispose();
  });
}
