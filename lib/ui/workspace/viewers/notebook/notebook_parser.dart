import 'dart:convert';

/// Parsed Jupyter notebook (.ipynb) document.
///
/// The on-disk format is JSON described by the nbformat spec; this
/// module decodes it into Dart models the viewer can render directly,
/// stripping the format quirks (e.g. `source` may be a string or a list
/// of lines, outputs come in many shapes, …).
class NotebookDocument {
  final List<NotebookCell> cells;
  final String? kernelName;
  final String? kernelDisplayName;
  final String? language;
  final String? languageVersion;
  final int nbformat;
  final int nbformatMinor;
  final String? parseError;

  const NotebookDocument({
    required this.cells,
    this.kernelName,
    this.kernelDisplayName,
    this.language,
    this.languageVersion,
    this.nbformat = 4,
    this.nbformatMinor = 0,
    this.parseError,
  });

  bool get isValid => parseError == null;
  bool get isEmpty => cells.isEmpty;

  int get codeCellCount => cells.whereType<CodeCell>().length;
  int get markdownCellCount => cells.whereType<MarkdownCell>().length;

  /// Convenience: human-readable kernel summary, e.g. "Python 3 · python 3.11.5".
  String get kernelSummary {
    final disp = kernelDisplayName ?? kernelName ?? '';
    final lang = language ?? '';
    final ver = languageVersion ?? '';
    final right = [lang, ver].where((s) => s.isNotEmpty).join(' ');
    if (disp.isEmpty && right.isEmpty) return 'Notebook';
    if (right.isEmpty) return disp;
    if (disp.isEmpty) return right;
    return '$disp · $right';
  }

  static NotebookDocument parse(String raw) {
    if (raw.trim().isEmpty) {
      return const NotebookDocument(cells: [], parseError: 'Empty notebook');
    }
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return _parseDocument(json);
    } catch (e) {
      return NotebookDocument(
        cells: const [],
        parseError: 'Invalid notebook JSON: $e',
      );
    }
  }
}

NotebookDocument _parseDocument(Map<String, dynamic> json) {
  final rawCells = json['cells'] as List? ?? const [];
  final cells = <NotebookCell>[];
  for (final raw in rawCells) {
    if (raw is! Map<String, dynamic>) continue;
    final cell = _parseCell(raw);
    if (cell != null) cells.add(cell);
  }

  final metadata = json['metadata'] as Map<String, dynamic>? ?? const {};
  final kernelspec = metadata['kernelspec'] as Map<String, dynamic>? ?? const {};
  final languageInfo =
      metadata['language_info'] as Map<String, dynamic>? ?? const {};

  return NotebookDocument(
    cells: cells,
    kernelName: kernelspec['name'] as String?,
    kernelDisplayName: kernelspec['display_name'] as String?,
    language: languageInfo['name'] as String? ??
        kernelspec['language'] as String?,
    languageVersion: languageInfo['version'] as String?,
    nbformat: (json['nbformat'] as num?)?.toInt() ?? 4,
    nbformatMinor: (json['nbformat_minor'] as num?)?.toInt() ?? 0,
  );
}

NotebookCell? _parseCell(Map<String, dynamic> raw) {
  final type = raw['cell_type'] as String? ?? '';
  final source = _normaliseSource(raw['source']);

  switch (type) {
    case 'code':
      return CodeCell(
        source: source,
        executionCount: (raw['execution_count'] as num?)?.toInt(),
        outputs: _parseOutputs(raw['outputs']),
      );
    case 'markdown':
      return MarkdownCell(source: source);
    case 'raw':
      return RawCell(source: source);
  }
  return null;
}

/// nbformat allows `source` to be either a single string or a list of
/// strings (each ending in `\n` for non-final lines). Coerce to a single
/// string for consumers.
String _normaliseSource(dynamic source) {
  if (source == null) return '';
  if (source is String) return source;
  if (source is List) return source.whereType<String>().join();
  return source.toString();
}

List<NotebookOutput> _parseOutputs(dynamic raw) {
  if (raw is! List) return const [];
  final out = <NotebookOutput>[];
  for (final item in raw) {
    if (item is! Map<String, dynamic>) continue;
    final type = item['output_type'] as String? ?? '';
    switch (type) {
      case 'stream':
        out.add(StreamOutput(
          name: item['name'] as String? ?? 'stdout',
          text: _normaliseSource(item['text']),
        ));
        break;
      case 'display_data':
      case 'execute_result':
        out.add(DisplayDataOutput(
          data: _normaliseDataMap(item['data']),
          executionCount: (item['execution_count'] as num?)?.toInt(),
          isExecuteResult: type == 'execute_result',
        ));
        break;
      case 'error':
        out.add(ErrorOutput(
          ename: item['ename'] as String? ?? 'Error',
          evalue: item['evalue'] as String? ?? '',
          traceback: (item['traceback'] as List? ?? const [])
              .whereType<String>()
              .toList(),
        ));
        break;
    }
  }
  return out;
}

/// nbformat values inside `data` may be either strings or lists of
/// strings (same line-list trick as `source`). Normalise to strings.
Map<String, String> _normaliseDataMap(dynamic raw) {
  if (raw is! Map) return const {};
  final out = <String, String>{};
  raw.forEach((k, v) {
    if (k is! String) return;
    if (v is String) {
      out[k] = v;
    } else if (v is List) {
      out[k] = v.whereType<String>().join();
    } else if (v != null) {
      out[k] = v.toString();
    }
  });
  return out;
}

// ─── Cell models ───────────────────────────────────────────────────────────

abstract class NotebookCell {
  String get source;
  const NotebookCell();
}

class CodeCell extends NotebookCell {
  @override
  final String source;
  final int? executionCount;
  final List<NotebookOutput> outputs;

  const CodeCell({
    required this.source,
    required this.executionCount,
    required this.outputs,
  });

  String get prompt =>
      'In [${executionCount?.toString() ?? ' '}]:';
}

class MarkdownCell extends NotebookCell {
  @override
  final String source;
  const MarkdownCell({required this.source});
}

class RawCell extends NotebookCell {
  @override
  final String source;
  const RawCell({required this.source});
}

// ─── Output models ─────────────────────────────────────────────────────────

abstract class NotebookOutput {
  const NotebookOutput();
}

class StreamOutput extends NotebookOutput {
  final String name; // 'stdout' | 'stderr'
  final String text;
  const StreamOutput({required this.name, required this.text});
  bool get isStderr => name == 'stderr';
}

class DisplayDataOutput extends NotebookOutput {
  /// MIME type → string content (already normalised).
  /// Common keys: 'text/plain', 'text/html', 'image/png', 'image/jpeg',
  /// 'image/svg+xml', 'application/json'.
  final Map<String, String> data;

  /// Only present for 'execute_result'; null for 'display_data'.
  final int? executionCount;
  final bool isExecuteResult;

  const DisplayDataOutput({
    required this.data,
    required this.executionCount,
    required this.isExecuteResult,
  });

  String? get textPlain => data['text/plain'];
  String? get textHtml => data['text/html'];
  String? get imagePng => data['image/png'];
  String? get imageJpeg => data['image/jpeg'];
  String? get imageSvg => data['image/svg+xml'];
  String? get json => data['application/json'];

  String? get prompt => isExecuteResult
      ? 'Out[${executionCount?.toString() ?? ' '}]:'
      : null;
}

class ErrorOutput extends NotebookOutput {
  final String ename;
  final String evalue;
  final List<String> traceback;

  const ErrorOutput({
    required this.ename,
    required this.evalue,
    required this.traceback,
  });

  /// Traceback joined and stripped of ANSI escape sequences.
  String get prettyTraceback {
    final joined = traceback.join('\n');
    return _stripAnsi(joined);
  }
}

/// Quick & dirty ANSI escape stripper. Removes CSI sequences (`ESC [ ... letter`)
/// and OSC sequences. Good enough for tracebacks.
String _stripAnsi(String input) {
  return input
      .replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '')
      .replaceAll(RegExp(r'\x1B\][^\x07]*\x07'), '');
}
