import 'package:flutter/widgets.dart';

import '../ide/monaco_editor_pane.dart';
import 'file_viewer.dart';

/// Fallback viewer that hosts any text-based file inside Monaco.
/// Used by the [ViewerRegistry] as the catch-all for unknown
/// extensions — registered in `main.dart` via `setFallback`. Also
/// claims a broad set of common code/text extensions so it wins
/// over unspecialised viewers.
///
/// Previously wrapped a `flutter_highlight`-based editor; unified
/// on Monaco so every code surface in the workspace speaks the
/// same VS Code dialect (syntax, gutter, diagnostics).
class CodeFileViewer extends FileViewer
    with NavigableViewer, SearchableViewer {
  const CodeFileViewer();

  @override
  String get id => 'code';

  @override
  Set<String> get extensions => const {
        'txt', 'log', 'md', 'markdown',
        'dart', 'py', 'js', 'mjs', 'cjs', 'ts', 'tsx', 'jsx',
        'html', 'htm', 'css', 'scss', 'sass',
        'json', 'yaml', 'yml', 'toml', 'xml',
        'sh', 'bash', 'zsh', 'fish', 'ps1', 'bat', 'cmd',
        'c', 'cc', 'cpp', 'cxx', 'h', 'hpp',
        'rs', 'go', 'java', 'kt', 'swift',
        'sql', 'env', 'ini', 'cfg', 'conf',
        'rb', 'php', 'pl', 'lua',
      };

  @override
  Widget build(BuildContext context, ViewerContext vctx) {
    // Monaco derives the language from the path extension when we
    // don't pass one explicitly — good enough for the fallback.
    return MonacoEditorPane(
      path: vctx.buffer.path,
      content: vctx.buffer.content,
      readOnly: true,
    );
  }
}
