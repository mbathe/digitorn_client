import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../services/auth_service.dart';

/// Session metrics — fetched from GET /api/apps/{appId}/sessions/{sessionId}
class SessionMetrics extends ChangeNotifier {
  static final SessionMetrics _i = SessionMetrics._();
  factory SessionMetrics() => _i;
  SessionMetrics._();

  bool isActive = false;
  int turnNumber = 0;
  String model = '';

  int promptTokens = 0;
  int completionTokens = 0;
  int get totalTokens => promptTokens + completionTokens;

  double contextPressure = 0;
  int contextEstimated = 0;
  int contextMax = 0;
  int outputReserved = 0;
  int effectiveMax = 0;
  int systemPromptTokens = 0;
  double systemPromptPct = 0;
  int toolsSchemaTokens = 0;
  double toolsSchemaPct = 0;
  int messageHistoryTokens = 0;
  double messageHistoryPct = 0;
  int availableTokens = 0;
  int compactions = 0;

  int toolCallsTotal = 0;
  int toolCallsSuccess = 0;
  int toolCallsFailed = 0;
  double costUsd = 0;

  Timer? _pollTimer;
  String? _appId;
  String? _sessionId;

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 5),
    validateStatus: (s) => s != null && s < 500,
  ))..interceptors.add(AuthService().authInterceptor);

  String get _base => AuthService().baseUrl;

  /// Fetch once immediately, then every 60s as a safety net.
  /// Real-time updates come from the session SSE via [updateContext].
  void startPolling(String appId, String sessionId) {
    _appId = appId;
    _sessionId = sessionId;
    _pollTimer?.cancel();
    fetch();
    _pollTimer = Timer.periodic(const Duration(seconds: 60), (_) => fetch());
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Fetch from API
  Future<void> fetch() async {
    if (_appId == null || _sessionId == null) return;
    try {
      final resp = await _dio.get(
        '$_base/api/apps/$_appId/sessions/$_sessionId',
      );
      if (resp.statusCode != 200 || resp.data == null) return;

      final d = (resp.data['data'] ?? resp.data) as Map<String, dynamic>;

      isActive = d['is_active'] as bool? ?? isActive;
      turnNumber = d['turn_number'] as int? ?? d['message_count'] as int? ?? turnNumber;
      model = d['model'] as String? ?? model;

      final tokens = d['tokens'] as Map<String, dynamic>?;
      if (tokens != null) {
        promptTokens = tokens['prompt'] as int? ?? promptTokens;
        completionTokens = tokens['completion'] as int? ?? completionTokens;
      }

      final ctx = d['context'] as Map<String, dynamic>?;
      if (ctx != null) {
        updateContext(ctx);
        // Polling the `GET session` endpoint returns the canonical
        // aggregate — trust it authoritatively.
        ContextState().updateFromJson(ctx, authoritative: true);
      }

      final tools = d['tools'] as Map<String, dynamic>?;
      if (tools != null) {
        toolCallsTotal = tools['total_calls'] as int? ?? toolCallsTotal;
        toolCallsSuccess = tools['success'] as int? ?? toolCallsSuccess;
        toolCallsFailed = tools['failed'] as int? ?? toolCallsFailed;
      }

      // Cost
      final cost = d['cost_usd'] as num? ?? d['total_cost_usd'] as num?;
      if (cost != null) costUsd = cost.toDouble();

      notifyListeners();
    } catch (e) {
      debugPrint('SessionMetrics.fetch: $e');
    }
  }

  void reset() {
    stopPolling();
    isActive = false;
    turnNumber = 0;
    model = '';
    promptTokens = 0;
    completionTokens = 0;
    contextPressure = 0;
    contextEstimated = 0;
    toolCallsTotal = 0;
    toolCallsSuccess = 0;
    toolCallsFailed = 0;
    costUsd = 0;
    _appId = null;
    _sessionId = null;
    notifyListeners();
  }

  // Formatted
  String fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return n.toString();
  }

  void updateContext(Map<String, dynamic> ctx) {
    contextPressure = (ctx['pressure'] as num?)?.toDouble() ?? contextPressure;
    contextEstimated = ctx['total_estimated_tokens'] as int? ?? ctx['total_estimated'] as int? ?? contextEstimated;
    contextMax = ctx['max_tokens'] as int? ?? contextMax;
    outputReserved = ctx['output_reserved'] as int? ?? outputReserved;
    effectiveMax = ctx['effective_max'] as int? ?? effectiveMax;
    systemPromptTokens = ctx['system_prompt_tokens'] as int? ?? systemPromptTokens;
    systemPromptPct = (ctx['system_prompt_pct'] as num?)?.toDouble() ?? systemPromptPct;
    toolsSchemaTokens = ctx['tools_schema_tokens'] as int? ?? toolsSchemaTokens;
    toolsSchemaPct = (ctx['tools_schema_pct'] as num?)?.toDouble() ?? toolsSchemaPct;
    messageHistoryTokens = ctx['message_history_tokens'] as int? ?? messageHistoryTokens;
    messageHistoryPct = (ctx['message_history_pct'] as num?)?.toDouble() ?? messageHistoryPct;
    availableTokens = ctx['available_tokens'] as int? ?? availableTokens;
    compactions = ctx['compactions'] as int? ?? compactions;
    notifyListeners();
  }

  String get pressurePercent => '${(contextPressure * 100).round()}%';
}

/// Daemon-provided context window state — single source of truth.
class ContextState extends ChangeNotifier {
  static final ContextState _i = ContextState._();
  factory ContextState() => _i;
  ContextState._();

  int maxTokens = 0;
  int outputReserved = 0;
  int effectiveMax = 0;
  int systemPromptTokens = 0;
  double systemPromptPct = 0;
  int toolsSchemaTokens = 0;
  double toolsSchemaPct = 0;
  int messageHistoryTokens = 0;
  double messageHistoryPct = 0;
  int totalEstimatedTokens = 0;
  double pressure = 0; // 0.0 to 1.0 — raw: estimatedTokens / maxTokens
  int availableTokens = 0;
  int compactions = 0;

  /// Compaction trigger — when `pressure >= threshold`, the daemon
  /// fires `compact_context`. Sourced from the app's YAML (scout
  /// confirmed hooks always ship `threshold: 0.75` on stock apps);
  /// this is the denominator the UI uses so 100 % means "about to
  /// compact" rather than "at the model's absolute max".
  double threshold = 0.75;

  /// Pressure normalised by the compaction threshold — this is what
  /// the ring should show. `0.0` → empty; `1.0` → compaction imminent;
  /// `> 1.0` → overdue (daemon should have compacted by now; clamp in
  /// the UI). We expose both `pressure` (raw) for the detail panel
  /// and `displayPressure` (threshold-relative) for the ring.
  double get displayPressure {
    if (threshold <= 0) return pressure;
    return pressure / threshold;
  }

  String get displayPressurePercent =>
      '${(displayPressure * 100).round()}%';

  /// Source flags that relax the monotonic guard:
  ///
  ///   * [afterCompaction] — set when the daemon just emitted
  ///     `hook/compact_context:end`. Compaction payloads carry
  ///     `pressure` but not `compactions`, so the guard would
  ///     otherwise reject the legitimate drop.
  ///
  ///   * [authoritative] — set when the payload comes from a
  ///     `result.context` / `turn_complete.context` envelope. The
  ///     scout confirmed these carry the stable post-turn aggregate
  ///     (system + tools + persisted history) while mid-turn
  ///     `hook/context_status` events oscillate wildly (0.144 →
  ///     0.018 → 0.440 → 0.634 → 0.019 within a single turn,
  ///     depending on whether a tool result is momentarily in the
  ///     working window). Adopting `result.context` unconditionally
  ///     fixes the "ring stuck at 40 % after turn complete" bug.
  void updateFromJson(Map<String, dynamic> ctx,
      {bool afterCompaction = false, bool authoritative = false}) {
    // ── Guard 1 — zero-out payloads ──────────────────────────────
    // Two flavours of "blank" payloads the daemon occasionally ships:
    //   (a) `effective_max: 0` — a usage/tool envelope with no
    //       capacity data; adopting it would wipe the ring baseline.
    //   (b) `total_estimated_tokens: 0` AND `pressure: 0` — the
    //       pressure scout caught result.context envelopes filled
    //       entirely with zeros ("pressure=0, est=0, system=0,
    //       tools=0, history=0"), shipped even when a hook just said
    //       `estimated_tokens=3174`. Those are the daemon's
    //       uninitialised baseline leaking through; we must keep our
    //       existing pressure state instead of zero-ing the ring.
    //
    // In both cases, if we already have ANY populated state, skip
    // the whole update. Fresh sessions (zero state) fall through so
    // the initial baseline can land.
    final incomingMax = (ctx['effective_max'] as num?)?.toInt();
    final incomingTotal =
        (ctx['total_estimated_tokens'] as num?)?.toInt();
    final incomingPressureProbe = (ctx['pressure'] as num?)?.toDouble();
    final blanksOutMax =
        incomingMax != null && incomingMax == 0;
    final fullyBlankBucket = (incomingTotal == null || incomingTotal == 0)
        && (incomingPressureProbe == null || incomingPressureProbe == 0)
        && ((ctx['message_history_tokens'] as num?)?.toInt() ?? 0) == 0
        && ((ctx['system_prompt_tokens'] as num?)?.toInt() ?? 0) == 0;
    final haveAnyState = effectiveMax > 0
        || totalEstimatedTokens > 0
        || pressure > 0;
    if ((blanksOutMax || fullyBlankBucket) && haveAnyState) {
      return;
    }

    // ── Guard 2 — monotonic pressure invariant ────────────────────
    // Pressure can only DECREASE when a compaction just fired.
    // Otherwise a drop is a stale snapshot (per-turn telemetry, a
    // race between `turn_complete` and `context_status`, a partial
    // usage block…) and would make the ring flicker downwards —
    // confusing the user since no compaction message lands with it.
    //
    // Detection: either (a) incoming `compactions` is strictly
    // larger than ours, or (b) the caller flagged [afterCompaction]
    // because it just processed a `compact_context:end` hook.
    final incomingPressure = (ctx['pressure'] as num?)?.toDouble();
    final incomingCompactions = (ctx['compactions'] as num?)?.toInt();
    final compactionHappened = afterCompaction ||
        (incomingCompactions != null &&
            incomingCompactions > compactions);
    // `authoritative` skips the guard — the caller has identified
    // the payload as a stable post-turn aggregate (result.context).
    if (!authoritative && !compactionHappened && effectiveMax > 0) {
      if (incomingPressure != null &&
          pressure > 0 &&
          incomingPressure < pressure - 0.005) {
        return;
      }
      if (incomingTotal != null &&
          totalEstimatedTokens > 0 &&
          incomingTotal < totalEstimatedTokens) {
        return;
      }
    }

    // Two shapes coexist on the wire:
    //   * Full breakdown — sent with `result.context` at turn end.
    //     Carries system_prompt_tokens, tools_schema_tokens, etc.
    //   * Flat hook — `hook/context_status` `details`: only
    //     `pressure`, `estimated_tokens`, `max_tokens`, `threshold`,
    //     `messages`. No per-bucket breakdown.
    //
    // We accept both. `estimated_tokens` from the hook fills in for
    // `total_estimated_tokens` when the latter isn't present so the
    // ring's percentage label stays accurate between turns.
    maxTokens = ctx['max_tokens'] as int? ?? maxTokens;
    outputReserved = ctx['output_reserved'] as int? ?? outputReserved;
    effectiveMax = ctx['effective_max'] as int? ?? effectiveMax;
    systemPromptTokens = ctx['system_prompt_tokens'] as int? ?? systemPromptTokens;
    systemPromptPct = (ctx['system_prompt_pct'] as num?)?.toDouble() ?? systemPromptPct;
    toolsSchemaTokens = ctx['tools_schema_tokens'] as int? ?? toolsSchemaTokens;
    toolsSchemaPct = (ctx['tools_schema_pct'] as num?)?.toDouble() ?? toolsSchemaPct;
    messageHistoryTokens = ctx['message_history_tokens'] as int? ?? messageHistoryTokens;
    messageHistoryPct = (ctx['message_history_pct'] as num?)?.toDouble() ?? messageHistoryPct;
    totalEstimatedTokens = ctx['total_estimated_tokens'] as int?
        ?? ctx['estimated_tokens'] as int?
        ?? (ctx['tokens_after'] as int?)
        ?? totalEstimatedTokens;
    pressure = (ctx['pressure'] as num?)?.toDouble() ?? pressure;
    availableTokens = ctx['available_tokens'] as int? ?? availableTokens;
    // `threshold` comes from the app's YAML; hook/context_status
    // always carries it, result.context never does (confirmed by the
    // pressure scout). We persist whatever lands and keep the last
    // known value otherwise — the threshold doesn't change within a
    // session.
    threshold = (ctx['threshold'] as num?)?.toDouble() ?? threshold;
    // Accept an explicit counter if present; otherwise bump it
    // ourselves when the caller flagged a compaction. Ensures the
    // next regular context_status can still drop pressure below
    // this new baseline.
    final explicitCompactions = ctx['compactions'] as int?;
    if (explicitCompactions != null) {
      compactions = explicitCompactions;
    } else if (afterCompaction) {
      compactions += 1;
    }
    notifyListeners();
  }

  /// Reset session-specific fields only.
  /// Keeps app-level fields (maxTokens, effectiveMax, outputReserved,
  /// systemPromptTokens, toolsSchemaTokens) intact across session switches.
  void reset() {
    messageHistoryTokens = 0;
    messageHistoryPct = 0;
    totalEstimatedTokens = systemPromptTokens + toolsSchemaTokens;
    pressure = effectiveMax > 0 ? totalEstimatedTokens / effectiveMax : 0;
    availableTokens = effectiveMax - totalEstimatedTokens;
    compactions = 0;
    notifyListeners();
  }

  /// Full reset — clears everything including app-level fields.
  /// Use when switching apps, not when switching sessions.
  void fullReset() {
    maxTokens = 0;
    outputReserved = 0;
    effectiveMax = 0;
    systemPromptTokens = 0;
    systemPromptPct = 0;
    toolsSchemaTokens = 0;
    toolsSchemaPct = 0;
    messageHistoryTokens = 0;
    messageHistoryPct = 0;
    totalEstimatedTokens = 0;
    pressure = 0;
    availableTokens = 0;
    compactions = 0;
    notifyListeners();
  }

  bool get hasData => effectiveMax > 0;
  String get pressurePercent => '${(pressure * 100).toStringAsFixed(1)}%';

  String fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return n.toString();
  }
}
