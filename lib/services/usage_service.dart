/// Real usage & quota data fetched from `GET /api/users/me/usage`.
///
/// The daemon returns authoritative token + cost numbers computed
/// from the actual per-model pricing table (20+ models). The shape
/// is the one documented in the Omnibus integration doc §3:
///
/// {
///   "quota": {
///     "tokens_per_month": 10000000,
///     "tokens_used_this_month": 3214567,
///     "tokens_remaining": 6785433,
///     "resets_at": "2026-05-01T00:00:00Z"
///   },
///   "cost": {
///     "currency": "USD",
///     "this_month": 12.34,
///     "by_model": {"claude-opus-4-6": 8.20, "gpt-4o": 3.00}
///   },
///   "tokens_this_month": {"prompt": 1500000, "completion": 700000, "total": 2200000},
///   "tokens_timeseries_24h": [{"ts": "...", "prompt": 1234, "completion": 567}, ...],
///   "tokens_timeseries_30d": [{"date": "...", "prompt": 12340, "completion": 5670}, ...],
///   "by_app": [{"app_id": "digitorn-code", "tokens": 280000, "cost_usd": 3.75}, ...]
/// }
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'auth_service.dart';

/// One bucket in the token time series. `ts` is populated for the
/// 24h series (hourly), `day` for the 30d series (daily).
class UsagePoint {
  final DateTime? ts;
  final DateTime? day;
  final int promptTokens;
  final int completionTokens;

  int get totalTokens => promptTokens + completionTokens;

  const UsagePoint({
    this.ts,
    this.day,
    this.promptTokens = 0,
    this.completionTokens = 0,
  });
}

class UsageByApp {
  final String appId;
  final String? appName;
  final int tokens;
  final double costUsd;
  const UsageByApp({
    required this.appId,
    required this.tokens,
    required this.costUsd,
    this.appName,
  });
}

class UsageSnapshot {
  // Totals for the current month.
  final int totalTokens;
  final int promptTokens;
  final int completionTokens;

  // Cost block.
  final double costThisMonth;
  final String currency;
  final Map<String, double> costByModel;

  // Quota block — all null when the user is unlimited.
  final int? quotaTokenLimit;
  final int? quotaTokenUsed;
  final int? quotaTokenRemaining;
  final DateTime? quotaResetsAt;

  // Time series and breakdown.
  final List<UsagePoint> timeseries24h;
  final List<UsagePoint> timeseries30d;
  final List<UsageByApp> byApp;

  final DateTime fetchedAt;

  const UsageSnapshot({
    this.totalTokens = 0,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.costThisMonth = 0,
    this.currency = 'USD',
    this.costByModel = const {},
    this.quotaTokenLimit,
    this.quotaTokenUsed,
    this.quotaTokenRemaining,
    this.quotaResetsAt,
    this.timeseries24h = const [],
    this.timeseries30d = const [],
    this.byApp = const [],
    required this.fetchedAt,
  });

  bool get hasQuota => quotaTokenLimit != null && quotaTokenLimit! > 0;

  /// Fraction used 0..1 — only meaningful when [hasQuota] is true.
  double get quotaFraction {
    if (!hasQuota) return 0;
    final used = (quotaTokenUsed ?? totalTokens).toDouble();
    final limit = quotaTokenLimit!.toDouble();
    return (used / limit).clamp(0, 1);
  }

  /// Days until the quota period resets. Null when there's no
  /// quota or the daemon didn't send [quotaResetsAt].
  int? get daysUntilReset {
    if (quotaResetsAt == null) return null;
    final diff = quotaResetsAt!.difference(DateTime.now()).inDays;
    return diff < 0 ? 0 : diff;
  }
}

class UsageService extends ChangeNotifier {
  static final UsageService _i = UsageService._();
  factory UsageService() => _i;
  UsageService._();

  late final Dio _dio = Dio(BaseOptions(
    receiveTimeout: const Duration(seconds: 15),
    validateStatus: (s) => s != null && s < 500,
  ))..interceptors.add(AuthService().authInterceptor);

  UsageSnapshot? _snapshot;
  UsageSnapshot? get snapshot => _snapshot;

  bool _loading = false;
  bool get loading => _loading;

  String? _error;
  String? get error => _error;

  Future<UsageSnapshot?> load() async {
    if (_loading) return _snapshot;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final r = await _dio.get(
        '${AuthService().baseUrl}/api/users/me/usage',
      );
      if (r.statusCode != 200 || r.data is! Map) {
        _error = 'HTTP ${r.statusCode}';
        _loading = false;
        notifyListeners();
        return _snapshot;
      }
      _snapshot = _parse(Map<String, dynamic>.from(r.data as Map));
      _loading = false;
      notifyListeners();
      return _snapshot;
    } on DioException catch (e) {
      _error = e.message ?? e.toString();
      _loading = false;
      notifyListeners();
      return _snapshot;
    }
  }

  int _asInt(dynamic v) =>
      v is num ? v.toInt() : (int.tryParse('$v') ?? 0);
  double _asDbl(dynamic v) =>
      v is num ? v.toDouble() : (double.tryParse('$v') ?? 0);
  DateTime? _asDate(dynamic v) {
    if (v is String) return DateTime.tryParse(v);
    if (v is num) {
      return DateTime.fromMillisecondsSinceEpoch((v * 1000).toInt());
    }
    return null;
  }

  UsageSnapshot _parse(Map<String, dynamic> j) {
    // ── Tokens this month (prompt/completion/total) ──
    final tokensMonth = (j['tokens_this_month'] is Map)
        ? (j['tokens_this_month'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};

    // ── Cost block ──
    final cost = (j['cost'] is Map)
        ? (j['cost'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final costByModelRaw = (cost['by_model'] is Map)
        ? (cost['by_model'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final costByModel = <String, double>{
      for (final e in costByModelRaw.entries) e.key: _asDbl(e.value),
    };

    // ── Quota block ──
    final quota = (j['quota'] is Map)
        ? (j['quota'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};

    // ── Time series ──
    final ts24 = <UsagePoint>[];
    final raw24 = j['tokens_timeseries_24h'];
    if (raw24 is List) {
      for (final p in raw24) {
        if (p is! Map) continue;
        final m = p.cast<String, dynamic>();
        ts24.add(UsagePoint(
          ts: _asDate(m['ts']),
          promptTokens: _asInt(m['prompt']),
          completionTokens: _asInt(m['completion']),
        ));
      }
    }

    final ts30 = <UsagePoint>[];
    final raw30 = j['tokens_timeseries_30d'];
    if (raw30 is List) {
      for (final p in raw30) {
        if (p is! Map) continue;
        final m = p.cast<String, dynamic>();
        ts30.add(UsagePoint(
          day: _asDate(m['date']),
          promptTokens: _asInt(m['prompt']),
          completionTokens: _asInt(m['completion']),
        ));
      }
    }

    // ── By app ──
    final byApp = <UsageByApp>[];
    final byAppRaw = j['by_app'];
    if (byAppRaw is List) {
      for (final p in byAppRaw) {
        if (p is! Map) continue;
        final m = p.cast<String, dynamic>();
        final id = m['app_id'] as String?;
        if (id == null) continue;
        byApp.add(UsageByApp(
          appId: id,
          appName: m['app_name'] as String?,
          tokens: _asInt(m['tokens']),
          costUsd: _asDbl(m['cost_usd']),
        ));
      }
      // Bigger spenders first so the breakdown list ranks correctly.
      byApp.sort((a, b) => b.tokens.compareTo(a.tokens));
    }

    final prompt = _asInt(tokensMonth['prompt']);
    final completion = _asInt(tokensMonth['completion']);
    final total = _asInt(tokensMonth['total']);
    final resolvedTotal = total > 0 ? total : (prompt + completion);

    return UsageSnapshot(
      totalTokens: resolvedTotal,
      promptTokens: prompt,
      completionTokens: completion,
      costThisMonth: _asDbl(cost['this_month']),
      currency: (cost['currency'] as String?) ?? 'USD',
      costByModel: costByModel,
      quotaTokenLimit: quota['tokens_per_month'] is num
          ? (quota['tokens_per_month'] as num).toInt()
          : null,
      quotaTokenUsed: quota['tokens_used_this_month'] is num
          ? (quota['tokens_used_this_month'] as num).toInt()
          : null,
      quotaTokenRemaining: quota['tokens_remaining'] is num
          ? (quota['tokens_remaining'] as num).toInt()
          : null,
      quotaResetsAt: _asDate(quota['resets_at']),
      timeseries24h: ts24,
      timeseries30d: ts30,
      byApp: byApp,
      fetchedAt: DateTime.now(),
    );
  }
}
