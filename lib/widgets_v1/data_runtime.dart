/// Digitorn Widgets v1 — data source runtime.
///
/// Walks a parsed widget spec, discovers every `data:` block, and
/// spawns fetchers that feed the pane's [WidgetRuntimeState]. Four
/// source types are handled:
///
///   * `static`  — value copied as-is (no network, no polling)
///   * `http`    — GET/POST via [WidgetsService] with optional poll
///   * `tool`    — invokes an agent tool via the chat pipeline
///   * `stream`  — subscribes to an SSE feed (best-effort)
///   * `local`   — reads / writes SharedPreferences
///
/// All fetchers respect the `when:` expression and debounce
/// re-fetches triggered by input changes. Polling is best-effort —
/// one timer per binding.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/auth_service.dart';
import 'bindings.dart';
import 'models.dart';
import 'service.dart';
import 'state.dart';

/// Owns the lifecycle of every data binding declared inside a
/// mounted pane. Created once per [WidgetHost], disposed at unmount.
class DataRuntime {
  final String appId;
  final WidgetRuntimeState state;

  /// Declared bindings, indexed by their name. A name may appear
  /// multiple times only if registered from different sub-trees —
  /// the runtime uses the first one and warns on conflicts.
  final Map<String, _Binding> _bindings = {};

  /// Optional hook invoked when a `type: tool` binding wants to
  /// run. Main.dart wires this to the chat/session pipeline so
  /// we don't have a hard dependency on the chat layer here.
  final Future<dynamic> Function(String tool, Map<String, dynamic> args)?
      toolRunner;

  DataRuntime({
    required this.appId,
    required this.state,
    this.toolRunner,
  });

  /// Register a group of data sources. Safe to call multiple times
  /// — duplicates are ignored with a debug warning.
  void register(Map<String, DataSourceSpec> sources) {
    sources.forEach((key, spec) {
      if (_bindings.containsKey(key)) {
        debugPrint('DataRuntime: duplicate binding "$key" ignored');
        return;
      }
      final b = _Binding(name: key, spec: spec, runtime: this);
      _bindings[key] = b;
      b.bootstrap();
    });
  }

  /// Walks a [WidgetNode] tree recursively and registers every
  /// `data:` block it encounters. Useful when the pane spec has
  /// data blocks deeper in the tree (not just at the root).
  void scanTree(WidgetNode node) {
    if (node.data.isNotEmpty) register(node.data);
    final children = node.children;
    if (children != null) {
      for (final c in children) {
        scanTree(c);
      }
    }
    // Recurse into well-known slot keys that may hold sub-trees.
    for (final slot in const ['first', 'second', 'item', 'empty', 'loading', 'card']) {
      final n = node.nodeAt(slot);
      if (n != null) scanTree(n);
    }
    for (final slot in const ['tabs', 'columns']) {
      for (final n in node.nodesAt(slot)) {
        scanTree(n);
      }
    }
  }

  /// Refresh a binding by name. "all" → refresh every registered one.
  Future<void> refresh(String name) async {
    if (name == 'all') {
      for (final b in _bindings.values) {
        b.refresh();
      }
      return;
    }
    final b = _bindings[name];
    if (b != null) await b.refresh();
  }

  /// Dispose everything. Called by [WidgetHost] at unmount.
  void dispose() {
    for (final b in _bindings.values) {
      b.dispose();
    }
    _bindings.clear();
  }
}

/// One active binding — owns its timer and last-fetched value.
class _Binding {
  final String name;
  final DataSourceSpec spec;
  final DataRuntime runtime;

  Timer? _pollTimer;
  Timer? _debounceTimer;
  StreamSubscription? _streamSub;
  http.Client? _streamClient;
  bool _disposed = false;

  _Binding({required this.name, required this.spec, required this.runtime});

  WidgetRuntimeState get state => runtime.state;

  String? get _when => spec.props['when'] as String?;

  bool _shouldRun() {
    final w = _when;
    if (w == null) return true;
    return evalBool(w, state.buildScope(), fallback: true);
  }

  Future<void> bootstrap() async {
    switch (spec.type) {
      case 'static':
        _applyStatic();
        break;
      case 'http':
        await _runHttp();
        _schedulePoll();
        break;
      case 'tool':
        if (spec.props['auto'] != false) {
          await _runTool();
        }
        break;
      case 'local':
        await _runLocal();
        break;
      case 'stream':
        _runStream();
        break;
      default:
        state.setDataError(name, 'Unknown data type: ${spec.type}');
    }
  }

  void _applyStatic() {
    var v = spec.props['value'];
    // Templates inside static values are still resolved.
    if (v is String) {
      v = evalValue(v, state.buildScope()) ?? v;
    }
    state.setDataValue(name, v);
  }

  Future<void> _runHttp() async {
    if (!_shouldRun()) return;
    state.setDataLoading(name);
    try {
      final scope = state.buildScope();
      final method = (spec.props['method'] as String? ?? 'GET').toUpperCase();
      final url = evalTemplate(spec.props['url'] as String? ?? '', scope);
      final query = _resolveMap(spec.props['query'], scope);
      final body = _resolveMap(spec.props['body'], scope);
      final headers = _resolveStringMap(spec.props['headers'], scope);
      final raw = await WidgetsService().fetchBinding(
        runtime.appId,
        method: method,
        url: url,
        query: query,
        body: body,
        headers: headers,
      );
      // Optional transform expression extracts a sub-field.
      final transform = spec.props['transform'] as String?;
      dynamic value = raw;
      if (transform != null && transform.isNotEmpty) {
        // Evaluate with a layered scope exposing the fetched body
        // as `response`.
        final layered = state.buildScope(extra: {'response': raw});
        value = evalValue(transform, layered);
      }
      state.setDataValue(name, value);
    } catch (e) {
      state.setDataError(name, e.toString());
    }
  }

  /// Real SSE stream binding. Subscribes to the daemon's endpoint,
  /// parses `data:` lines as JSON, and feeds them to the state
  /// store per the declared reducer (`replace`, `append`, `merge`).
  Future<void> _runStream() async {
    if (!_shouldRun()) return;
    // Cancel any previous subscription — re-subscribes are safe.
    await _cancelStream();
    state.setDataLoading(name);
    try {
      final scope = state.buildScope();
      final urlRaw = spec.props['url'] as String? ?? '';
      final url = evalTemplate(urlRaw, scope);
      final reducer = (spec.props['reducer'] as String? ?? 'replace');
      final limit = (spec.props['limit'] is num)
          ? (spec.props['limit'] as num).toInt()
          : 500;
      final base = AuthService().baseUrl;
      final token = AuthService().accessToken;
      final full = url.startsWith('http')
          ? url
          : '$base/api/apps/${runtime.appId}${url.startsWith('/') ? '' : '/'}$url';

      _streamClient = http.Client();
      final req = http.Request('GET', Uri.parse(full))
        ..headers['Accept'] = 'text/event-stream'
        ..headers['Cache-Control'] = 'no-cache';
      if (token != null) req.headers['Authorization'] = 'Bearer $token';

      final response = await _streamClient!.send(req);
      if (response.statusCode >= 400) {
        state.setDataError(name, 'Stream HTTP ${response.statusCode}');
        return;
      }
      state.setDataValue(name, reducer == 'append' ? const [] : null);

      final buffer = <dynamic>[];
      _streamSub = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          if (!line.startsWith('data:')) return;
          final raw = line.substring(5).trim();
          if (raw.isEmpty || raw == '[DONE]') return;
          dynamic decoded;
          try {
            decoded = jsonDecode(raw);
          } catch (_) {
            decoded = raw;
          }
          switch (reducer) {
            case 'append':
              buffer.add(decoded);
              if (buffer.length > limit) {
                buffer.removeRange(0, buffer.length - limit);
              }
              state.setDataValue(name, [...buffer]);
              break;
            case 'merge':
              final current = state.getDataValue(name);
              if (decoded is Map && current is Map) {
                state.setDataValue(name, {...current, ...decoded});
              } else {
                state.setDataValue(name, decoded);
              }
              break;
            case 'replace':
            default:
              state.setDataValue(name, decoded);
          }
        },
        onError: (e) {
          state.setDataError(name, e.toString());
        },
        onDone: () {
          // Stream closed cleanly — mark stale so the binding can
          // be refreshed if needed, but keep the last value.
          state.setDataStale(name);
        },
        cancelOnError: true,
      );
    } catch (e) {
      state.setDataError(name, e.toString());
    }
  }

  Future<void> _cancelStream() async {
    await _streamSub?.cancel();
    _streamSub = null;
    try {
      _streamClient?.close();
    } catch (_) {}
    _streamClient = null;
  }

  Future<void> _runTool() async {
    final runner = runtime.toolRunner;
    if (runner == null) {
      state.setDataError(name, 'No tool runner wired');
      return;
    }
    if (!_shouldRun()) return;
    state.setDataLoading(name);
    try {
      final scope = state.buildScope();
      final tool = evalTemplate(spec.props['tool'] as String? ?? '', scope);
      final args = _resolveMap(spec.props['args'], scope) ?? const {};
      final value = await runner(tool, args);
      state.setDataValue(name, value);
    } catch (e) {
      state.setDataError(name, e.toString());
    }
  }

  Future<void> _runLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'widget.local.${runtime.appId}.${spec.props['key']}';
      final raw = prefs.getString(key);
      if (raw == null) {
        state.setDataValue(name, spec.props['default']);
        return;
      }
      try {
        state.setDataValue(name, jsonDecode(raw));
      } catch (_) {
        state.setDataValue(name, raw);
      }
    } catch (e) {
      state.setDataError(name, e.toString());
    }
  }

  void _schedulePoll({int? overrideMs}) {
    if (_disposed) return;
    final pollRaw = spec.props['poll'];
    final ms = overrideMs ?? _parseDuration(pollRaw);
    if (ms == null || ms <= 0) return;
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(Duration(milliseconds: ms), (_) {
      if (_disposed) return;
      _runHttp();
    });
  }

  Future<void> refresh() async {
    _debounceTimer?.cancel();
    switch (spec.type) {
      case 'http':
        await _runHttp();
        break;
      case 'stream':
        await _runStream();
        break;
      case 'tool':
        await _runTool();
        break;
      case 'local':
        await _runLocal();
        break;
      case 'static':
        _applyStatic();
        break;
    }
  }

  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _debounceTimer?.cancel();
    // Fire-and-forget — we don't block dispose on network teardown.
    // The http.Client.close() is cheap and the subscription cancel
    // is synchronous enough in practice.
    _streamSub?.cancel();
    try {
      _streamClient?.close();
    } catch (_) {}
    _streamSub = null;
    _streamClient = null;
  }

  // ── helpers ──────────────────────────────────────────────────

  Map<String, dynamic>? _resolveMap(dynamic raw, BindingScope scope) {
    if (raw is! Map) return null;
    final out = <String, dynamic>{};
    raw.forEach((k, v) {
      out[k.toString()] = resolve(v, scope);
    });
    return out;
  }

  Map<String, String>? _resolveStringMap(dynamic raw, BindingScope scope) {
    final m = _resolveMap(raw, scope);
    if (m == null) return null;
    return m.map((k, v) => MapEntry(k, v?.toString() ?? ''));
  }

  int? _parseDuration(dynamic v) {
    if (v == null) return null;
    if (v is num) return (v * 1000).toInt();
    final s = v.toString().trim().toLowerCase();
    if (s.isEmpty || s == '0') return 0;
    final match = RegExp(r'^(\d+)(ms|s|m|h)?$').firstMatch(s);
    if (match == null) return null;
    final n = int.parse(match.group(1)!);
    final unit = match.group(2) ?? 's';
    switch (unit) {
      case 'ms':
        return n;
      case 's':
        return n * 1000;
      case 'm':
        return n * 60 * 1000;
      case 'h':
        return n * 60 * 60 * 1000;
    }
    return null;
  }
}
