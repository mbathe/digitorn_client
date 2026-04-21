import 'package:flutter/material.dart';
import 'package:yaml/yaml.dart' as yaml;
import '../../../theme/app_theme.dart';
import 'file_viewer.dart';
import 'structured/structured_data_viewer.dart';

/// YAML viewer — thin wrapper around [StructuredDataViewer]. Parses
/// the buffer with the official `yaml` package, normalises the
/// `YamlMap` / `YamlList` / `YamlScalar` objects to plain Dart
/// `Map<String, dynamic>` / `List<dynamic>` / primitives, and
/// delegates rendering to the shared structured viewer.
///
/// YAML supports a few extra primitive types compared to JSON
/// (e.g. `DateTime`, sets). Sets are turned into ordered lists; dates
/// are converted to ISO-8601 strings so the tree node simply shows
/// them as strings — good enough for v1.
class YamlFileViewer extends FileViewer with SearchableViewer {
  const YamlFileViewer();

  @override
  String get id => 'yaml';

  @override
  int get priority => 100;

  @override
  Set<String> get extensions => const {'yaml', 'yml'};

  @override
  Widget build(BuildContext context, ViewerContext vctx) {
    dynamic decoded;
    String? parseError;
    try {
      final raw = yaml.loadYaml(vctx.buffer.content);
      decoded = _yamlToPlain(raw);
    } catch (e) {
      parseError = e.toString();
    }
    return StructuredDataViewer(
      key: ValueKey('yaml-${vctx.buffer.path}'),
      filename: vctx.buffer.filename,
      rawContent: vctx.buffer.content,
      decodedValue: decoded,
      parseError: parseError,
      badgeLabel: 'YAML',
      badgeColorOf: (AppColors c) => c.purple,
      rawLanguage: 'yaml',
    );
  }
}

/// Recursively converts the YAML package's typed wrappers
/// (`YamlMap` / `YamlList`) into plain Dart collections so the
/// shared tree builder can walk them with its existing
/// `Map` / `List` checks.
dynamic _yamlToPlain(dynamic node) {
  if (node is yaml.YamlMap) {
    final m = <String, dynamic>{};
    node.forEach((k, v) {
      m[k.toString()] = _yamlToPlain(v);
    });
    return m;
  }
  if (node is yaml.YamlList) {
    return [for (final item in node) _yamlToPlain(item)];
  }
  if (node is DateTime) {
    return node.toIso8601String();
  }
  if (node is Set) {
    return node.map(_yamlToPlain).toList(growable: false);
  }
  // Scalars: String, num, bool, null — already in plain form.
  return node;
}
