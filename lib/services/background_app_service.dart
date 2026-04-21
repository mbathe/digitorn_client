import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'auth_service.dart';
import 'payload_schema.dart';

export 'payload_schema.dart';

// ─── Models ─────────────────────────────────────────────────────────────────

/// Logical category of a trigger from the perspective of the user
/// configuring the session payload.
///
/// - **scheduled** — fires without external input (cron, watch, rss,
///   queue). The user MUST supply a payload (prompt + optional files)
///   otherwise the agent has nothing to do at each tick.
/// - **conversational** — fires because a real human (or system) sent
///   a message (telegram, discord, slack, email, webhook, voice, http).
///   The payload is optional and acts as permanent context that is
///   appended to every received message.
/// - **system** — internal plumbing trigger that doesn't need a
///   payload (log).
/// - **unknown** — type not recognised; treated as conversational by
///   default so we don't accidentally hide the page.
enum TriggerKind { scheduled, conversational, system, unknown }

/// Aggregated payload-relevance of an entire app, derived from the
/// kinds of its triggers. Drives the label / wording / required-state
/// of the session payload page.
enum SessionPayloadMode {
  /// Every trigger is scheduled — the user MUST configure a payload.
  required,
  /// At least one scheduled trigger exists alongside conversational
  /// ones. Payload is recommended but the conversational triggers will
  /// keep working even if it stays empty.
  recommended,
  /// Only conversational triggers — payload is optional, used only for
  /// permanent preferences ("answer in French", etc).
  optional,
  /// No payload-relevant triggers — hide the page entirely.
  hidden,
}

class Trigger {
  final String id;
  final String type; // cron, http, file_watch, telegram, …
  final String? schedule; // cron expression
  final String? path; // http path or file path
  final String? method; // http method
  final String routing; // broadcast, user, round_robin
  final String? routingKey;

  const Trigger({
    required this.id,
    required this.type,
    this.schedule,
    this.path,
    this.method,
    this.routing = 'broadcast',
    this.routingKey,
  });

  factory Trigger.fromJson(Map<String, dynamic> j) => Trigger(
    id: j['id'] as String? ?? '',
    type: j['type'] as String? ?? '',
    schedule: j['schedule'] as String?,
    path: j['path'] as String?,
    method: j['method'] as String?,
    routing: j['routing'] as String? ?? 'broadcast',
    routingKey: j['routing_key'] as String?,
  );

  String get displayType => switch (type) {
        'cron' => 'Cron',
        'http' => 'HTTP',
        'file_watch' || 'watch' => 'File Watch',
        'rss' => 'RSS',
        'webhook' => 'Webhook',
        'telegram' => 'Telegram',
        'discord' => 'Discord',
        'slack' => 'Slack',
        'email' => 'Email',
        'voice' => 'Voice',
        'queue' => 'Queue',
        'log' => 'Log',
        _ => type,
      };

  String get displaySchedule {
    if (schedule != null) return schedule!;
    if (path != null) return '${method ?? 'POST'} $path';
    return '';
  }

  /// Logical classification used by the payload UI.
  TriggerKind get kind {
    switch (type) {
      case 'cron':
      case 'watch':
      case 'file_watch':
      case 'rss':
      case 'queue':
        return TriggerKind.scheduled;
      case 'telegram':
      case 'discord':
      case 'slack':
      case 'email':
      case 'webhook':
      case 'voice':
      case 'http':
        return TriggerKind.conversational;
      case 'log':
        return TriggerKind.system;
      default:
        return TriggerKind.unknown;
    }
  }
}

/// Compute the [SessionPayloadMode] for a list of triggers — used by
/// the dashboard to decide whether to show / how to label the
/// "Session payload" affordance on a session card.
SessionPayloadMode computeSessionPayloadMode(List<Trigger> triggers) {
  if (triggers.isEmpty) return SessionPayloadMode.hidden;

  var hasScheduled = false;
  var hasConversational = false;
  for (final t in triggers) {
    final k = t.kind;
    if (k == TriggerKind.scheduled) hasScheduled = true;
    if (k == TriggerKind.conversational || k == TriggerKind.unknown) {
      hasConversational = true;
    }
  }

  if (hasScheduled && hasConversational) return SessionPayloadMode.recommended;
  if (hasScheduled) return SessionPayloadMode.required;
  if (hasConversational) return SessionPayloadMode.optional;
  return SessionPayloadMode.hidden;
}

class Channel {
  final String name;
  final String type; // slack, telegram, email, webhook, log
  final bool inbound;
  final bool outbound;
  final String status; // connected, disconnected, error
  final int eventsReceived;
  final DateTime? lastEventAt;

  const Channel({
    required this.name,
    required this.type,
    this.inbound = false,
    this.outbound = false,
    this.status = 'disconnected',
    this.eventsReceived = 0,
    this.lastEventAt,
  });

  factory Channel.fromJson(Map<String, dynamic> j) => Channel(
    name: j['name'] as String? ?? '',
    type: j['type'] as String? ?? '',
    inbound: j['inbound'] as bool? ?? false,
    outbound: j['outbound'] as bool? ?? false,
    status: j['status'] as String? ?? 'disconnected',
    eventsReceived: j['events_received'] as int? ?? 0,
    lastEventAt: j['last_event_at'] != null
        ? DateTime.tryParse(j['last_event_at'] as String? ?? '')
        : null,
  );

  String get direction {
    if (inbound && outbound) return 'bidirectional';
    if (inbound) return 'inbound';
    if (outbound) return 'outbound';
    return '';
  }
}

class BackgroundSession {
  final String id;
  final String appId;
  final String userId;
  final String name;
  final String status; // active, paused, stopped
  final Map<String, dynamic> params;
  final Map<String, dynamic> routingKeys;
  final String workspace;
  final DateTime? createdAt;
  final DateTime? lastActiveAt;
  final int activationCount;

  const BackgroundSession({
    required this.id,
    this.appId = '',
    this.userId = '',
    required this.name,
    this.status = 'active',
    this.params = const {},
    this.routingKeys = const {},
    this.workspace = '',
    this.createdAt,
    this.lastActiveAt,
    this.activationCount = 0,
  });

  factory BackgroundSession.fromJson(Map<String, dynamic> j) => BackgroundSession(
    id: j['id'] as String? ?? j['session_id'] as String? ?? '',
    appId: j['app_id'] as String? ?? '',
    userId: j['user_id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    status: j['status'] as String? ?? 'active',
    params: Map<String, dynamic>.from(j['params'] ?? {}),
    routingKeys: Map<String, dynamic>.from(j['routing_keys'] ?? {}),
    workspace: j['workspace'] as String? ?? '',
    createdAt: _parseDate(j['created_at']),
    lastActiveAt: _parseDate(j['last_active_at']),
    activationCount: j['activation_count'] as int? ?? 0,
  );

  bool get isActive => status == 'active';
  bool get isPaused => status == 'paused';

  String get timeAgo {
    final dt = lastActiveAt ?? createdAt;
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 30) return '${diff.inDays}d ago';
    return '${(diff.inDays / 30).floor()}mo ago';
  }
}

class Activation {
  final String id;
  final String triggerId;
  final String triggerType;
  final String status; // running, completed, failed
  final String sessionId;
  final String userId;
  final String message;
  final String response;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final double durationMs;
  final int toolCallsCount;
  final int turnsUsed;
  final int promptTokens;
  final int completionTokens;
  final String? error;

  const Activation({
    required this.id,
    this.triggerId = '',
    this.triggerType = '',
    this.status = 'completed',
    this.sessionId = '',
    this.userId = '',
    this.message = '',
    this.response = '',
    this.startedAt,
    this.completedAt,
    this.durationMs = 0,
    this.toolCallsCount = 0,
    this.turnsUsed = 0,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.error,
  });

  factory Activation.fromJson(Map<String, dynamic> j) => Activation(
    id: j['id'] as String? ?? '',
    triggerId: j['trigger_id'] as String? ?? '',
    triggerType: j['trigger_type'] as String? ?? '',
    status: j['status'] as String? ?? 'completed',
    sessionId: j['session_id'] as String? ?? '',
    userId: j['user_id'] as String? ?? '',
    message: j['message'] as String? ?? '',
    response: j['response'] as String? ?? '',
    startedAt: _parseDate(j['started_at']),
    completedAt: _parseDate(j['completed_at']),
    durationMs: (j['duration_ms'] as num?)?.toDouble() ?? 0,
    toolCallsCount: j['tool_calls_count'] as int? ?? 0,
    turnsUsed: j['turns_used'] as int? ?? 0,
    promptTokens: j['prompt_tokens'] as int? ?? 0,
    completionTokens: j['completion_tokens'] as int? ?? 0,
    error: j['error'] as String?,
  );

  bool get isRunning => status == 'running';
  bool get isFailed => status == 'failed';
  bool get isCompleted => status == 'completed';
  int get totalTokens => promptTokens + completionTokens;

  String get durationDisplay {
    if (durationMs < 1000) return '${durationMs.round()}ms';
    if (durationMs < 60000) return '${(durationMs / 1000).toStringAsFixed(1)}s';
    return '${(durationMs / 60000).toStringAsFixed(1)}m';
  }

  String get timeDisplay {
    final dt = startedAt;
    if (dt == null) return '';
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${dt.month}/${dt.day} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

class ActivationStats {
  final int total;
  final int completed;
  final int failed;
  final double totalDurationMs;
  final double avgDurationMs;
  final int totalPromptTokens;
  final int totalCompletionTokens;
  final int totalToolCalls;
  final DateTime? lastActivationAt;
  final double successRate;

  const ActivationStats({
    this.total = 0,
    this.completed = 0,
    this.failed = 0,
    this.totalDurationMs = 0,
    this.avgDurationMs = 0,
    this.totalPromptTokens = 0,
    this.totalCompletionTokens = 0,
    this.totalToolCalls = 0,
    this.lastActivationAt,
    this.successRate = 0,
  });

  factory ActivationStats.fromJson(Map<String, dynamic> j) => ActivationStats(
    total: j['total'] as int? ?? 0,
    completed: j['completed'] as int? ?? 0,
    failed: j['failed'] as int? ?? 0,
    totalDurationMs: (j['total_duration_ms'] as num?)?.toDouble() ?? 0,
    avgDurationMs: (j['avg_duration_ms'] as num?)?.toDouble() ?? 0,
    totalPromptTokens: j['total_prompt_tokens'] as int? ?? 0,
    totalCompletionTokens: j['total_completion_tokens'] as int? ?? 0,
    totalToolCalls: j['total_tool_calls'] as int? ?? 0,
    lastActivationAt: _parseDate(j['last_activation_at']),
    successRate: (j['success_rate'] as num?)?.toDouble() ?? 0,
  );

  int get totalTokens => totalPromptTokens + totalCompletionTokens;
  int get running => total - completed - failed;
}

class AppTriggerInfo {
  final String appId;
  final String mode;
  final bool isBackground;
  final List<Trigger> triggers;
  final List<Channel> channels;

  const AppTriggerInfo({
    required this.appId,
    this.mode = '',
    this.isBackground = false,
    this.triggers = const [],
    this.channels = const [],
  });

  factory AppTriggerInfo.fromJson(Map<String, dynamic> j) => AppTriggerInfo(
    appId: j['app_id'] as String? ?? '',
    mode: j['mode'] as String? ?? '',
    isBackground: j['is_background'] as bool? ?? false,
    triggers: (j['triggers'] as List?)
        ?.map((t) => Trigger.fromJson(t as Map<String, dynamic>))
        .toList() ?? [],
    channels: (j['channels'] as List?)
        ?.map((c) => Channel.fromJson(c as Map<String, dynamic>))
        .toList() ?? [],
  );
}

// ─── v2 models (status, channel health, events, artifacts) ────────────────

/// Live snapshot of a background app — runtime state plus a 24h
/// activity series suitable for a sparkline. Matches
/// GET /api/apps/{id}/status.
class AppStatus {
  /// `running` when the app is currently mid-activation,
  /// `idle` when it's registered but quiet,
  /// `error` when the most recent activation failed,
  /// `disabled` when pausing/disconnected.
  final String state;

  /// When the most recent activation *started*.
  final DateTime? lastRunAt;

  /// Human text describing the next scheduled event, e.g.
  /// `"in 4 minutes"` or `"waiting for webhook"`.
  final String? nextRun;

  /// Hourly buckets of activation counts, 24 entries newest-last.
  /// Empty when the daemon hasn't aggregated enough data yet.
  final List<int> runs24h;

  /// Percentage change vs the same hour yesterday, e.g. `12.0` for
  /// +12% (up) or `-8.4` for -8.4% (down). `null` = unknown.
  final double? trendPct;

  final ActivationStats? stats;

  const AppStatus({
    this.state = 'idle',
    this.lastRunAt,
    this.nextRun,
    this.runs24h = const [],
    this.trendPct,
    this.stats,
  });

  factory AppStatus.fromJson(Map<String, dynamic> j) => AppStatus(
    state: j['state'] as String? ?? j['current_state'] as String? ?? 'idle',
    lastRunAt: _parseDate(j['last_run_at']),
    nextRun: j['next_run'] as String?,
    runs24h: (j['runs_24h'] as List?)?.map((e) => (e as num).toInt()).toList()
        ?? const [],
    trendPct: (j['trend_pct'] as num?)?.toDouble(),
    stats: j['stats'] is Map<String, dynamic>
        ? ActivationStats.fromJson(j['stats'] as Map<String, dynamic>)
        : null,
  );

  bool get isRunning => state == 'running';
  bool get isError => state == 'error';
  bool get isIdle => state == 'idle';
}

/// Live health info for one channel (slack, email, webhook, …).
/// Matches one entry in GET /api/apps/{id}/channels/health.
class ChannelHealth {
  final String name;
  final String type;
  /// `connected` / `degraded` / `error` / `disconnected`.
  final String status;
  final int sent;
  final int failed;
  final DateTime? lastSentAt;
  final String? lastError;
  /// Free-form identifier to display under the name, e.g. email
  /// address, webhook URL, channel id.
  final String? target;

  const ChannelHealth({
    required this.name,
    required this.type,
    this.status = 'disconnected',
    this.sent = 0,
    this.failed = 0,
    this.lastSentAt,
    this.lastError,
    this.target,
  });

  factory ChannelHealth.fromJson(Map<String, dynamic> j) => ChannelHealth(
    name: j['name'] as String? ?? '',
    type: j['type'] as String? ?? '',
    status: j['status'] as String? ?? 'disconnected',
    sent: (j['sent'] as num?)?.toInt() ?? 0,
    failed: (j['failed'] as num?)?.toInt() ?? 0,
    lastSentAt: _parseDate(j['last_sent_at']),
    lastError: j['last_error'] as String?,
    target: j['target'] as String? ??
        j['address'] as String? ??
        j['endpoint'] as String?,
  );

  bool get isHealthy => status == 'connected';
  bool get hasError => status == 'error' || lastError != null;
}

/// A single event in an activation's timeline. `eventType` is the
/// discriminator — typical values: `trigger`, `agent_start`, `agent_end`,
/// `tool_call`, `thinking`, `artifact`, `channel_send`, `error`.
class ActivationEvent {
  /// Stable id — used as the event_id for artifact downloads when
  /// `eventType == 'artifact'`.
  final String id;
  /// Monotonic order inside the activation.
  final int sequence;
  final DateTime timestamp;
  final String eventType;
  /// Full raw payload for type-specific renderers.
  final Map<String, dynamic> data;

  const ActivationEvent({
    required this.id,
    required this.sequence,
    required this.timestamp,
    required this.eventType,
    required this.data,
  });

  factory ActivationEvent.fromJson(Map<String, dynamic> j) => ActivationEvent(
    id: j['id'] as String? ?? '',
    sequence: (j['sequence'] as num?)?.toInt() ?? 0,
    timestamp: _parseDate(j['timestamp']) ?? DateTime.now(),
    eventType: j['event_type'] as String? ?? 'unknown',
    data: j['data'] is Map
        ? (j['data'] as Map).cast<String, dynamic>()
        : const {},
  );

  // Convenience accessors for common payload shapes.
  String? get toolName => data['tool_name'] as String? ?? data['name'] as String?;
  String? get text => data['text'] as String? ?? data['message'] as String?;
  String? get channelType => data['channel_type'] as String? ?? data['type'] as String?;
  String? get channelTarget =>
      data['target'] as String? ?? data['address'] as String?;
}

/// A file generated during an activation. Derived from the
/// `artifact`-type events returned by
/// GET /api/apps/{id}/activations/{aid}/events?event_type=artifact.
class ActivationArtifact {
  /// Stable event id — pass this to [BackgroundAppService.downloadArtifact].
  final String eventId;
  final int sequence;
  final DateTime timestamp;
  final String path;
  /// The tool name that produced the file (e.g. `filesystem.write`).
  final String action;
  final int? sizeBytes;

  const ActivationArtifact({
    required this.eventId,
    required this.sequence,
    required this.timestamp,
    required this.path,
    required this.action,
    this.sizeBytes,
  });

  factory ActivationArtifact.fromEvent(Map<String, dynamic> j) {
    final data = (j['data'] is Map ? j['data'] as Map : const {})
        .cast<String, dynamic>();
    return ActivationArtifact(
      eventId: j['id'] as String? ?? '',
      sequence: (j['sequence'] as num?)?.toInt() ?? 0,
      timestamp: _parseDate(j['timestamp']) ?? DateTime.now(),
      path: data['path'] as String? ?? '',
      action: data['action'] as String? ?? '',
      sizeBytes: (data['size_bytes'] as num?)?.toInt() ??
          (data['size'] as num?)?.toInt(),
    );
  }

  String get filename {
    final p = path.replaceAll('\\', '/');
    final i = p.lastIndexOf('/');
    return i >= 0 ? p.substring(i + 1) : p;
  }

  String get extension {
    final i = filename.lastIndexOf('.');
    return i == -1 ? '' : filename.substring(i + 1).toLowerCase();
  }

  String get sizeDisplay {
    final s = sizeBytes;
    if (s == null) return '—';
    if (s < 1024) return '$s B';
    if (s < 1024 * 1024) return '${(s / 1024).toStringAsFixed(1)} KB';
    return '${(s / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// Result of [BackgroundAppService.downloadArtifact] — raw bytes plus
/// the metadata we need to pick a viewer.
class ArtifactDownload {
  final Uint8List bytes;
  final String contentType;
  final String filename;

  const ArtifactDownload({
    required this.bytes,
    required this.contentType,
    required this.filename,
  });
}

// ─── Session Payload (background app input) ───────────────────────────────

/// One file attached to a background session's payload. The daemon
/// stores the bytes on disk and re-injects them into the agent's
/// input at every trigger fire. The client only ever sees the
/// metadata — `path` lives server-side only and is intentionally
/// omitted here.
class PayloadFile {
  final String name;
  final String mimeType;
  final int sizeBytes;

  const PayloadFile({
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
  });

  factory PayloadFile.fromJson(Map<String, dynamic> j) => PayloadFile(
        name: j['name'] as String? ?? '',
        mimeType:
            j['mime_type'] as String? ?? 'application/octet-stream',
        sizeBytes: (j['size_bytes'] as num?)?.toInt() ?? 0,
      );

  String get sizeDisplay {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  String get extension {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1).toLowerCase();
  }

  /// Broad category from [mimeType] — used to pick an icon / label.
  String get category {
    final mt = mimeType.toLowerCase();
    if (mt.startsWith('image/')) return 'image';
    if (mt == 'application/pdf') return 'pdf';
    if (mt.contains('json')) return 'json';
    if (mt.contains('yaml')) return 'yaml';
    if (mt.contains('csv')) return 'csv';
    if (mt.startsWith('text/')) return 'text';
    if (mt.contains('zip')) return 'zip';
    return 'binary';
  }
}

/// Snapshot of everything a background session will feed to its agent
/// at every tick: a prompt (free-text instruction), a metadata bag of
/// structured preferences, a list of attached files, and — when the
/// app declares a schema — a server-side validation block the client
/// uses to enable/disable the Activate button.
///
/// Produced by / round-tripped through
/// `GET/PUT /api/apps/{id}/background-sessions/{sid}/payload`.
class SessionPayload {
  final String prompt;
  final Map<String, dynamic> metadata;
  final List<PayloadFile> files;
  final PayloadValidation validation;

  const SessionPayload({
    this.prompt = '',
    this.metadata = const {},
    this.files = const [],
    this.validation = PayloadValidation.empty,
  });

  static const empty = SessionPayload();

  factory SessionPayload.fromJson(Map<String, dynamic> j) {
    final v = j['validation'];
    return SessionPayload(
      prompt: j['prompt'] as String? ?? '',
      metadata: j['metadata'] is Map
          ? Map<String, dynamic>.from(j['metadata'] as Map)
          : const {},
      files: (j['files'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PayloadFile.fromJson)
          .toList(),
      validation: v is Map
          ? PayloadValidation.fromJson(v.cast<String, dynamic>())
          : PayloadValidation.empty,
    );
  }

  bool get isEmpty =>
      prompt.isEmpty && metadata.isEmpty && files.isEmpty;

  SessionPayload copyWith({
    String? prompt,
    Map<String, dynamic>? metadata,
    List<PayloadFile>? files,
    PayloadValidation? validation,
  }) =>
      SessionPayload(
        prompt: prompt ?? this.prompt,
        metadata: metadata ?? this.metadata,
        files: files ?? this.files,
        validation: validation ?? this.validation,
      );
}

// ─── Service ────────────────────────────────────────────────────────────────

class BackgroundAppService extends ChangeNotifier {
  static final BackgroundAppService _i = BackgroundAppService._();
  factory BackgroundAppService() => _i;
  BackgroundAppService._();

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 60),
    validateStatus: (s) => s != null && s < 500 && s != 401,
  ))..interceptors.add(AuthService().authInterceptor);

  String get _base => AuthService().baseUrl;

  // ── Cached state ──────────────────────────────────────────────────────────

  AppTriggerInfo? triggerInfo;
  List<BackgroundSession> sessions = [];
  List<Activation> activations = [];
  ActivationStats? stats;
  bool isLoading = false;

  // v2 caches
  AppStatus? status;
  List<ChannelHealth> channelsHealth = [];

  // ── Triggers ──────────────────────────────────────────────────────────────

  Future<AppTriggerInfo?> loadTriggers(String appId) async {
    try {
      final resp = await _dio.get('$_base/api/apps/$appId/triggers');
      if (resp.data?['success'] == true) {
        triggerInfo = AppTriggerInfo.fromJson(resp.data['data'] as Map<String, dynamic>);
        notifyListeners();
        return triggerInfo;
      }
    } catch (e) {
      debugPrint('loadTriggers error: $e');
    }
    return null;
  }

  Future<bool> fireTrigger(String appId, String triggerId) async {
    try {
      final resp = await _dio.post(
        '$_base/api/apps/$appId/triggers/$triggerId/fire',
      );
      return resp.data?['success'] == true;
    } catch (e) {
      debugPrint('fireTrigger error: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>?> testTrigger(String appId, String triggerId, {
    String? body,
    String? path,
  }) async {
    try {
      final resp = await _dio.post(
        '$_base/api/apps/$appId/triggers/$triggerId/test',
        data: {
          'body': ?body,
          'path': ?path,
        },
        options: Options(
          receiveTimeout: const Duration(seconds: 120), // tests can be slow
        ),
      );
      if (resp.data?['success'] == true) {
        return resp.data['data'] as Map<String, dynamic>?;
      }
    } catch (e) {
      debugPrint('testTrigger error: $e');
    }
    return null;
  }

  // ── Background Sessions ───────────────────────────────────────────────────

  Future<void> loadSessions(String appId) async {
    isLoading = true;
    notifyListeners();
    try {
      final resp = await _dio.get('$_base/api/apps/$appId/background-sessions');
      if (resp.data?['success'] == true) {
        final list = resp.data['data']['sessions'] as List? ?? [];
        sessions = list.map((j) =>
            BackgroundSession.fromJson(j as Map<String, dynamic>)).toList();
      }
    } catch (e) {
      debugPrint('loadSessions error: $e');
    }
    isLoading = false;
    notifyListeners();
  }

  Future<BackgroundSession?> createSession(String appId, {
    required String name,
    Map<String, dynamic> params = const {},
    Map<String, dynamic> routingKeys = const {},
    String workspace = '',
  }) async {
    try {
      final resp = await _dio.post(
        '$_base/api/apps/$appId/background-sessions',
        data: {
          'name': name,
          'params': params,
          'routing_keys': routingKeys,
          if (workspace.isNotEmpty) 'workspace': workspace,
        },
      );
      if (resp.data?['success'] == true) {
        final session = BackgroundSession.fromJson(
            resp.data['data'] as Map<String, dynamic>);
        sessions.insert(0, session);
        notifyListeners();
        return session;
      }
    } catch (e) {
      debugPrint('createSession error: $e');
    }
    return null;
  }

  Future<BackgroundSession?> getSession(String appId, String sessionId) async {
    try {
      final resp = await _dio.get(
          '$_base/api/apps/$appId/background-sessions/$sessionId');
      if (resp.data?['success'] == true) {
        return BackgroundSession.fromJson(
            resp.data['data'] as Map<String, dynamic>);
      }
    } catch (e) {
      debugPrint('getSession error: $e');
    }
    return null;
  }

  Future<bool> pauseSession(String appId, String sessionId) async {
    try {
      final resp = await _dio.post(
          '$_base/api/apps/$appId/background-sessions/$sessionId/pause');
      if (resp.statusCode == 200) {
        final idx = sessions.indexWhere((s) => s.id == sessionId);
        if (idx != -1) {
          sessions[idx] = BackgroundSession.fromJson({
            ...sessions[idx]._toMap(),
            'status': 'paused',
          });
          notifyListeners();
        }
        return true;
      }
    } catch (e) {
      debugPrint('pauseSession error: $e');
    }
    return false;
  }

  Future<bool> resumeSession(String appId, String sessionId) async {
    try {
      final resp = await _dio.post(
          '$_base/api/apps/$appId/background-sessions/$sessionId/resume');
      if (resp.statusCode == 200) {
        final idx = sessions.indexWhere((s) => s.id == sessionId);
        if (idx != -1) {
          sessions[idx] = BackgroundSession.fromJson({
            ...sessions[idx]._toMap(),
            'status': 'active',
          });
          notifyListeners();
        }
        return true;
      }
    } catch (e) {
      debugPrint('resumeSession error: $e');
    }
    return false;
  }

  Future<bool> deleteSession(String appId, String sessionId) async {
    try {
      final resp = await _dio.delete(
          '$_base/api/apps/$appId/background-sessions/$sessionId');
      if (resp.statusCode == 200) {
        sessions.removeWhere((s) => s.id == sessionId);
        notifyListeners();
        return true;
      }
    } catch (e) {
      debugPrint('deleteSession error: $e');
    }
    return false;
  }

  // ── Activations ───────────────────────────────────────────────────────────

  Future<void> loadActivations(String appId, {
    int limit = 20,
    int offset = 0,
    String? triggerId,
    String? status,
  }) async {
    try {
      final resp = await _dio.get(
        '$_base/api/apps/$appId/activations',
        queryParameters: {
          'limit': limit,
          'offset': offset,
          'trigger_id': ?triggerId,
          'status': ?status,
        },
      );
      if (resp.data?['success'] == true) {
        final list = resp.data['data']['activations'] as List? ?? [];
        final parsed = list.map((j) =>
            Activation.fromJson(j as Map<String, dynamic>)).toList();
        if (offset == 0) {
          activations = parsed;
        } else {
          activations.addAll(parsed);
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint('loadActivations error: $e');
    }
  }

  Future<Activation?> getActivation(String appId, String activationId) async {
    try {
      final resp = await _dio.get(
          '$_base/api/apps/$appId/activations/$activationId');
      if (resp.data?['success'] == true) {
        return Activation.fromJson(resp.data['data'] as Map<String, dynamic>);
      }
    } catch (e) {
      debugPrint('getActivation error: $e');
    }
    return null;
  }

  Future<ActivationStats?> loadStats(String appId) async {
    try {
      final resp = await _dio.get(
          '$_base/api/apps/$appId/activations/stats');
      if (resp.data?['success'] == true) {
        stats = ActivationStats.fromJson(
            resp.data['data'] as Map<String, dynamic>);
        notifyListeners();
        return stats;
      }
    } catch (e) {
      debugPrint('loadStats error: $e');
    }
    return null;
  }

  Future<List<Activation>> loadErrors(String appId, {int limit = 10}) async {
    try {
      final resp = await _dio.get(
        '$_base/api/apps/$appId/errors',
        queryParameters: {'limit': limit},
      );
      if (resp.data?['success'] == true) {
        final list = resp.data['data']['activations'] as List?
            ?? resp.data['data']['errors'] as List?
            ?? [];
        return list.map((j) =>
            Activation.fromJson(j as Map<String, dynamic>)).toList();
      }
    } catch (e) {
      debugPrint('loadErrors error: $e');
    }
    return [];
  }

  // ── v2: live status + sparkline ───────────────────────────────────────────

  Future<AppStatus?> loadStatus(String appId) async {
    try {
      final resp = await _dio.get('$_base/api/apps/$appId/status');
      if (resp.data is Map && resp.data['success'] == true) {
        status = AppStatus.fromJson(
            (resp.data['data'] as Map).cast<String, dynamic>());
        // The /status endpoint may also embed the latest stats — keep
        // the cache in sync so the hero card never flashes empty.
        if (status!.stats != null) stats = status!.stats;
        notifyListeners();
        return status;
      }
    } catch (e) {
      debugPrint('loadStatus error: $e');
    }
    return null;
  }

  // ── v2: channel health ─────────────────────────────────────────────────────

  Future<List<ChannelHealth>> loadChannelsHealth(String appId) async {
    try {
      final resp = await _dio.get('$_base/api/apps/$appId/channels/health');
      if (resp.data is Map && resp.data['success'] == true) {
        final data = resp.data['data'];
        final list = data is List
            ? data
            : (data is Map ? (data['channels'] as List? ?? const []) : const []);
        channelsHealth = list
            .whereType<Map<String, dynamic>>()
            .map(ChannelHealth.fromJson)
            .toList();
        notifyListeners();
        return channelsHealth;
      }
    } catch (e) {
      debugPrint('loadChannelsHealth error: $e');
    }
    return [];
  }

  // ── v2: activation detail (events + artifacts + download) ─────────────────

  /// GET /api/apps/{id}/activations/{aid}/events — full timeline ordered
  /// by `sequence`. Optionally filter by event_type.
  Future<List<ActivationEvent>> loadActivationEvents(
    String appId,
    String activationId, {
    String? eventType,
  }) async {
    try {
      final resp = await _dio.get(
        '$_base/api/apps/$appId/activations/$activationId/events',
        queryParameters: {
          'event_type': ?eventType,
        },
      );
      if (resp.data is Map && resp.data['success'] == true) {
        final data = resp.data['data'];
        final list = data is List
            ? data
            : (data is Map ? (data['events'] as List? ?? const []) : const []);
        return list
            .whereType<Map<String, dynamic>>()
            .map(ActivationEvent.fromJson)
            .toList()
          ..sort((a, b) => a.sequence.compareTo(b.sequence));
      }
    } catch (e) {
      debugPrint('loadActivationEvents error: $e');
    }
    return const [];
  }

  /// Returns only artifact events, already mapped to [ActivationArtifact].
  /// One round-trip instead of the old /events + /artifacts double call.
  Future<List<ActivationArtifact>> loadActivationArtifacts(
    String appId,
    String activationId,
  ) async {
    try {
      final resp = await _dio.get(
        '$_base/api/apps/$appId/activations/$activationId/events',
        queryParameters: const {'event_type': 'artifact'},
      );
      if (resp.data is Map && resp.data['success'] == true) {
        final data = resp.data['data'];
        final list = data is List
            ? data
            : (data is Map ? (data['events'] as List? ?? const []) : const []);
        return list
            .whereType<Map<String, dynamic>>()
            .map(ActivationArtifact.fromEvent)
            .toList()
          ..sort((a, b) => a.sequence.compareTo(b.sequence));
      }
    } catch (e) {
      debugPrint('loadActivationArtifacts error: $e');
    }
    return const [];
  }

  /// Download an artifact's bytes. Capped at 50 MB server-side.
  ///
  /// Uses `responseType: bytes` so Dio doesn't try to parse the body as
  /// JSON — that's a must-have otherwise binary artifacts crash on
  /// utf-8 decode.
  Future<ArtifactDownload?> downloadArtifact({
    required String appId,
    required String eventId,
  }) async {
    try {
      final resp = await _dio.get<List<int>>(
        '$_base/api/apps/$appId/artifacts/$eventId/download',
        options: Options(responseType: ResponseType.bytes),
      );
      if (resp.statusCode != 200 || resp.data == null) {
        return null;
      }
      final headers = resp.headers;
      final contentType =
          headers.value('content-type') ?? 'application/octet-stream';
      final dispHeader = headers.value('content-disposition') ?? '';
      String filename = '';
      final m = RegExp(r'filename="?([^";]+)"?').firstMatch(dispHeader);
      if (m != null) filename = m.group(1) ?? '';
      if (filename.isEmpty) {
        filename = headers.value('x-artifact-filename') ??
            headers.value('x-artifact-path')?.split('/').last ??
            'artifact';
      }
      return ArtifactDownload(
        bytes: Uint8List.fromList(resp.data!),
        contentType: contentType,
        filename: filename,
      );
    } catch (e) {
      debugPrint('downloadArtifact error: $e');
      return null;
    }
  }

  /// HEAD /api/apps/{id}/artifacts/{event_id}/download — peek the size
  /// without downloading the body. Returns 0 on failure.
  Future<int> peekArtifactSize({
    required String appId,
    required String eventId,
  }) async {
    try {
      final resp = await _dio.head(
        '$_base/api/apps/$appId/artifacts/$eventId/download',
      );
      final len = resp.headers.value('content-length') ??
          resp.headers.value('x-artifact-size') ??
          '0';
      return int.tryParse(len) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  // ── Reset ─────────────────────────────────────────────────────────────────

  void reset() {
    triggerInfo = null;
    sessions = [];
    activations = [];
    stats = null;
    status = null;
    channelsHealth = [];
    isLoading = false;
    notifyListeners();
  }
}

// ─── Helpers ────────────────────────────────────────────────────────────────

DateTime? _parseDate(dynamic v) {
  if (v == null) return null;
  if (v is String) return DateTime.tryParse(v);
  if (v is num) return DateTime.fromMillisecondsSinceEpoch((v * 1000).toInt());
  return null;
}

extension _BackgroundSessionMap on BackgroundSession {
  Map<String, dynamic> _toMap() => {
    'id': id,
    'app_id': appId,
    'user_id': userId,
    'name': name,
    'status': status,
    'params': params,
    'routing_keys': routingKeys,
    'workspace': workspace,
    'created_at': createdAt?.toIso8601String(),
    'last_active_at': lastActiveAt?.toIso8601String(),
    'activation_count': activationCount,
  };
}
