import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'auth_service.dart';

/// Caches the daemon's `GET /api/ui/tool_display_defaults` catalog —
/// the canonical source of:
///
///   * icon semantic keys (file, folder, terminal, …) the daemon
///     knows about, so the client can log unknown values in dev
///     rather than falling back silently.
///   * human labels for `channel` values ("Terminal", "Workspace", …)
///     — surfaced in the UI when routing a non-chat tool call to a
///     side panel ("Sent to Terminal").
///   * human labels for `category` values ("Action", "Memory", …).
///   * fallback regex patterns used when a tool_call event arrives
///     from an older daemon without a `display` block.
///
/// The service is best-effort: it attempts [load] once at app
/// start and silently falls back to built-in defaults when the
/// endpoint is unreachable. UI code should never fail hard because
/// this catalog isn't available — every getter has a sensible
/// static fallback matching the event-spec canonical values.
class ToolDisplayDefaultsService extends ChangeNotifier {
  static final ToolDisplayDefaultsService _i =
      ToolDisplayDefaultsService._();
  factory ToolDisplayDefaultsService() => _i;
  ToolDisplayDefaultsService._();

  Map<String, dynamic>? _raw;
  Set<String> _knownIcons = const {};
  Map<String, String> _channelLabels = const {};
  Map<String, String> _categoryLabels = const {};
  List<Map<String, dynamic>> _fallbackPatterns = const [];
  int _version = 0;
  bool _loaded = false;
  bool get isLoaded => _loaded;
  int get catalogVersion => _version;

  // ── Static defaults mirroring the v2 spec canonical values ──────────────
  //
  // Used both as a fallback when the endpoint is unreachable AND as
  // a guarantee that every callsite gets a sensible label even if a
  // daemon omits a particular value from its catalog.

  static const Set<String> _defaultIcons = {
    'file', 'folder', 'checklist', 'memory', 'terminal', 'search',
    'agent', 'web', 'database', 'git', 'tool', 'image', 'network',
    'edit', 'preview', 'workspace', 'diagnostics', 'shell',
    // Client-side supplemental icons used by existing _semanticIcon:
    'code', 'download', 'upload', 'lock', 'key', 'mail', 'chat',
    'settings', 'graph',
  };

  static const Map<String, String> _defaultChannelLabels = {
    'chat': 'Chat',
    'tasks': 'Tasks',
    'memory': 'Memory',
    'agents': 'Agents',
    'workspace': 'Workspace',
    'terminal': 'Terminal',
    'diagnostics': 'Diagnostics',
    'preview': 'Preview',
    'none': 'Hidden',
  };

  static const Map<String, String> _defaultCategoryLabels = {
    'action': 'Action',
    'plumbing': 'Plumbing',
    'memory': 'Memory',
    'control_flow': 'Flow',
  };

  // ── Public API ──────────────────────────────────────────────────────────

  /// Human-readable label for a canonical `channel` value. Falls
  /// back to a capitalised raw value for unknown channels.
  String channelLabel(String channel) {
    if (channel.isEmpty) return '';
    final server = _channelLabels[channel];
    if (server != null && server.isNotEmpty) return server;
    final builtin = _defaultChannelLabels[channel];
    if (builtin != null) return builtin;
    return channel[0].toUpperCase() + channel.substring(1);
  }

  /// Human-readable label for a canonical `category` value.
  String categoryLabel(String category) {
    if (category.isEmpty) return '';
    final server = _categoryLabels[category];
    if (server != null && server.isNotEmpty) return server;
    final builtin = _defaultCategoryLabels[category];
    if (builtin != null) return builtin;
    return category[0].toUpperCase() + category.substring(1);
  }

  /// True when [icon] is a known canonical icon (either from the
  /// server catalog or the built-in fallback). Unknown icons should
  /// be logged in dev — the client will render its generic "tool"
  /// icon for them but an unknown value is a signal that the daemon
  /// and client drifted.
  bool knowsIcon(String icon) =>
      _knownIcons.contains(icon) || _defaultIcons.contains(icon);

  /// Raw catalog payload, for debug inspection.
  Map<String, dynamic>? get raw => _raw;

  /// Regex fallback patterns served by the daemon for tools emitted
  /// without a `display` block. Each entry should at least carry
  /// `name_pattern` + `icon`/`channel`/`category` hints.
  List<Map<String, dynamic>> get fallbackPatterns =>
      List.unmodifiable(_fallbackPatterns);

  // ── Loader ──────────────────────────────────────────────────────────────

  Future<void> load() async {
    if (_loaded) return;
    final auth = AuthService();
    final base = auth.baseUrl;
    if (base.isEmpty) return;
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 6),
        receiveTimeout: const Duration(seconds: 8),
        validateStatus: (s) => s != null && s < 500,
      ))
        ..interceptors.add(auth.authInterceptor);
      final r = await dio.get('$base/api/ui/tool_display_defaults');
      if (r.statusCode == null || r.statusCode! >= 400) {
        debugPrint(
            'ToolDisplayDefaults: endpoint unavailable (${r.statusCode}) — using built-in defaults');
        _loaded = true;
        notifyListeners();
        return;
      }
      final body = r.data;
      if (body is! Map) {
        debugPrint(
            'ToolDisplayDefaults: unexpected body shape — ${body.runtimeType}');
        _loaded = true;
        notifyListeners();
        return;
      }
      _ingest(Map<String, dynamic>.from(body));
      _loaded = true;
      notifyListeners();
    } catch (e) {
      debugPrint('ToolDisplayDefaults: load failed — $e');
      _loaded = true;
      notifyListeners();
    }
  }

  /// Drop the cached catalog and re-fetch. Call when baseUrl or
  /// auth changes so the labels reflect the new daemon's defaults.
  Future<void> reload() async {
    _raw = null;
    _knownIcons = const {};
    _channelLabels = const {};
    _categoryLabels = const {};
    _fallbackPatterns = const [];
    _loaded = false;
    await load();
  }

  // ── Internal — parse the catalog defensively ────────────────────────────

  void _ingest(Map<String, dynamic> body) {
    _raw = body;
    _version = (body['version'] as num?)?.toInt() ?? 0;

    final icons = body['icons'];
    if (icons is Map) {
      _knownIcons = icons.keys.map((e) => e.toString()).toSet();
    } else if (icons is List) {
      _knownIcons = icons.whereType<String>().toSet();
    }

    _channelLabels = _parseLabelMap(body['channels']);
    _categoryLabels = _parseLabelMap(body['categories']);

    final fallbacks = body['fallback_patterns'];
    if (fallbacks is List) {
      _fallbackPatterns = fallbacks
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList(growable: false);
    }
  }

  /// Accepts either `{key: "Label"}` or `{key: {label: "Label", …}}`.
  Map<String, String> _parseLabelMap(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, String>{};
    raw.forEach((k, v) {
      final key = k.toString();
      if (v is String && v.isNotEmpty) {
        out[key] = v;
      } else if (v is Map && v['label'] is String) {
        out[key] = v['label'] as String;
      }
    });
    return out;
  }
}
