import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../models/chat_message.dart';
import '../models/app_summary.dart';
import 'auth_service.dart';

class DigitornApiClient {
  static final DigitornApiClient _instance = DigitornApiClient._internal();
  factory DigitornApiClient() => _instance;

  DigitornApiClient._internal();

  late Dio _dio = _buildDio('http://127.0.0.1:8000');
  String? _token;

  String appId = "code-assistant";
  String sessionId = "default-session";

  Dio _buildDio(String baseUrl) => Dio(BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(hours: 1),
      ))..interceptors.add(AuthService().authInterceptor);

  // ─── Auth ─────────────────────────────────────────────────────────────────

  void updateBaseUrl(String baseUrl, {String? token}) {
    _dio = _buildDio(baseUrl);
    _token = token;
  }

  Options get _authOptions => Options(
    headers: {
      'Accept': 'application/json',
      if (_token != null) 'Authorization': 'Bearer $_token',
    },
  );

  Options get _streamOptions => Options(
    responseType: ResponseType.stream,
    headers: {
      'Accept': 'text/event-stream',
      if (_token != null) 'Authorization': 'Bearer $_token',
    },
  );

  // ─── Apps ─────────────────────────────────────────────────────────────────

  Future<List<AppSummary>> fetchApps() async {
    try {
      debugPrint('fetchApps → GET ${_dio.options.baseUrl}/api/apps');
      final response = await _dio.get('/api/apps', options: Options(
        headers: {'Accept': 'application/json'},
        validateStatus: (s) => s != null && s < 500,
      ));
      debugPrint('fetchApps ← ${response.statusCode} data=${response.data}');
      if (response.data != null && response.data['success'] == true) {
        final List list = response.data['data'] ?? [];
        debugPrint('fetchApps: ${list.length} apps found');
        return list.map((json) => AppSummary.fromJson(json)).toList();
      }
      return [];
    } catch (e) {
      debugPrint('fetchApps error: $e');
      return [];
    }
  }

  // ─── Legacy /chat/stream (kept for fallback) ───────────────────────────────

  Future<void> sendChatMessageStream({
    required String sessionId,
    required String message,
    required ChatMessage assistantMessageRef,
    required Function onFinished,
    required Function(String) onError,
    String? workspace,
    Function(String type, Map<String, dynamic> data)? onRawEvent,
  }) async {
    try {
      assistantMessageRef.setStreamingState(true);

      final url = '/api/apps/$appId/chat/stream';
      final body = {
        "session_id": sessionId,
        "message": message,
        if (workspace != null && workspace.isNotEmpty) "workspace": workspace,
      };
      debugPrint('chat/stream → POST ${_dio.options.baseUrl}$url body=$body');

      final response = await _dio.post<ResponseBody>(
        url,
        data: body,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            'Accept': 'text/event-stream',
            'Content-Type': 'application/json',
            if (_token != null) 'Authorization': 'Bearer $_token',
          },
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      if (response.statusCode != 200) {
        debugPrint('chat/stream ← ${response.statusCode}');
        onError('Server returned ${response.statusCode}. The agent may still be processing the previous message.');
        return;
      }

      String currentEventType = "";
      String dataBuffer = "";

      debugPrint('chat/stream: response ${response.statusCode}, starting stream listen...');

      response.data?.stream
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (String line) {
          debugPrint('SSE line: $line');
          if (line.startsWith('event: ')) {
            currentEventType = line.substring(7).trim();
          } else if (line.startsWith('data: ')) {
            dataBuffer = line.substring(6).trim();
          } else if (line.isEmpty && currentEventType.isNotEmpty && dataBuffer.isNotEmpty) {
            if (dataBuffer == "[DONE]") {
              currentEventType = "";
              dataBuffer = "";
              return;
            }
            try {
              final Map<String, dynamic> data = jsonDecode(dataBuffer);
              debugPrint('SSE event: $currentEventType');
              onRawEvent?.call(currentEventType, data);
              handleStreamEvent(currentEventType, data, assistantMessageRef);
            } catch (e) {
              debugPrint('SSE parse error: $e');
            }
            currentEventType = "";
            dataBuffer = "";
          }
        },
        onDone: () {
          debugPrint('SSE stream done');
          assistantMessageRef.setStreamingState(false);
          onFinished();
        },
        onError: (e) {
          debugPrint('SSE stream error: $e');
          assistantMessageRef.setStreamingState(false);
          onError("Stream error: $e");
        },
      );
    } catch (e) {
      assistantMessageRef.setStreamingState(false);
      onError("Request error: $e");
    }
  }

  // ─── Event Handler (shared between /chat/stream and /sessions SSE) ─────────

  void handleStreamEvent(String event, Map<String, dynamic> data, ChatMessage msg) {
    switch (event) {
      // ── Text tokens ──────────────────────────────────────────────────────
      case 'token':
      case 'out_token' when data.containsKey('delta'):
        final delta = data['delta'] as String? ?? '';
        if (delta.isNotEmpty) msg.appendText(delta);
        break;

      // ── Thinking ─────────────────────────────────────────────────────────
      case 'thinking_started':
        msg.setThinkingState(true);
        break;
      case 'thinking_delta':
        final delta = data['delta'] as String? ?? '';
        if (delta.isNotEmpty) msg.appendThinking(delta);
        break;
      case 'thinking':
        // batch — full thinking text at once
        final text = data['text'] as String? ?? '';
        if (text.isNotEmpty) msg.setThinkingText(text);
        break;
      case 'stream_done':
        msg.setThinkingState(false);
        break;

      // ── Tool calls ────────────────────────────────────────────────────────
      case 'tool_start':
        final id = data['id'] as String? ?? data['name'] as String? ?? 'tool';
        // Label/detail: try display.verb first, then root label, then name
        final display = data['display'] as Map<String, dynamic>?;
        final label = display?['verb'] as String? ??
            data['label'] as String? ?? '';
        final detail = display?['detail'] as String? ??
            data['detail'] as String? ?? '';
        msg.addOrUpdateToolCall(ToolCall(
          id: id,
          name: data['name'] as String? ?? 'tool',
          label: label,
          detail: detail,
          params: Map<String, dynamic>.from(data['params'] ?? {}),
          status: 'started',
        ));
        break;
      case 'tool_call':
        final id = data['id'] as String? ?? data['name'] as String? ?? 'tool';
        final name = data['name'] as String? ?? 'tool';
        final success = data['success'] ?? true;
        final display = data['display'] as Map<String, dynamic>?;
        final label = display?['verb'] as String? ??
            data['label'] as String? ?? '';
        final detail = display?['detail'] as String? ??
            data['detail'] as String? ?? '';
        msg.addOrUpdateToolCall(ToolCall(
          id: id,
          name: name,
          label: label,
          detail: detail,
          params: Map<String, dynamic>.from(data['params'] ?? {}),
          status: success == true ? 'completed' : 'failed',
          result: data['result'],
          error: data['error'] as String?,
        ));
        break;

      // ── Turn result ───────────────────────────────────────────────────────
      case 'result':
        msg.setStreamingState(false);
        msg.setThinkingState(false);
        // Persist token usage from result payload
        final usage = data['usage'] as Map<String, dynamic>?;
        if (usage != null) {
          msg.addTokens(
            out: usage['output_tokens'] as int? ?? 0,
            inT: usage['input_tokens'] as int? ?? 0,
          );
        }
        break;

      // ── Token counts ─────────────────────────────────────────────────────
      case 'out_token':
        final count = data['count'] as int? ?? 0;
        if (count > 0) msg.addTokens(out: count);
        break;
      case 'in_token':
        final count = data['count'] as int? ?? 0;
        if (count > 0) msg.addTokens(inT: count);
        break;

      // ── Status phase ───────────────────────────────────────────────────
      case 'status':
      case 'stream_done':
        // Handled by ChatPanel via onStatusPhase callback
        break;

      // ── Agent events ──────────────────────────────────────────────────────
      case 'agent_event':
        final agentId = data['agent_id'] as String? ?? '';
        if (agentId.isNotEmpty) {
          msg.addAgentEvent(AgentEventData(
            agentId: agentId,
            status: data['status'] as String? ?? 'unknown',
            specialist: data['specialist'] as String? ?? '',
            task: data['task'] as String? ?? '',
            duration: (data['duration_seconds'] as num?)?.toDouble() ?? 0,
            preview: data['preview'] as String? ?? '',
          ));
        }
        break;

      // ── Hook events ───────────────────────────────────────────────────────
      case 'hook':
        msg.addHookEvent(HookEventData(
          hookId: data['hook_id'] as String? ?? '',
          actionType: data['action_type'] as String? ?? '',
          phase: data['phase'] as String? ?? '',
          details: Map<String, dynamic>.from(data['details'] ?? {}),
        ));
        break;

      // ── Memory update — show as system info in tool pills ─────────────────
      case 'memory_update':
        final action = data['action'] as String? ?? 'memory';
        msg.addOrUpdateToolCall(ToolCall(
          id: 'memory_$action',
          name: 'memory.$action',
          params: {},
          status: 'completed',
          result: data['result'],
        ));
        break;

      // ── Approval request — handled by ChatPanel directly ──────────────────
      case 'approval_request':
        // Delegated to ChatPanel._handleSessionEvent
        break;

      case 'error':
        msg.appendText('\n\n**Error:** ${data['error'] ?? 'Unknown error'}');
        msg.setStreamingState(false);
        break;
    }
  }
}
