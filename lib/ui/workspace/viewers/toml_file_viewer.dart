import 'package:flutter/material.dart';
import 'package:toml/toml.dart' as toml;
import '../../../theme/app_theme.dart';
import 'file_viewer.dart';
import 'structured/structured_data_viewer.dart';

/// TOML viewer — thin wrapper around [StructuredDataViewer]. The
/// official `toml` package decodes a TOML document into a plain
/// `Map<String, dynamic>` of `String` / `int` / `double` / `bool` /
/// `DateTime` / `List` / nested maps, which is exactly what the shared
/// tree builder expects.
///
/// We just stringify [DateTime] values so the tree displays them as
/// `STR` instead of choking on an unknown type.
class TomlFileViewer extends FileViewer with SearchableViewer {
  const TomlFileViewer();

  @override
  String get id => 'toml';

  @override
  int get priority => 100;

  @override
  Set<String> get extensions => const {'toml'};

  @override
  Widget build(BuildContext context, ViewerContext vctx) {
    dynamic decoded;
    String? parseError;
    try {
      final doc = toml.TomlDocument.parse(vctx.buffer.content);
      decoded = _normaliseDates(doc.toMap());
    } catch (e) {
      parseError = e.toString();
    }
    return StructuredDataViewer(
      key: ValueKey('toml-${vctx.buffer.path}'),
      filename: vctx.buffer.filename,
      rawContent: vctx.buffer.content,
      decodedValue: decoded,
      parseError: parseError,
      badgeLabel: 'TOML',
      badgeColorOf: (AppColors c) => c.orange,
      rawLanguage: 'ini',
    );
  }

  /// Recursively replaces [DateTime] / [toml.TomlValue] subclasses with
  /// ISO-8601 strings so they fit the tree's primitive types.
  dynamic _normaliseDates(dynamic node) {
    if (node is Map) {
      final m = <String, dynamic>{};
      node.forEach((k, v) {
        m[k.toString()] = _normaliseDates(v);
      });
      return m;
    }
    if (node is List) {
      return [for (final item in node) _normaliseDates(item)];
    }
    if (node is DateTime) return node.toIso8601String();
    return node;
  }
}
