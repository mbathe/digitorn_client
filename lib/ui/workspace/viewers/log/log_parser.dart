/// Logical severity of a parsed log line. Order matches the intuitive
/// "noisiness" of logs — [unknown] sits apart for lines we can't
/// classify (plain text dumped to a `.log` file, etc.).
enum LogLevel { trace, debug, info, warn, error, fatal, unknown }

extension LogLevelX on LogLevel {
  /// Three-letter badge rendered in the gutter.
  String get shortLabel => switch (this) {
        LogLevel.trace => 'TRC',
        LogLevel.debug => 'DBG',
        LogLevel.info => 'INF',
        LogLevel.warn => 'WRN',
        LogLevel.error => 'ERR',
        LogLevel.fatal => 'FTL',
        LogLevel.unknown => '···',
      };

  /// Full upper-case label used in filter buttons / status bar.
  String get label => switch (this) {
        LogLevel.trace => 'TRACE',
        LogLevel.debug => 'DEBUG',
        LogLevel.info => 'INFO',
        LogLevel.warn => 'WARN',
        LogLevel.error => 'ERROR',
        LogLevel.fatal => 'FATAL',
        LogLevel.unknown => 'OTHER',
      };
}

/// A single parsed line.
class LogEntry {
  /// 1-based line number in the source file.
  final int lineNumber;

  /// Raw content of the line (whitespace preserved).
  final String rawLine;

  /// Best-effort detected level.
  final LogLevel level;

  /// Text of the timestamp prefix, if detected, e.g. `"2024-01-15 12:34:56"`.
  /// Null when no timestamp could be recognised.
  final String? timestampText;

  /// Message part of the line — the portion after the timestamp and
  /// level indicators were stripped. Falls back to [rawLine] when we
  /// can't isolate anything cleaner.
  final String message;

  const LogEntry({
    required this.lineNumber,
    required this.rawLine,
    required this.level,
    required this.timestampText,
    required this.message,
  });

  /// `true` when the line looks like the continuation of a stack trace
  /// (indented or starts with `at ` / `File ` / `Caused by`). Useful
  /// to inherit the level of the preceding line so the whole stack
  /// stays grouped under ERROR instead of dropping back to UNKNOWN.
  bool get looksLikeStackContinuation {
    if (rawLine.isEmpty) return false;
    final trimmed = rawLine.trimLeft();
    if (rawLine.startsWith(' ') || rawLine.startsWith('\t')) return true;
    if (trimmed.startsWith('at ')) return true;
    if (trimmed.startsWith('File "')) return true;
    if (trimmed.startsWith('Caused by')) return true;
    if (trimmed.startsWith('... ')) return true;
    return false;
  }
}

/// Parse a raw log file into a flat list of [LogEntry]. Stack-trace
/// continuations inherit the level of the last non-continuation line,
/// so an exception shows up as one logical group under `ERROR`.
List<LogEntry> parseLog(String raw) {
  if (raw.isEmpty) return const [];
  final lines = raw.split('\n');
  final out = <LogEntry>[];
  var lastNonContinuationLevel = LogLevel.unknown;

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.isEmpty && i == lines.length - 1) {
      // Ignore trailing empty line from the split.
      continue;
    }

    final timestampText = _extractTimestamp(line);
    var level = _detectLevel(line);

    // Build a clean message: strip the timestamp prefix, then any
    // trailing level indicator, leaving just the interesting bit.
    var message = line;
    if (timestampText != null && message.startsWith(timestampText)) {
      message = message.substring(timestampText.length).trimLeft();
      // Drop the separator that often follows a timestamp (`-`, `|`, `:`).
      if (message.isNotEmpty && '-|:'.contains(message[0])) {
        message = message.substring(1).trimLeft();
      }
    }
    message = _stripLevelPrefix(message);

    // Stack-trace continuation → inherit previous level.
    final continuation = LogEntry(
      lineNumber: i + 1,
      rawLine: line,
      level: level,
      timestampText: timestampText,
      message: message.isEmpty ? line : message,
    ).looksLikeStackContinuation;

    if (continuation && level == LogLevel.unknown) {
      level = lastNonContinuationLevel;
    }
    if (!continuation) {
      lastNonContinuationLevel = level;
    }

    out.add(LogEntry(
      lineNumber: i + 1,
      rawLine: line,
      level: level,
      timestampText: timestampText,
      message: message.isEmpty ? line : message,
    ));
  }
  return out;
}

// ─── Level detection ───────────────────────────────────────────────────────

/// Matches common level tokens in various shapes:
/// - `[ERROR]`, `[WARN]`, `[INFO]` …
/// - `ERROR:`, `WARN:` …
/// - ` ERROR `, ` WARN ` …
/// - `E/TAG`, `W/TAG`, `I/TAG`, `D/TAG` (Android logcat)
/// - JSON lines with `"level":"info"`.
final _kLevelPatterns = <LogLevel, List<RegExp>>{
  LogLevel.fatal: [
    RegExp(r'\bFATAL\b', caseSensitive: false),
    RegExp(r'\bCRITICAL\b', caseSensitive: false),
    RegExp(r'\bPANIC\b', caseSensitive: false),
  ],
  LogLevel.error: [
    RegExp(r'\bERROR\b', caseSensitive: false),
    RegExp(r'\[ERR\]', caseSensitive: false),
    RegExp(r'\bE/[A-Za-z]'),
  ],
  LogLevel.warn: [
    RegExp(r'\bWARN(ING)?\b', caseSensitive: false),
    RegExp(r'\[WRN\]', caseSensitive: false),
    RegExp(r'\bW/[A-Za-z]'),
  ],
  LogLevel.info: [
    RegExp(r'\bINFO\b', caseSensitive: false),
    RegExp(r'\[INF\]', caseSensitive: false),
    RegExp(r'\bNOTICE\b', caseSensitive: false),
    RegExp(r'\bI/[A-Za-z]'),
  ],
  LogLevel.debug: [
    RegExp(r'\bDEBUG\b', caseSensitive: false),
    RegExp(r'\[DBG\]', caseSensitive: false),
    RegExp(r'\bD/[A-Za-z]'),
  ],
  LogLevel.trace: [
    RegExp(r'\bTRACE\b', caseSensitive: false),
    RegExp(r'\[TRC\]', caseSensitive: false),
    RegExp(r'\bV/[A-Za-z]'),
  ],
};

LogLevel _detectLevel(String line) {
  // Only scan the first ~150 characters to keep hot path cheap.
  final scan = line.length > 150 ? line.substring(0, 150) : line;
  // Priority from loudest to quietest.
  for (final level in const [
    LogLevel.fatal,
    LogLevel.error,
    LogLevel.warn,
    LogLevel.info,
    LogLevel.debug,
    LogLevel.trace,
  ]) {
    for (final p in _kLevelPatterns[level]!) {
      if (p.hasMatch(scan)) return level;
    }
  }
  return LogLevel.unknown;
}

/// Drop a level prefix like `ERROR:` or `[INFO]` from the start of the
/// message. Purely cosmetic — we already captured the level.
String _stripLevelPrefix(String message) {
  final pats = [
    RegExp(r'^\[(FATAL|ERROR|WARN(ING)?|INFO|NOTICE|DEBUG|TRACE|ERR|WRN|INF|DBG|TRC)\]\s*',
        caseSensitive: false),
    RegExp(r'^(FATAL|ERROR|WARN(ING)?|INFO|NOTICE|DEBUG|TRACE)[:\s]\s*',
        caseSensitive: false),
  ];
  for (final p in pats) {
    final m = p.firstMatch(message);
    if (m != null) return message.substring(m.end);
  }
  return message;
}

// ─── Timestamp detection ───────────────────────────────────────────────────

/// Matches the **prefix** of a line that looks like a timestamp. We try
/// the most specific patterns first and bail out on the first match.
final _kTimestampPatterns = <RegExp>[
  // ISO 8601 with time: `2024-01-15T12:34:56(.123)?(Z|+HH:MM)?`
  RegExp(
    r'^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?',
  ),
  // Python logging: `2024-01-15 12:34:56,123`
  RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d+'),
  // Just a date: `2024-01-15`
  RegExp(r'^\d{4}-\d{2}-\d{2}'),
  // Just time: `12:34:56(.123)?`
  RegExp(r'^\d{2}:\d{2}:\d{2}(\.\d+)?'),
  // Syslog: `Jan 15 12:34:56`
  RegExp(
    r'^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}',
  ),
  // Bracketed: `[2024-01-15T12:34:56Z]`
  RegExp(
    r'^\[\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?\]',
  ),
];

String? _extractTimestamp(String line) {
  if (line.isEmpty) return null;
  for (final p in _kTimestampPatterns) {
    final m = p.firstMatch(line);
    if (m != null) return line.substring(m.start, m.end);
  }
  return null;
}
