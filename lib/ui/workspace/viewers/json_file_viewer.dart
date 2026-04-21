import 'dart:convert';
import 'package:flutter/material.dart';
import '../../../theme/app_theme.dart';
import 'file_viewer.dart';
import 'structured/structured_data_viewer.dart';

/// JSON viewer — a thin wrapper around [StructuredDataViewer] that
/// only knows how to decode JSON. All the tree, search, path bar,
/// expand/collapse, copy and raw-mode behaviour lives in the shared
/// component, so adding YAML / TOML / XML viewers is a one-file job.
class JsonFileViewer extends FileViewer with SearchableViewer {
  const JsonFileViewer();

  @override
  String get id => 'json';

  @override
  int get priority => 100;

  @override
  Set<String> get extensions => const {'json', 'jsonc'};

  @override
  Widget build(BuildContext context, ViewerContext vctx) {
    dynamic decoded;
    String? parseError;
    try {
      decoded = jsonDecode(vctx.buffer.content);
    } catch (e) {
      parseError = e.toString();
    }
    return StructuredDataViewer(
      key: ValueKey('json-${vctx.buffer.path}'),
      filename: vctx.buffer.filename,
      rawContent: vctx.buffer.content,
      decodedValue: decoded,
      parseError: parseError,
      badgeLabel: 'JSON',
      badgeColorOf: (AppColors c) => c.cyan,
      rawLanguage: 'json',
    );
  }
}
