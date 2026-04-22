/// Typed quota model — live-matched against
/// `GET /api/apps/{app_id}/quota(/me|/user/{uid})`.
///
/// Daemon shape (confirmed 2026-04, tested live):
/// ```json
/// {
///   "app_id": "digitorn-chat",
///   "user_id": "alice-uid",        // only on /me and /user/{uid}
///   "scope": "user",               // "app" | "user"
///   "quota": { ... },              // raw override, may be null
///   "effective": { ... },          // merged app+user; what's enforced
///   "usage": {
///     "messages": {
///       "5h": {
///         "current": 47, "limit": 100,
///         "reset_at": 1776806748.16,        // ← Unix seconds float
///         "reset_at_iso": "2026-04-21T21:25:48Z",
///         "reset": "rolling_from_first"
///       }
///     }
///   },
///   "updated_at": "...",
///   "updated_by": "..."
/// }
/// ```
library;

import 'package:flutter/foundation.dart';

/// Reset strategy enum — five flavours the daemon supports.
enum ResetStrategy {
  /// Generic fixed window aligned on the epoch. Reset every N
  /// seconds (derived from the window name, e.g. `per_minute` →
  /// 60 s).
  fixed,

  /// Calendar day boundary (UTC midnight).
  fixedDaily,

  /// Calendar week boundary (Monday UTC 00:00).
  fixedWeekly,

  /// Calendar month boundary (1st of the month UTC 00:00).
  fixedMonthly,

  /// Window starts when the FIRST event lands inside it (the
  /// Claude-style "N messages in 5 rolling hours" flavour). The
  /// counter doesn't reset until the oldest event in the window
  /// falls off.
  rollingFromFirst;

  static ResetStrategy fromString(String? s) => switch (s) {
        'fixed_daily' => ResetStrategy.fixedDaily,
        'fixed_weekly' => ResetStrategy.fixedWeekly,
        'fixed_monthly' => ResetStrategy.fixedMonthly,
        'rolling_from_first' => ResetStrategy.rollingFromFirst,
        _ => ResetStrategy.fixed,
      };

  String toJson() => switch (this) {
        ResetStrategy.fixedDaily => 'fixed_daily',
        ResetStrategy.fixedWeekly => 'fixed_weekly',
        ResetStrategy.fixedMonthly => 'fixed_monthly',
        ResetStrategy.rollingFromFirst => 'rolling_from_first',
        ResetStrategy.fixed => 'fixed',
      };
}

/// Metric names the daemon supports. Keep as plain strings in the
/// model (the server accepts arbitrary keys under `metric_windows`)
/// but expose the known set as a constant for UI pickers.
const kKnownQuotaMetrics = <String>[
  'requests',
  'messages',
  'tokens_input',
  'tokens_output',
  'tokens_total',
  'cost_usd',
];

/// Standard window names (live next to `custom` under each metric).
const kNamedWindows = <String>[
  'per_minute',
  'per_hour',
  'per_day',
  'per_week',
  'per_month',
];

/// One (limit, reset) pair. The daemon's shape is just
/// `{"limit": N, "reset": "..."}`.
class QuotaRule {
  final double limit;
  final ResetStrategy reset;

  const QuotaRule({required this.limit, required this.reset});

  factory QuotaRule.fromJson(Map<String, dynamic> j) => QuotaRule(
        limit: (j['limit'] as num? ?? 0).toDouble(),
        reset: ResetStrategy.fromString(j['reset'] as String?),
      );

  Map<String, dynamic> toJson() => {
        'limit': limit,
        'reset': reset.toJson(),
      };

  QuotaRule copyWith({double? limit, ResetStrategy? reset}) => QuotaRule(
        limit: limit ?? this.limit,
        reset: reset ?? this.reset,
      );
}

/// Usage counter returned under `usage.{metric}.{window}`. Every
/// field is live-populated by the daemon per turn.
class UsageCounter {
  final double current;
  final double limit;

  /// Absolute UTC time this counter rolls over.
  final DateTime resetAt;
  final ResetStrategy reset;

  const UsageCounter({
    required this.current,
    required this.limit,
    required this.resetAt,
    required this.reset,
  });

  factory UsageCounter.fromJson(Map<String, dynamic> j) {
    final rawMs = j['reset_at'];
    DateTime resetAt;
    if (rawMs is num) {
      // Daemon sends Unix SECONDS (float). Dart's
      // fromMillisecondsSinceEpoch takes ms → multiply by 1000.
      resetAt = DateTime.fromMillisecondsSinceEpoch(
        (rawMs * 1000).toInt(),
        isUtc: true,
      );
    } else if (j['reset_at_iso'] is String) {
      resetAt =
          DateTime.tryParse(j['reset_at_iso'] as String)?.toUtc() ??
              DateTime.now().toUtc();
    } else {
      resetAt = DateTime.now().toUtc();
    }
    return UsageCounter(
      current: (j['current'] as num? ?? 0).toDouble(),
      limit: (j['limit'] as num? ?? 0).toDouble(),
      resetAt: resetAt,
      reset: ResetStrategy.fromString(j['reset'] as String?),
    );
  }

  /// 0.0 when no limit or untouched; capped visually to 1.0 by
  /// callers (but the raw value can exceed 100% on a post-turn
  /// overrun, so keep the computation faithful to [current]).
  double get percent =>
      limit > 0 ? (current / limit).clamp(0, double.infinity).toDouble() : 0.0;

  double get remaining =>
      (limit - current).clamp(0, double.infinity).toDouble();

  Duration get untilReset => resetAt.difference(DateTime.now().toUtc());

  bool get exceeded => limit > 0 && current >= limit;
  bool get nearLimit => percent >= 0.8;
}

/// The `quota` / `effective` map — metric → window → rule + the flat
/// session-level caps (`concurrent_sessions` etc.). Kept minimal so
/// the admin editor can round-trip exactly what the daemon stores.
class QuotaDefinition {
  /// metric → window → rule.
  final Map<String, Map<String, QuotaRule>> metricWindows;

  /// Flat caps the daemon stores at the top level of the quota map.
  final int? concurrentSessions;
  final int? messagesPerSession;
  final int? sessionDurationSeconds;

  const QuotaDefinition({
    this.metricWindows = const {},
    this.concurrentSessions,
    this.messagesPerSession,
    this.sessionDurationSeconds,
  });

  factory QuotaDefinition.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const QuotaDefinition();
    final mw = <String, Map<String, QuotaRule>>{};
    // Walk every top-level key that looks like a metric (any map).
    for (final entry in j.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      final windows = <String, QuotaRule>{};
      final m = value.cast<String, dynamic>();
      // Named windows live directly under the metric.
      for (final name in kNamedWindows) {
        final v = m[name];
        if (v is Map) {
          windows[name] = QuotaRule.fromJson(v.cast<String, dynamic>());
        }
      }
      // Custom windows live under `custom`.
      final custom = m['custom'];
      if (custom is Map) {
        for (final c in custom.entries) {
          if (c.value is Map) {
            windows[c.key as String] =
                QuotaRule.fromJson((c.value as Map).cast<String, dynamic>());
          }
        }
      }
      if (windows.isNotEmpty) mw[entry.key] = windows;
    }
    return QuotaDefinition(
      metricWindows: mw,
      concurrentSessions: (j['concurrent_sessions'] as num?)?.toInt(),
      messagesPerSession: (j['messages_per_session'] as num?)?.toInt(),
      sessionDurationSeconds:
          (j['session_duration_seconds'] as num?)?.toInt(),
    );
  }

  /// Serialize back to the daemon's shape. Puts named windows
  /// directly under the metric and everything else under `custom`.
  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{};
    final namedSet = kNamedWindows.toSet();
    for (final m in metricWindows.entries) {
      final bucket = <String, dynamic>{};
      final custom = <String, dynamic>{};
      for (final w in m.value.entries) {
        if (namedSet.contains(w.key)) {
          bucket[w.key] = w.value.toJson();
        } else {
          custom[w.key] = w.value.toJson();
        }
      }
      if (custom.isNotEmpty) bucket['custom'] = custom;
      if (bucket.isNotEmpty) out[m.key] = bucket;
    }
    if (concurrentSessions != null) {
      out['concurrent_sessions'] = concurrentSessions;
    }
    if (messagesPerSession != null) {
      out['messages_per_session'] = messagesPerSession;
    }
    if (sessionDurationSeconds != null) {
      out['session_duration_seconds'] = sessionDurationSeconds;
    }
    return out;
  }

  bool get isEmpty =>
      metricWindows.isEmpty &&
      concurrentSessions == null &&
      messagesPerSession == null &&
      sessionDurationSeconds == null;

  QuotaDefinition copyWith({
    Map<String, Map<String, QuotaRule>>? metricWindows,
    int? concurrentSessions,
    int? messagesPerSession,
    int? sessionDurationSeconds,
  }) =>
      QuotaDefinition(
        metricWindows: metricWindows ?? this.metricWindows,
        concurrentSessions: concurrentSessions ?? this.concurrentSessions,
        messagesPerSession: messagesPerSession ?? this.messagesPerSession,
        sessionDurationSeconds:
            sessionDurationSeconds ?? this.sessionDurationSeconds,
      );
}

/// Full quota response — same shape on `/quota`, `/quota/me`,
/// `/quota/user/{uid}`.
class QuotaResponse {
  final String appId;
  final String? userId;
  final String scope;
  final QuotaDefinition? quota;
  final QuotaDefinition effective;
  final Map<String, Map<String, UsageCounter>> usage;
  final DateTime? updatedAt;
  final String? updatedBy;

  const QuotaResponse({
    required this.appId,
    this.userId,
    required this.scope,
    this.quota,
    required this.effective,
    this.usage = const {},
    this.updatedAt,
    this.updatedBy,
  });

  factory QuotaResponse.fromJson(Map<String, dynamic> j) {
    final rawUsage = j['usage'];
    final usage = <String, Map<String, UsageCounter>>{};
    if (rawUsage is Map) {
      for (final m in rawUsage.cast<String, dynamic>().entries) {
        if (m.value is! Map) continue;
        final windows = <String, UsageCounter>{};
        for (final w in (m.value as Map).cast<String, dynamic>().entries) {
          if (w.value is Map) {
            windows[w.key] = UsageCounter.fromJson(
                (w.value as Map).cast<String, dynamic>());
          }
        }
        if (windows.isNotEmpty) usage[m.key] = windows;
      }
    }
    return QuotaResponse(
      appId: (j['app_id'] as String?) ?? '',
      userId: j['user_id'] as String?,
      scope: (j['scope'] as String?) ?? 'app',
      quota: j['quota'] is Map
          ? QuotaDefinition.fromJson(
              (j['quota'] as Map).cast<String, dynamic>())
          : null,
      effective: j['effective'] is Map
          ? QuotaDefinition.fromJson(
              (j['effective'] as Map).cast<String, dynamic>())
          : const QuotaDefinition(),
      usage: usage,
      updatedAt: _parseDate(j['updated_at']),
      updatedBy: j['updated_by'] as String?,
    );
  }

  /// Flat (metric, window, counter) tuples suitable for rendering
  /// one card per pair. Sorted so the most critical (highest %)
  /// floats to the top, then alphabetical.
  List<({String metric, String window, UsageCounter counter})>
      get usageFlat {
    final out = <({String metric, String window, UsageCounter counter})>[];
    for (final m in usage.entries) {
      for (final w in m.value.entries) {
        out.add((metric: m.key, window: w.key, counter: w.value));
      }
    }
    out.sort((a, b) {
      final byPercent = b.counter.percent.compareTo(a.counter.percent);
      if (byPercent != 0) return byPercent;
      final byMetric = a.metric.compareTo(b.metric);
      if (byMetric != 0) return byMetric;
      return a.window.compareTo(b.window);
    });
    return out;
  }

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is String) return DateTime.tryParse(v)?.toUtc();
    if (v is num) {
      return DateTime.fromMillisecondsSinceEpoch((v * 1000).toInt(),
          isUtc: true);
    }
    return null;
  }
}

/// Event payload emitted on the session room when the daemon
/// refuses a turn because of a quota. Parsed by the chat panel
/// listener; the field names match the server's exact keys.
class QuotaExceededEvent {
  final String scope;
  final String metric;
  final String window;
  final double current;
  final double limit;
  final DateTime resetAt;
  final Duration retryAfter;
  final bool postTurn;

  const QuotaExceededEvent({
    required this.scope,
    required this.metric,
    required this.window,
    required this.current,
    required this.limit,
    required this.resetAt,
    required this.retryAfter,
    required this.postTurn,
  });

  factory QuotaExceededEvent.fromJson(Map<String, dynamic> j) {
    final rawResetAt = j['reset_at'];
    final resetAt = rawResetAt is num
        ? DateTime.fromMillisecondsSinceEpoch(
            (rawResetAt * 1000).toInt(),
            isUtc: true,
          )
        : (rawResetAt is String
            ? (DateTime.tryParse(rawResetAt)?.toUtc() ??
                DateTime.now().toUtc())
            : DateTime.now().toUtc());
    final retry = (j['retry_after_seconds'] as num?)?.toInt() ?? 0;
    return QuotaExceededEvent(
      scope: (j['scope'] as String?) ?? 'app',
      metric: (j['metric'] as String?) ?? 'messages',
      window: (j['window'] as String?) ?? 'per_day',
      current: (j['current'] as num? ?? 0).toDouble(),
      limit: (j['limit'] as num? ?? 0).toDouble(),
      resetAt: resetAt,
      retryAfter: Duration(seconds: retry),
      postTurn: j['post_turn'] == true,
    );
  }
}

/// Parse a "custom" window name like `"5h"` / `"30m"` / `"7d"` into
/// its (count, unit) components. Returns null for the named windows
/// (`per_day`, etc.) — the caller should handle those separately.
({int count, String unit})? parseCustomWindow(String window) {
  final m = RegExp(r'^(\d+)([smhdw])$').firstMatch(window);
  if (m == null) return null;
  return (count: int.parse(m.group(1)!), unit: m.group(2)!);
}

/// Format a counter's headline value (current / limit). Cost uses
/// a dollar sign + 2 decimals; everything else uses integer count.
String formatCounterValue(double v, String metric) {
  if (metric == 'cost_usd') {
    return '\$${v.toStringAsFixed(2)}';
  }
  // Simple thousands-separator (locale-free on purpose so it
  // renders the same on every device).
  final rounded = v.round().abs();
  final sign = v < 0 ? '-' : '';
  final str = rounded.toString();
  final buf = StringBuffer();
  for (var i = 0; i < str.length; i++) {
    if (i > 0 && (str.length - i) % 3 == 0) buf.write(',');
    buf.write(str[i]);
  }
  return '$sign$buf';
}

/// True if the spec's known metric list contains [metric].
bool isKnownMetric(String metric) => kKnownQuotaMetrics.contains(metric);

/// Safeguard: debug-only invariant that a round-trip of the JSON
/// preserves the shape. Used by tests, not runtime code.
@visibleForTesting
void assertRoundTrip(QuotaDefinition d) {
  final encoded = d.toJson();
  final decoded = QuotaDefinition.fromJson(encoded);
  assert(decoded.metricWindows.keys.toSet() == d.metricWindows.keys.toSet());
}
