/// Minimal 5-field cron parser — computes the next N runs after a
/// given instant. Supports the standard Unix cron fields:
///
///     minute hour day-of-month month day-of-week
///
/// Each field accepts:
///   - `*`            any value
///   - `1`            literal
///   - `1,2,5`        list
///   - `1-5`          range
///   - `*/5` / `0-30/5` step on range
///
/// Returns `null` from [parse] on invalid input — the caller should
/// hide the "next runs" preview silently in that case.
library;

class CronExpression {
  final List<int> minutes; // 0..59
  final List<int> hours;   // 0..23
  final List<int> doms;    // 1..31
  final List<int> months;  // 1..12
  final List<int> dows;    // 0..6 (0=Sunday)

  const CronExpression._(
      this.minutes, this.hours, this.doms, this.months, this.dows);

  static CronExpression? parse(String raw) {
    final parts = raw.trim().split(RegExp(r'\s+'));
    if (parts.length != 5) return null;
    try {
      return CronExpression._(
        _field(parts[0], 0, 59),
        _field(parts[1], 0, 23),
        _field(parts[2], 1, 31),
        _field(parts[3], 1, 12),
        _field(parts[4], 0, 6),
      );
    } catch (_) {
      return null;
    }
  }

  /// Yields the next [count] DateTime occurrences after [from] (local),
  /// walking up to 366 days to avoid pathological expressions.
  List<DateTime> nextRuns(DateTime from, {int count = 3}) {
    final out = <DateTime>[];
    // Start from the next minute, ignore seconds.
    var t = DateTime(from.year, from.month, from.day, from.hour, from.minute)
        .add(const Duration(minutes: 1));
    final end = t.add(const Duration(days: 366));
    while (out.length < count && t.isBefore(end)) {
      if (!months.contains(t.month)) {
        t = DateTime(t.year, t.month + 1, 1, 0, 0);
        continue;
      }
      if (!doms.contains(t.day) || !dows.contains(t.weekday % 7)) {
        t = DateTime(t.year, t.month, t.day + 1, 0, 0);
        continue;
      }
      if (!hours.contains(t.hour)) {
        t = DateTime(t.year, t.month, t.day, t.hour + 1, 0);
        continue;
      }
      if (!minutes.contains(t.minute)) {
        t = t.add(const Duration(minutes: 1));
        continue;
      }
      out.add(t);
      t = t.add(const Duration(minutes: 1));
    }
    return out;
  }

  static List<int> _field(String f, int lo, int hi) {
    final out = <int>{};
    for (final piece in f.split(',')) {
      final stepIdx = piece.indexOf('/');
      final base = stepIdx < 0 ? piece : piece.substring(0, stepIdx);
      final step = stepIdx < 0 ? 1 : int.parse(piece.substring(stepIdx + 1));
      int start, end;
      if (base == '*') {
        start = lo;
        end = hi;
      } else if (base.contains('-')) {
        final r = base.split('-');
        start = int.parse(r[0]);
        end = int.parse(r[1]);
      } else {
        start = end = int.parse(base);
      }
      if (start < lo || end > hi || start > end || step <= 0) {
        throw FormatException('cron out of range: $f');
      }
      for (var v = start; v <= end; v += step) {
        out.add(v);
      }
    }
    final list = out.toList()..sort();
    return list;
  }
}

/// Human-friendly "in 2m", "in 4h", "tomorrow 09:00", etc.
String relativeDateTime(DateTime target, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final diff = target.difference(n);
  if (diff.isNegative) return 'past';
  if (diff.inSeconds < 60) return 'in <1m';
  if (diff.inMinutes < 60) return 'in ${diff.inMinutes}m';
  if (diff.inHours < 24 && target.day == n.day) {
    return 'today ${_hhmm(target)}';
  }
  final tomorrow = DateTime(n.year, n.month, n.day + 1);
  if (target.year == tomorrow.year &&
      target.month == tomorrow.month &&
      target.day == tomorrow.day) {
    return 'tomorrow ${_hhmm(target)}';
  }
  if (diff.inDays < 7) {
    return '${_dow(target.weekday)} ${_hhmm(target)}';
  }
  return '${target.day}/${target.month} ${_hhmm(target)}';
}

String _hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String _dow(int w) {
  const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return names[(w - 1) % 7];
}
