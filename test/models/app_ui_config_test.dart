/// Anchors the Dart model to the daemon-captured `/ui-config` shape.
///
/// Payloads below are verbatim from
/// `scout/scout_ui_config_shape.py` runs — any future daemon change
/// will break these tests first.
library;

import 'package:digitorn_client/models/app_ui_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manual-mode app: auto_approve=false, workspace block empty', () {
    final cfg = AppUiConfig.fromJson({
      'app_id': 'ws-validate-manual',
      'workspace_config': {
        'render_mode': 'code',
        'sync_to_disk': true,
        'auto_approve': false,
      },
      'preview_config': {},
      'workspace': {},
    });
    expect(cfg.appId, 'ws-validate-manual');
    expect(cfg.workspace.renderMode, 'code');
    expect(cfg.workspace.autoApprove, isFalse);
    expect(cfg.workspace.syncToDisk, isTrue);
  });

  test('auto-approve app: auto_approve=true', () {
    final cfg = AppUiConfig.fromJson({
      'app_id': 'ws-validate-auto',
      'workspace_config': {
        'render_mode': 'code',
        'sync_to_disk': true,
        'auto_approve': true,
      },
      'preview_config': {},
      'workspace': {},
    });
    expect(cfg.workspace.autoApprove, isTrue);
  });

  test('digitorn-builder: merges workspace + workspace_config', () {
    final cfg = AppUiConfig.fromJson({
      'app_id': 'digitorn-builder',
      'workspace_config': {
        'render_mode': 'builder',
        'entry_file': 'app.yaml',
        'title': 'Digitorn App Builder',
        'sync_to_disk': true,
      },
      'preview_config': {},
      'workspace': {
        'render_mode': 'builder',
        'entry_file': 'app.yaml',
        'title': 'Digitorn App Builder',
      },
    });
    expect(cfg.workspace.renderMode, 'builder');
    expect(cfg.workspace.entryFile, 'app.yaml');
    expect(cfg.workspace.title, 'Digitorn App Builder');
    // auto_approve absent → default false
    expect(cfg.workspace.autoApprove, isFalse);
  });

  test('workspace_config wins on shared keys', () {
    final cfg = AppUiConfig.fromJson({
      'workspace_config': {'render_mode': 'code'},
      'workspace': {'render_mode': 'OUTDATED'},
    });
    // Superset wins the merge.
    expect(cfg.workspace.renderMode, 'code');
  });

  test('workspace-only fields fill gaps when workspace_config omits them',
      () {
    final cfg = AppUiConfig.fromJson({
      'workspace_config': {'auto_approve': true},
      'workspace': {'render_mode': 'markdown', 'entry_file': 'README.md'},
    });
    expect(cfg.workspace.autoApprove, isTrue);
    expect(cfg.workspace.renderMode, 'markdown');
    expect(cfg.workspace.entryFile, 'README.md');
  });

  test('empty config produces safe defaults', () {
    final cfg = AppUiConfig.fromJson({'app_id': 'x'});
    expect(cfg.workspace.autoApprove, isFalse);
    expect(cfg.workspace.renderMode, isNull);
    expect(cfg.preview.enabled, isFalse);
  });

  test('empty defaults constant', () {
    const empty = AppUiConfig.empty();
    expect(empty.appId, '');
    expect(empty.workspace.autoApprove, isFalse);
    expect(empty.preview.enabled, isFalse);
  });
}
