import 'package:csv/csv.dart';

/// All separators we know how to detect, in priority order
/// (we prefer comma when ties happen because comma is the default
/// for the canonical CSV spec).
const List<String> _kCandidateSeparators = [',', ';', '\t', '|'];

/// Inferred logical type of a CSV column.
enum CsvColumnType { integer, decimal, dateTime, boolean, text }

extension CsvColumnTypeX on CsvColumnType {
  String get label => switch (this) {
        CsvColumnType.integer => 'INT',
        CsvColumnType.decimal => 'NUM',
        CsvColumnType.dateTime => 'DATE',
        CsvColumnType.boolean => 'BOOL',
        CsvColumnType.text => 'TEXT',
      };

  /// Logical alignment hint used by the grid renderer.
  /// Numbers right-align, dates centre, text left-aligns.
  CsvAlign get alignment => switch (this) {
        CsvColumnType.integer => CsvAlign.right,
        CsvColumnType.decimal => CsvAlign.right,
        CsvColumnType.dateTime => CsvAlign.center,
        CsvColumnType.boolean => CsvAlign.center,
        CsvColumnType.text => CsvAlign.left,
      };
}

enum CsvAlign { left, center, right }

class CsvColumn {
  /// Display name (header row value, or "Column N" if no header).
  final String name;

  /// Zero-based index in the original row.
  final int index;

  /// Inferred logical type for the values under this column.
  final CsvColumnType type;

  const CsvColumn({
    required this.name,
    required this.index,
    required this.type,
  });
}

/// Result of parsing a CSV file. Immutable, ready to feed a grid.
class ParsedCsv {
  /// All data rows (excluding the header row if [hasHeader] is true).
  final List<List<String>> rows;

  /// Detected column metadata.
  final List<CsvColumn> columns;

  /// Whether the first line was treated as a header.
  final bool hasHeader;

  /// Detected separator character.
  final String separator;

  /// True if a UTF-8 BOM was stripped from the input.
  final bool hadBom;

  const ParsedCsv({
    required this.rows,
    required this.columns,
    required this.hasHeader,
    required this.separator,
    required this.hadBom,
  });

  int get rowCount => rows.length;
  int get columnCount => columns.length;

  /// Human-readable label for [separator].
  String get separatorLabel => switch (separator) {
        ',' => 'comma',
        ';' => 'semicolon',
        '\t' => 'tab',
        '|' => 'pipe',
        _ => separator.codeUnits.map((c) => 'U+${c.toRadixString(16)}').join(),
      };
}

/// Public entry point. Parses a raw CSV string into a [ParsedCsv].
ParsedCsv parseCsv(String raw) {
  if (raw.isEmpty) {
    return const ParsedCsv(
      rows: [],
      columns: [],
      hasHeader: false,
      separator: ',',
      hadBom: false,
    );
  }

  // Strip UTF-8 BOM if present.
  final hadBom = raw.codeUnitAt(0) == 0xFEFF;
  final input = hadBom ? raw.substring(1) : raw;

  // Detect separator before parsing.
  final separator = _detectSeparator(input);

  // Use the csv package — it handles quoting, escaping, embedded
  // newlines and trailing whitespace correctly.
  final converter = CsvToListConverter(
    fieldDelimiter: separator,
    eol: _detectEol(input),
    shouldParseNumbers: false,
    allowInvalid: true,
  );
  final raw2d = converter.convert(input);

  if (raw2d.isEmpty) {
    return ParsedCsv(
      rows: const [],
      columns: const [],
      hasHeader: false,
      separator: separator,
      hadBom: hadBom,
    );
  }

  // Normalise: stringify all cells and pad short rows so every row has
  // the same column count (some CSVs end rows early when trailing
  // values are empty).
  final maxCols = raw2d.fold<int>(0, (m, r) => r.length > m ? r.length : m);
  final stringRows = <List<String>>[];
  for (final r in raw2d) {
    final padded = List<String>.filled(maxCols, '');
    for (var i = 0; i < r.length; i++) {
      padded[i] = r[i]?.toString() ?? '';
    }
    stringRows.add(padded);
  }

  // Decide if the first row is a header. Heuristics:
  //   1. Single row → no header (we have nothing to compare against).
  //   2. If every cell of row 0 is non-empty AND none parses as a
  //      number / date / bool, treat it as a header.
  //   3. Otherwise treat it as data.
  final hasHeader = _looksLikeHeader(stringRows);

  final headerRow = hasHeader ? stringRows.first : null;
  final dataRows = hasHeader ? stringRows.sublist(1) : stringRows;

  final columns = <CsvColumn>[];
  for (var c = 0; c < maxCols; c++) {
    final name = headerRow != null && c < headerRow.length && headerRow[c].isNotEmpty
        ? headerRow[c]
        : 'Column ${c + 1}';
    final type = _inferColumnType(dataRows, c);
    columns.add(CsvColumn(name: name, index: c, type: type));
  }

  return ParsedCsv(
    rows: dataRows,
    columns: columns,
    hasHeader: hasHeader,
    separator: separator,
    hadBom: hadBom,
  );
}

// ─── Helpers ───────────────────────────────────────────────────────────────

/// Best-effort separator detection. Tries each candidate, parses the
/// first ~10 lines, picks the one that yields the most consistent and
/// largest column count. Ties broken by candidate order.
String _detectSeparator(String input) {
  final sample =
      input.split(RegExp(r'\r\n|\n|\r')).take(10).where((l) => l.isNotEmpty).toList();
  if (sample.isEmpty) return ',';

  String? best;
  int bestScore = -1;

  for (final sep in _kCandidateSeparators) {
    // Use a quick parse with the same converter so quoting is honoured.
    final conv = CsvToListConverter(
      fieldDelimiter: sep,
      eol: '\n',
      shouldParseNumbers: false,
      allowInvalid: true,
    );
    final parsed = conv.convert(sample.join('\n'));
    if (parsed.isEmpty) continue;

    final counts = parsed.map((r) => r.length).toList();
    final maxFields = counts.fold<int>(0, (m, c) => c > m ? c : m);
    if (maxFields <= 1) continue;
    // Consistency = how many rows match the max count.
    final consistent = counts.where((c) => c == maxFields).length;
    final score = consistent * 100 + maxFields;

    if (score > bestScore) {
      bestScore = score;
      best = sep;
    }
  }

  return best ?? ',';
}

/// Pick CRLF if it appears, else LF. The csv package needs an explicit
/// EOL to chunk records correctly.
String _detectEol(String input) {
  if (input.contains('\r\n')) return '\r\n';
  if (input.contains('\r')) return '\r';
  return '\n';
}

/// Heuristic header detection. Returns true if the first row looks
/// distinctly different from the data rows (textual labels).
bool _looksLikeHeader(List<List<String>> rows) {
  if (rows.length < 2) return false;
  final first = rows.first;
  if (first.isEmpty) return false;

  // Every header cell must be non-empty.
  if (first.any((c) => c.trim().isEmpty)) return false;

  // No header cell may parse as int / double / DateTime / bool.
  for (final c in first) {
    if (_isInt(c) || _isDouble(c) || _isDateTime(c) || _isBool(c)) {
      return false;
    }
  }

  // At least one row below must contain typed data (otherwise we
  // probably just have a CSV of strings everywhere — keep header).
  return true;
}

CsvColumnType _inferColumnType(List<List<String>> rows, int col) {
  if (rows.isEmpty) return CsvColumnType.text;
  // Sample up to 200 rows to keep inference fast on big files.
  final sampleSize = rows.length < 200 ? rows.length : 200;

  var seen = 0;
  var allInt = true;
  var allNum = true;
  var allDate = true;
  var allBool = true;

  for (var i = 0; i < sampleSize; i++) {
    if (col >= rows[i].length) continue;
    final raw = rows[i][col].trim();
    if (raw.isEmpty) continue;
    seen++;

    if (allInt && !_isInt(raw)) allInt = false;
    if (allNum && !_isDouble(raw)) allNum = false;
    if (allDate && !_isDateTime(raw)) allDate = false;
    if (allBool && !_isBool(raw)) allBool = false;

    if (!allInt && !allNum && !allDate && !allBool) break;
  }

  if (seen == 0) return CsvColumnType.text;
  if (allInt) return CsvColumnType.integer;
  if (allNum) return CsvColumnType.decimal;
  if (allBool) return CsvColumnType.boolean;
  if (allDate) return CsvColumnType.dateTime;
  return CsvColumnType.text;
}

bool _isInt(String s) {
  // Allow leading +/-. Strip thousands separators (only if pattern is
  // canonical, e.g. "1,234,567" — but never if separator is comma…).
  // Keep it strict here: pure digits with optional sign.
  return RegExp(r'^[+-]?\d+$').hasMatch(s);
}

bool _isDouble(String s) {
  if (_isInt(s)) return true;
  return RegExp(r'^[+-]?(\d+\.\d*|\.\d+|\d+)([eE][+-]?\d+)?$').hasMatch(s);
}

bool _isBool(String s) {
  final l = s.toLowerCase();
  return l == 'true' || l == 'false' || l == 'yes' || l == 'no';
}

/// Try a small set of common datetime formats. We deliberately avoid
/// pulling in `intl` for parsing — these patterns cover ~95% of CSVs
/// without needing a heavyweight dep.
bool _isDateTime(String s) {
  // ISO 8601 (with or without time, with or without TZ).
  if (RegExp(r'^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?)?$')
      .hasMatch(s)) {
    return true;
  }
  // dd/MM/yyyy or MM/dd/yyyy
  if (RegExp(r'^\d{1,2}/\d{1,2}/\d{4}$').hasMatch(s)) return true;
  // dd-MM-yyyy
  if (RegExp(r'^\d{1,2}-\d{1,2}-\d{4}$').hasMatch(s)) return true;
  // yyyy/MM/dd
  if (RegExp(r'^\d{4}/\d{1,2}/\d{1,2}$').hasMatch(s)) return true;
  return false;
}
