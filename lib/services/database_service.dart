import 'package:flutter/foundation.dart';

/// All tool names that the daemon's database module surfaces in
/// `tool_call` events. We accept either the bare name (`sql`) or a
/// `database.` prefix (`database.sql`) so we don't break if the daemon
/// changes its naming convention.
const Set<String> _kDatabaseTools = {
  'sql',
  'schema',
  'transaction',
  'bulk_insert',
  'browse',
  'relations',
  'search_data',
  'connect',
  'disconnect',
  'list_connections',
};

/// One database tool_call captured from the SSE stream. Two events
/// arrive for the same call (one without `result`, one with) — we
/// dedupe by [id] so the UI doesn't flicker between them.
class DatabaseCall {
  final String id;
  final String name;
  final Map<String, dynamic> params;
  final bool success;
  final String error;
  final String label;
  final String detail;
  final DatabaseResult? result;
  final DateTime timestamp;

  const DatabaseCall({
    required this.id,
    required this.name,
    required this.params,
    required this.success,
    required this.error,
    required this.label,
    required this.detail,
    required this.result,
    required this.timestamp,
  });

  /// Strip an optional `database.` prefix so renderers can switch on
  /// the bare action name.
  String get bareName {
    if (name.startsWith('database.')) return name.substring(9);
    return name;
  }

  /// `true` while we have not yet received the second event with the
  /// final result. Failed calls also have no result, but they carry
  /// an error string.
  bool get isRunning => result == null && error.isEmpty;
  bool get isFailed => !success || error.isNotEmpty;
  bool get isSuccess => success && error.isEmpty && result != null;

  /// Connection id pulled from params (when present).
  String? get connectionId =>
      params['connection_id'] as String? ?? params['conn_id'] as String?;

  factory DatabaseCall.fromEvent(Map<String, dynamic> data) {
    final result = data['result'];
    return DatabaseCall(
      id: data['id'] as String? ?? '',
      name: data['name'] as String? ?? '',
      params: (data['params'] as Map?)?.cast<String, dynamic>() ?? const {},
      success: data['success'] as bool? ?? true,
      error: data['error'] as String? ?? '',
      label: data['label'] as String? ?? '',
      detail: data['detail'] as String? ?? '',
      result: result is Map ? DatabaseResult.fromMap(result.cast<String, dynamic>()) : null,
      timestamp: DateTime.now(),
    );
  }

  DatabaseCall mergeWith(DatabaseCall newer) {
    // Newer event always wins for everything except the original timestamp
    // (we want the card to keep its position in the list).
    return DatabaseCall(
      id: newer.id,
      name: newer.name,
      params: newer.params,
      success: newer.success,
      error: newer.error,
      label: newer.label,
      detail: newer.detail,
      result: newer.result ?? result,
      timestamp: timestamp, // keep original
    );
  }
}

/// The shape of `result` inside a database tool_call. The daemon
/// returns different fields depending on the action:
/// - `sql` / `browse` / `search_data` / `relations` → tabular
///   `{columns, rows, count, elapsed_ms, type}`
/// - `schema` → arbitrary nested map (handled as raw JSON tree)
/// - `transaction` → `{op, status}` or similar
/// - `connect` / `disconnect` / `list_connections` → connection objects
///
/// We expose typed getters for the tabular case and keep [raw] around
/// for renderers that need the full payload.
class DatabaseResult {
  final Map<String, dynamic> raw;

  /// Tabular result columns, if present.
  final List<String>? columns;

  /// Tabular rows. Each row is a list aligned with [columns].
  final List<List<dynamic>>? rows;

  /// Number of rows for tabular results, or affected rows for DML.
  final int? count;

  /// Server-side execution time in milliseconds.
  final int? elapsedMs;

  /// Logical type: `select`, `insert`, `update`, `delete`, `ddl`, etc.
  final String? type;

  const DatabaseResult({
    required this.raw,
    this.columns,
    this.rows,
    this.count,
    this.elapsedMs,
    this.type,
  });

  bool get isTabular => columns != null && rows != null;

  factory DatabaseResult.fromMap(Map<String, dynamic> map) {
    final cols = map['columns'];
    final rws = map['rows'];
    return DatabaseResult(
      raw: map,
      columns: cols is List ? cols.map((e) => e.toString()).toList() : null,
      rows: rws is List
          ? rws
              .whereType<List>()
              .map((r) => r.map((e) => e).toList(growable: false))
              .toList(growable: false)
          : null,
      count: (map['count'] as num?)?.toInt() ??
          (map['affected'] as num?)?.toInt(),
      elapsedMs: (map['elapsed_ms'] as num?)?.toInt() ??
          (map['elapsed'] as num?)?.toInt(),
      type: map['type'] as String?,
    );
  }
}

/// Snapshot of one connection as the daemon describes it (best-effort
/// — we read whatever fields are present without enforcing a schema).
class ConnectionInfo {
  final String id;
  final String? name;
  final String? engine; // postgresql, sqlite, mysql, mssql, oracle, …
  final String? database;
  final String? host;
  final int? port;
  final String? username;
  final bool? ssl;
  final String? status;
  final Map<String, dynamic> raw;

  const ConnectionInfo({
    required this.id,
    required this.raw,
    this.name,
    this.engine,
    this.database,
    this.host,
    this.port,
    this.username,
    this.ssl,
    this.status,
  });

  factory ConnectionInfo.fromMap(Map<String, dynamic> m) {
    return ConnectionInfo(
      id: (m['id'] ?? m['connection_id'] ?? m['name'] ?? '').toString(),
      name: m['name'] as String?,
      engine: m['engine'] as String? ?? m['driver'] as String? ?? m['type'] as String?,
      database: m['database'] as String? ?? m['db'] as String?,
      host: m['host'] as String?,
      port: (m['port'] as num?)?.toInt(),
      username: m['username'] as String? ?? m['user'] as String?,
      ssl: m['ssl'] as bool?,
      status: m['status'] as String?,
      raw: m,
    );
  }
}

/// Singleton service that observes database tool_calls flowing through
/// the SSE event stream. The frontend is **passive** — every state
/// transition (new connection, query result, transaction status) is
/// inferred from incoming events. We never send database commands.
class DatabaseService extends ChangeNotifier {
  static final DatabaseService _i = DatabaseService._();
  factory DatabaseService() => _i;
  DatabaseService._();

  // ── State ─────────────────────────────────────────────────────────────

  /// Captured database calls, ordered oldest → newest.
  final List<DatabaseCall> _calls = [];
  List<DatabaseCall> get calls => List.unmodifiable(_calls);

  /// Connections seen via `list_connections` / `connect` / `disconnect`
  /// events, keyed by id.
  final Map<String, ConnectionInfo> _connections = {};
  List<ConnectionInfo> get connections =>
      List.unmodifiable(_connections.values);

  /// Id of the connection most recently used by a database call.
  String? _activeConnectionId;
  String? get activeConnectionId => _activeConnectionId;
  ConnectionInfo? get activeConnection =>
      _activeConnectionId != null ? _connections[_activeConnectionId] : null;

  /// Number of currently-running calls (no result yet, no error).
  int get runningCount => _calls.where((c) => c.isRunning).length;
  int get errorCount => _calls.where((c) => c.isFailed).length;

  // ── Filtering helpers ─────────────────────────────────────────────────

  /// Whether the given tool name should be routed here.
  static bool isDatabaseTool(String name) {
    if (name.isEmpty) return false;
    if (name.startsWith('database.')) return true;
    return _kDatabaseTools.contains(name);
  }

  // ── Event ingestion ───────────────────────────────────────────────────

  /// Ingest a `tool_call` event. Idempotent: the daemon emits two
  /// events per call (start, end) and we merge them by id.
  void handleToolCall(Map<String, dynamic> data) {
    final incoming = DatabaseCall.fromEvent(data);
    if (incoming.id.isEmpty) return;

    final idx = _calls.indexWhere((c) => c.id == incoming.id);
    if (idx >= 0) {
      _calls[idx] = _calls[idx].mergeWith(incoming);
    } else {
      _calls.add(incoming);
      // Cap so we never grow unbounded across long sessions.
      if (_calls.length > 500) _calls.removeAt(0);
    }

    // Active connection inference: any successful database call wins,
    // unless it was an explicit disconnect.
    if (incoming.connectionId != null && incoming.isSuccess) {
      if (incoming.bareName == 'disconnect') {
        if (_activeConnectionId == incoming.connectionId) {
          _activeConnectionId = null;
        }
      } else {
        _activeConnectionId = incoming.connectionId;
      }
    }

    // Connection list inference from list_connections / connect events.
    _maybeUpdateConnections(incoming);

    notifyListeners();
  }

  void _maybeUpdateConnections(DatabaseCall call) {
    final result = call.result?.raw;
    if (result == null) return;

    // list_connections → result.connections is the canonical list.
    if (call.bareName == 'list_connections') {
      final list = result['connections'];
      if (list is List) {
        _connections.clear();
        for (final item in list) {
          if (item is Map) {
            final info = ConnectionInfo.fromMap(item.cast<String, dynamic>());
            if (info.id.isNotEmpty) _connections[info.id] = info;
          }
        }
      }
    }

    // connect / disconnect → upsert the single connection it touched.
    if (call.bareName == 'connect' || call.bareName == 'disconnect') {
      final info = result['connection'];
      if (info is Map) {
        final c = ConnectionInfo.fromMap(info.cast<String, dynamic>());
        if (c.id.isNotEmpty) _connections[c.id] = c;
      }
    }
  }

  /// Drop every captured call. Connection cache is preserved.
  void clearCalls() {
    _calls.clear();
    notifyListeners();
  }

  /// Reset the entire service. Used on session change.
  void clearAll() {
    _calls.clear();
    _connections.clear();
    _activeConnectionId = null;
    notifyListeners();
  }
}
