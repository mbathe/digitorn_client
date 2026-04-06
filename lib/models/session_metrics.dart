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

  /// Start polling session metrics every 3 seconds
  void startPolling(String appId, String sessionId) {
    _appId = appId;
    _sessionId = sessionId;
    _pollTimer?.cancel();
    fetch(); // immediate first fetch
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) => fetch());
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
      if (ctx != null) updateContext(ctx);

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
