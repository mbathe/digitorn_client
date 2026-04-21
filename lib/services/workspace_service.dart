import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'auth_service.dart';
import 'session_service.dart';
import 'workspace_module.dart';

// ─── Models ───────────────────────────────────────────────────────────────────

class TrackedFile {
  final String path;
  final String relativePath;
  final String action;
  final int size;
  final bool isDir;
  final int insertions;
  final int deletions;
  final double timestamp;
  final bool active;
  final int level;
  final String? icon;
  final String? color;
  final String? detail;

  const TrackedFile({
    required this.path,
    required this.relativePath,
    this.action = '',
    this.size = 0,
    this.isDir = false,
    this.insertions = 0,
    this.deletions = 0,
    this.timestamp = 0,
    this.active = false,
    this.level = 0,
    this.icon,
    this.color,
    this.detail,
  });

  String get badge => switch (action) {
        'write' => 'A',
        'edit' || 'insert' => 'M',
        'rm' => 'D',
        'mv_src' || 'mv_dst' => 'R',
        _ => '',
      };

  String get filename =>
      relativePath.replaceAll('\\', '/').split('/').last;

  String get extension {
    final parts = filename.split('.');
    return parts.length > 1 ? parts.last.toLowerCase() : '';
  }
}

class FileTreeStats {
  final int totalFiles;
  final int modifiedFiles;
  final int totalInsertions;
  final int totalDeletions;
  final int readFiles;

  const FileTreeStats({
    this.totalFiles = 0,
    this.modifiedFiles = 0,
    this.totalInsertions = 0,
    this.totalDeletions = 0,
    this.readFiles = 0,
  });

  static const empty = FileTreeStats();

  bool get isEmpty => totalFiles == 0 && modifiedFiles == 0;
  bool get isNotEmpty => !isEmpty;
}

/// Compatibility projection over [WorkspaceFile] — exists so older
/// consumers (search, changes panel, chat navigation) keep working
/// while they migrate to [WorkspaceModule.files] directly. New code
/// should read [WorkspaceModule] straight.
class WorkbenchBuffer {
  final String path;
  final String type;
  final String content;
  /// Previous content, when the source [WorkspaceFile] exposes a
  /// diff anchor. On [WorkspaceFile] we don't store raw baselines —
  /// only cumulative counts — so this is always empty today. Kept for
  /// wire-compat with legacy consumers; new diff views should rely on
  /// [unifiedDiffPending] instead.
  final String previousContent;
  final int lines;
  final int chars;
  final bool isEdited;
  /// Projected diff stats — cumulative insertions / deletions since
  /// session start, read straight from the source [WorkspaceFile].
  final int insertions;
  final int deletions;

  // ── PENDING counters (delta vs last approved baseline) ────────
  //
  // The correct source for the "Changes" panel stats and diff view:
  // scout-verified delta-vs-baseline that aggregates every write
  // since approve. Populated from the daemon's
  // `insertions_pending` / `deletions_pending` (BUG #1 fix) via
  // [WorkspaceFile.pendingInsertionsEffective].
  final int pendingInsertions;
  final int pendingDeletions;
  /// Daemon's `unified_diff_pending` — the aggregate diff vs the
  /// last approved baseline. What the Changes panel renders.
  final String unifiedDiffPending;

  const WorkbenchBuffer({
    required this.path,
    required this.type,
    required this.content,
    this.previousContent = '',
    required this.lines,
    required this.chars,
    this.isEdited = false,
    this.insertions = 0,
    this.deletions = 0,
    this.pendingInsertions = 0,
    this.pendingDeletions = 0,
    this.unifiedDiffPending = '',
  });

  String get filename =>
      path.replaceAll('\\', '/').split('/').last;

  String get extension {
    final parts = filename.split('.');
    return parts.length > 1 ? parts.last.toLowerCase() : '';
  }

  String get directory {
    final normalized = path.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    return idx > 0 ? normalized.substring(0, idx) : '';
  }

  /// Legacy record shape kept for [ChangesPanel] — the projection
  /// can't reconstruct a line-accurate diff without the baseline, so
  /// these are the cumulative counters from [WorkspaceFile].
  ({int insertions, int deletions}) get diffStats =>
      (insertions: insertions, deletions: deletions);
}

class TerminalEntry {
  final String command;
  final String stdout;
  final String stderr;
  final int exitCode;
  final DateTime timestamp;

  TerminalEntry({
    required this.command,
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  }) : timestamp = DateTime.now();

  bool get hasError => exitCode != 0 || stderr.isNotEmpty;
}

/// Legacy diagnostic shape kept for the terminal-bound `diagnostics`
/// event stream (not the Phase-1 LSP diagnostics, which live on
/// [WorkspaceModule.diagnostics]).
class DiagnosticItem {
  final String path;
  final String message;
  final String severity;
  final int line;
  final int? column;
  final int? endLine;
  final int? endColumn;
  final String? code;
  final String? source;

  const DiagnosticItem({
    required this.path,
    required this.message,
    required this.severity,
    this.line = 0,
    this.column,
    this.endLine,
    this.endColumn,
    this.code,
    this.source,
  });

  String get location {
    final name = path.replaceAll('\\', '/').split('/').last;
    if (line == 0) return name;
    return column != null ? '$name:$line:$column' : '$name:$line';
  }
}

/// One-shot navigation request consumed by the active viewer.
class RevealTarget {
  final String path;
  final int line;
  final int? column;
  final int requestId;

  const RevealTarget({
    required this.path,
    required this.line,
    this.column,
    required this.requestId,
  });
}

class GitStatus {
  final String branch;
  final int ahead;
  final int behind;
  final List<Map<String, String>> changes;

  const GitStatus({
    this.branch = '',
    this.ahead = 0,
    this.behind = 0,
    this.changes = const [],
  });
}

// ─── WorkspaceService ─────────────────────────────────────────────────────────
//
// Post-workbench era: the daemon's file operations are delivered
// exclusively via `preview:*` events, consumed by [WorkspaceModule].
// This service used to own a parallel `_buffers` storage fed by the
// now-deleted `workbench_*` stream. It is now a thin façade:
//
//   * [buffers] / [activeBuffer] — computed view over [WorkspaceModule].
//   * [activeBufferPath], [pendingReveal], [activeTab] — purely UI
//     state (which file is focused, which sub-view is open).
//   * [terminal], [diagnostics], [gitStatus], [trackedFiles] — legacy
//     telemetry still fed by a handful of non-file events
//     (`terminal_output`, `diagnostics`, `workspace_status`).
//
// No code writes into a private buffer map anymore; there is only one
// source of truth for files.

class WorkspaceService extends ChangeNotifier {
  static final WorkspaceService _i = WorkspaceService._();
  factory WorkspaceService() => _i;
  WorkspaceService._() {
    // Re-notify when WorkspaceModule changes, so consumers that watch
    // us directly (via Provider) keep updating without needing to
    // subscribe to both services.
    WorkspaceModule().addListener(notifyListeners);
  }

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 30),
  ))..interceptors.add(AuthService().authInterceptor);

  // ── Buffers (computed view over WorkspaceModule) ─────────────

  List<WorkbenchBuffer> get buffers {
    final files = WorkspaceModule().files;
    if (files.isEmpty) return const [];
    return files.values.map(_projectFile).toList(growable: false);
  }

  WorkbenchBuffer? get activeBuffer {
    final path = _activeBufferPath;
    if (path == null) return null;
    final file = WorkspaceModule().files[path];
    return file != null ? _projectFile(file) : null;
  }

  static WorkbenchBuffer _projectFile(WorkspaceFile f) => WorkbenchBuffer(
        path: f.path,
        type: 'text',
        content: f.content,
        previousContent: '',
        lines: f.lines,
        chars: f.content.length,
        isEdited: f.isPending || f.hasPendingChanges,
        insertions: f.totalInsertions,
        deletions: f.totalDeletions,
        // Aggregated pending counters — the "Changes" view reads
        // these so its +N -M reflects EVERY write since approve,
        // not just the last op.
        pendingInsertions: f.pendingInsertionsEffective,
        pendingDeletions: f.pendingDeletionsEffective,
        unifiedDiffPending: f.unifiedDiffPending ?? '',
      );

  // ── UI state (lives here, not in the module) ─────────────────

  String? _activeBufferPath;
  String? get activeBufferPath => _activeBufferPath;

  final List<TerminalEntry> _terminal = [];
  List<TerminalEntry> get terminal => List.unmodifiable(_terminal);

  final List<DiagnosticItem> _diagnostics = [];
  List<DiagnosticItem> get diagnostics => List.unmodifiable(_diagnostics);
  int get errorCount =>
      _diagnostics.where((d) => d.severity == 'error').length;
  int get warningCount =>
      _diagnostics.where((d) => d.severity == 'warning').length;

  GitStatus? _gitStatus;
  GitStatus? get gitStatus => _gitStatus;

  List<TrackedFile> trackedFiles = [];
  FileTreeStats fileStats = FileTreeStats.empty;
  String workspaceRoot = '';

  String activeTab = 'files';

  RevealTarget? _pendingReveal;
  RevealTarget? get pendingReveal => _pendingReveal;
  int _revealRequestId = 0;

  int get terminalCount => _terminal.length;
  bool get hasUnreadTerminal => _terminal.isNotEmpty;

  // ── Event dispatcher — shrunk to the non-file event streams ──

  /// Routes the remaining non-file Socket.IO events (terminal_output
  /// and legacy diagnostics) to the right handler. File events
  /// (`workbench_*`, `preview:*`) no longer pass through here.
  void handleEvent(String type, Map<String, dynamic> data) {
    switch (type) {
      case 'terminal_output':
        _handleTerminal(data);
      case 'diagnostics':
        _handleDiagnostics(data);
    }
  }

  String _pendingCommand = '';
  // Tracks the (command, stdout) pair appended most recently from a
  // `tool_call` so the follow-up `terminal_output` envelope (same
  // content, fewer fields) doesn't create a duplicate entry.
  String _lastIngestedCommand = '';
  String _lastIngestedStdout = '';

  void setPendingCommand(String command) {
    _pendingCommand = command;
  }

  /// Ingest the FULL bash/shell `tool_call.result` straight into the
  /// terminal. The scout confirmed this envelope carries every field
  /// `terminal_output` carries PLUS `exit_code`, `cwd`, `platform`,
  /// and `shell` — which the narrower `terminal_output` stream
  /// drops. Calling this from the chat pipeline makes the terminal
  /// tab correct for non-zero exit codes (the old path defaulted to
  /// 0 when terminal_output was silent on the field).
  void ingestBashToolCall(
      Map<String, dynamic> params, Map<String, dynamic> result) {
    final command = (params['command'] as String?)
        ?? (params['cmd'] as String?)
        ?? (result['command'] as String?)
        ?? _pendingCommand;
    final stdout = (result['stdout'] as String?) ?? '';
    final stderr = (result['stderr'] as String?) ?? '';
    final exitCode = (result['exit_code'] as num?)?.toInt() ?? 0;
    _terminal.add(TerminalEntry(
      command: command,
      stdout: stdout,
      stderr: stderr,
      exitCode: exitCode,
    ));
    if (_terminal.length > 200) _terminal.removeAt(0);
    _pendingCommand = '';
    _lastIngestedCommand = command;
    _lastIngestedStdout = stdout;
    activeTab = 'terminal';
    notifyListeners();
  }

  void _handleTerminal(Map<String, dynamic> data) {
    final command = data['command'] as String? ?? _pendingCommand;
    final stdout = data['stdout'] as String? ?? data['output'] as String? ?? '';
    // Dedupe: if we just ingested the same bash tool_call, its
    // terminal_output echo is redundant. Skip it so the terminal
    // doesn't show two cards per command.
    if (command == _lastIngestedCommand && stdout == _lastIngestedStdout) {
      _lastIngestedCommand = '';
      _lastIngestedStdout = '';
      return;
    }
    final entry = TerminalEntry(
      command: command,
      stdout: stdout,
      stderr: data['stderr'] as String? ?? '',
      exitCode: data['exit_code'] as int? ?? 0,
    );
    _pendingCommand = '';
    _terminal.add(entry);
    if (_terminal.length > 200) _terminal.removeAt(0);
    activeTab = 'terminal';
    notifyListeners();
  }

  void _handleDiagnostics(Map<String, dynamic> data) {
    final filePath = data['path'] as String? ?? '';
    final items = data['items'] as List? ?? data['diagnostics'] as List? ?? [];
    _diagnostics.removeWhere((d) => d.path == filePath);
    for (final item in items) {
      if (item is! Map) continue;
      final itemPath = item['path'] as String? ?? filePath;
      _diagnostics.add(DiagnosticItem(
        path: itemPath,
        message: item['message'] as String? ?? '',
        severity: item['severity'] as String? ?? 'info',
        line: (item['line'] as num?)?.toInt() ?? 0,
        column: (item['column'] as num?)?.toInt() ??
            (item['col'] as num?)?.toInt(),
        endLine: (item['end_line'] as num?)?.toInt() ??
            (item['endLine'] as num?)?.toInt(),
        endColumn: (item['end_column'] as num?)?.toInt() ??
            (item['endColumn'] as num?)?.toInt(),
        code: item['code'] as String?,
        source: item['source'] as String?,
      ));
    }
    notifyListeners();
  }

  /// Called from ChatPanel when result includes workspace_status
  void updateGitStatus(Map<String, dynamic>? data) {
    if (data == null || data.isEmpty) return;
    _gitStatus = GitStatus(
      branch: data['branch'] as String? ?? '',
      ahead: data['ahead'] as int? ?? 0,
      behind: data['behind'] as int? ?? 0,
      changes: (data['changes'] as List? ?? [])
          .map((c) => Map<String, String>.from(c as Map? ?? {}))
          .toList(),
    );
    notifyListeners();
  }

  /// Notify listeners externally — used after batch mutations.
  void notifyChanged() => notifyListeners();

  void setActiveBuffer(String path) {
    _activeBufferPath = path;
    notifyListeners();
  }

  // ── Diagnostics navigation ────────────────────────────────────

  List<DiagnosticItem> diagnosticsForPath(String path) =>
      _diagnostics.where((d) => d.path == path).toList(growable: false);

  /// Programmatically focus a file at a given line/column. Pointing at
  /// a path unknown to [WorkspaceModule] is a no-op — the file can no
  /// longer arrive via the dropped `workbench_read` event, and the
  /// agent always re-opens files via its own `preview:*` flow.
  void revealLine(String path, int line, {int? column}) {
    _revealRequestId++;
    _pendingReveal = RevealTarget(
      path: path,
      line: line,
      column: column,
      requestId: _revealRequestId,
    );
    if (WorkspaceModule().files.containsKey(path)) {
      _activeBufferPath = path;
    }
    activeTab = 'files';
    notifyListeners();
  }

  void revealDiagnostic(DiagnosticItem item) {
    if (item.line <= 0) return;
    revealLine(item.path, item.line, column: item.column);
  }

  void consumeReveal(int requestId) {
    if (_pendingReveal?.requestId == requestId) {
      _pendingReveal = null;
    }
  }

  /// Ask the daemon to open a file in the session workspace. Kept
  /// for backward-compat with code paths that still call it; the
  /// daemon may choose to emit a `preview:resource_set` in response
  /// or ignore the request entirely.
  Future<void> requestFileOpen(String path) async {
    final session = SessionService().activeSession;
    if (session == null) return;
    final base = AuthService().baseUrl;
    try {
      await _dio.post(
        '$base/api/apps/${session.appId}/sessions/${session.sessionId}/workbench/open',
        data: jsonEncode({'path': path}),
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (s) => s != null && s != 401,
        ),
      );
    } catch (_) {
      // Endpoint may not exist — silent fallback.
    }
  }

  void setActiveTab(String tab) {
    activeTab = tab;
    notifyListeners();
  }

  /// Compat alias — closes the editor-focused file. The underlying
  /// file stays in [WorkspaceModule]; we only drop our UI focus.
  void closeBuffer(String path) {
    if (_activeBufferPath == path) {
      final files = WorkspaceModule().files.keys;
      _activeBufferPath = files.isNotEmpty ? files.last : null;
      notifyListeners();
    }
  }

  /// Called when the user closes the whole workspace panel — drop UI
  /// state but leave [WorkspaceModule] alone (it's the daemon-synced
  /// source of truth).
  void clearAll() {
    _activeBufferPath = null;
    _terminal.clear();
    _diagnostics.clear();
    _gitStatus = null;
    trackedFiles = [];
    fileStats = FileTreeStats.empty;
    workspaceRoot = '';
    notifyListeners();
  }

  @override
  void dispose() {
    WorkspaceModule().removeListener(notifyListeners);
    super.dispose();
  }
}
