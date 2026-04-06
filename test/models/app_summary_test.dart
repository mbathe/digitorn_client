import 'package:flutter_test/flutter_test.dart';
import 'package:digitorn_client/models/app_summary.dart';

void main() {
  group('AppSummary', () {
    test('fromJson parses complete data', () {
      final app = AppSummary.fromJson({
        'app_id': 'opencode',
        'name': 'OpenCode',
        'version': '5.0',
        'mode': 'conversation',
        'agents': ['main', 'worker'],
        'modules': ['filesystem', 'shell'],
        'total_tools': 34,
        'total_categories': 6,
        'workspace_mode': 'required',
        'greeting': 'Ready!',
      });
      expect(app.appId, 'opencode');
      expect(app.name, 'OpenCode');
      expect(app.version, '5.0');
      expect(app.mode, 'conversation');
      expect(app.agents.length, 2);
      expect(app.modules.length, 2);
      expect(app.totalTools, 34);
      expect(app.totalCategories, 6);
      expect(app.workspaceMode, 'required');
      expect(app.greeting, 'Ready!');
    });

    test('fromJson handles missing fields', () {
      final app = AppSummary.fromJson({});
      expect(app.appId, '');
      expect(app.name, '');
      expect(app.agents, isEmpty);
      expect(app.totalTools, 0);
      expect(app.workspaceMode, 'auto');
    });
  });
}
