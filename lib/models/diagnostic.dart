/// LSP-shape diagnostics delivered via the `diagnostics` resource
/// channel on [PreviewStore]. The payload format mirrors the LSP
/// spec one-for-one so Monaco can render markers with minimal
/// translation — see [Diagnostic.toMonacoJson] for the 0→1 base
/// conversion Monaco expects.
library;

import 'package:flutter/foundation.dart';

enum DiagnosticSeverity {
  error,
  warning,
  info,
  hint;

  static DiagnosticSeverity parse(String? s) {
    switch (s?.toLowerCase()) {
      case 'error':
        return DiagnosticSeverity.error;
      case 'warning':
        return DiagnosticSeverity.warning;
      case 'info':
      case 'information':
        return DiagnosticSeverity.info;
      case 'hint':
        return DiagnosticSeverity.hint;
    }
    return DiagnosticSeverity.error;
  }

  String get wireName => switch (this) {
        DiagnosticSeverity.error => 'error',
        DiagnosticSeverity.warning => 'warning',
        DiagnosticSeverity.info => 'info',
        DiagnosticSeverity.hint => 'hint',
      };

  /// Higher = worse. Used by aggregators (worstSeverity, sort).
  int get rank => switch (this) {
        DiagnosticSeverity.error => 3,
        DiagnosticSeverity.warning => 2,
        DiagnosticSeverity.info => 1,
        DiagnosticSeverity.hint => 0,
      };
}

@immutable
class DiagnosticPosition {
  final int line; // 0-based (LSP)
  final int character; // 0-based
  const DiagnosticPosition(this.line, this.character);

  factory DiagnosticPosition.fromJson(Map m) => DiagnosticPosition(
        (m['line'] as num?)?.toInt() ?? 0,
        (m['character'] as num?)?.toInt() ?? 0,
      );
}

@immutable
class DiagnosticRange {
  final DiagnosticPosition start;
  final DiagnosticPosition end;
  const DiagnosticRange(this.start, this.end);

  factory DiagnosticRange.fromJson(Map m) {
    final s = m['start'];
    final e = m['end'];
    return DiagnosticRange(
      s is Map
          ? DiagnosticPosition.fromJson(s)
          : const DiagnosticPosition(0, 0),
      e is Map
          ? DiagnosticPosition.fromJson(e)
          : const DiagnosticPosition(0, 0),
    );
  }
}

@immutable
class Diagnostic {
  final DiagnosticSeverity severity;
  final String message;
  final DiagnosticRange range;
  final String? code; // e.g. "2304"
  final String? source; // e.g. "ts", "eslint", "pyright"
  const Diagnostic({
    required this.severity,
    required this.message,
    required this.range,
    this.code,
    this.source,
  });

  factory Diagnostic.fromJson(Map m) => Diagnostic(
        severity: DiagnosticSeverity.parse(m['severity'] as String?),
        message: (m['message'] as String?) ?? '',
        range: m['range'] is Map
            ? DiagnosticRange.fromJson(m['range'] as Map)
            : const DiagnosticRange(
                DiagnosticPosition(0, 0), DiagnosticPosition(0, 0)),
        code: m['code']?.toString(),
        source: m['source'] as String?,
      );

  /// Monaco `IMarkerData` shape. Monaco is 1-based for lines/columns
  /// and uses a numeric severity enum (8/4/2/1). LSP is 0-based, so
  /// we add 1 here — the canonical conversion documented across every
  /// monaco-languageclient implementation.
  Map<String, dynamic> toMonacoJson() => {
        'startLineNumber': range.start.line + 1,
        'startColumn': range.start.character + 1,
        'endLineNumber': range.end.line + 1,
        'endColumn': range.end.character + 1,
        'message': message,
        'severity': switch (severity) {
          DiagnosticSeverity.error => 8,
          DiagnosticSeverity.warning => 4,
          DiagnosticSeverity.info => 2,
          DiagnosticSeverity.hint => 1,
        },
        if (code != null) 'code': code,
        if (source != null) 'source': source,
      };
}

/// A snapshot of the daemon's current diagnostics for a single file.
/// [generation] is strictly monotonic per (session, path) — the client
/// must reject any payload whose generation is older than the last
/// one seen for the same path (guards against out-of-order socket
/// delivery).
///
/// [sourceModule] identifies the daemon module that produced the
/// diagnostics — `"workspace"` for Lovable-style in-memory virtual
/// filesystems, `"filesystem"` for real on-disk workspaces. Optional;
/// absent on older daemons. Surfaced only in tooltips — callers can
/// ignore it for most display purposes.
@immutable
class DiagnosticsEntry {
  final String filePath;
  final List<Diagnostic> items;
  final int generation;
  final DiagnosticSeverity? severityMax;
  final double? updatedAt;
  final String? sourceModule;

  const DiagnosticsEntry({
    required this.filePath,
    required this.items,
    required this.generation,
    this.severityMax,
    this.updatedAt,
    this.sourceModule,
  });

  factory DiagnosticsEntry.fromJson(String filePath, Map m) {
    final rawItems = m['items'];
    final items = rawItems is List
        ? rawItems.whereType<Map>().map(Diagnostic.fromJson).toList()
        : const <Diagnostic>[];
    DiagnosticSeverity? worst;
    if (m['severity_max'] != null) {
      worst = DiagnosticSeverity.parse(m['severity_max'] as String?);
    } else if (items.isNotEmpty) {
      worst = items.map((d) => d.severity).reduce(
          (a, b) => a.rank >= b.rank ? a : b);
    }
    return DiagnosticsEntry(
      filePath: filePath,
      items: items,
      generation: (m['generation'] as num?)?.toInt() ?? 0,
      severityMax: worst,
      updatedAt: (m['updated_at'] as num?)?.toDouble(),
      sourceModule: m['source_module'] as String?,
    );
  }

  /// Human-readable tag for the module that produced this entry.
  /// Empty string when [sourceModule] is null or unrecognised.
  String get sourceModuleLabel {
    switch (sourceModule) {
      case 'workspace':
        return 'in-memory';
      case 'filesystem':
        return 'on-disk';
      default:
        return '';
    }
  }

  bool get isEmpty => items.isEmpty;
  bool get isNotEmpty => items.isNotEmpty;
  int get errorCount =>
      items.where((d) => d.severity == DiagnosticSeverity.error).length;
  int get warningCount =>
      items.where((d) => d.severity == DiagnosticSeverity.warning).length;
  int get infoCount =>
      items.where((d) => d.severity == DiagnosticSeverity.info).length;
  int get hintCount =>
      items.where((d) => d.severity == DiagnosticSeverity.hint).length;
}
