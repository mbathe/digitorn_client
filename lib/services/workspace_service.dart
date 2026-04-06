import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'auth_service.dart';

// ─── Models ───────────────────────────────────────────────────────────────────

class WorkbenchBuffer {
  final String path;
  final String type; // 'code' | 'text' | 'spreadsheet'
  final String content;
  final String previousContent;
  final int lines;
  final int chars;
  final bool isEdited;

  const WorkbenchBuffer({
    required this.path,
    required this.type,
    required this.content,
    this.previousContent = '',
    required this.lines,
    required this.chars,
    this.isEdited = false,
  });

  String get filename {
    return path.replaceAll('\\', '/').split('/').last;
  }

  String get extension {
    final parts = filename.split('.');
    return parts.length > 1 ? parts.last.toLowerCase() : '';
  }

  /// Directory path (for tree grouping)
  String get directory {
    final normalized = path.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    return idx > 0 ? normalized.substring(0, idx) : '';
  }

  /// Diff stats: insertions and deletions
  ({int insertions, int deletions}) get diffStats {
    if (!isEdited || previousContent.isEmpty) return (insertions: 0, deletions: 0);
    final oldLines = previousContent.split('\n');
    final newLines = content.split('\n');
    final oldSet = oldLines.toSet();
    final newSet = newLines.toSet();
    final added = newSet.difference(oldSet).length;
    final removed = oldSet.difference(newSet).length;
    return (insertions: added, deletions: removed);
  }

  WorkbenchBuffer copyWith({String? content, String? previousContent, bool? isEdited}) =>
      WorkbenchBuffer(
        path: path,
        type: type,
        content: content ?? this.content,
        previousContent: previousContent ?? this.previousContent,
        lines: (content ?? this.content).split('\n').length,
        chars: (content ?? this.content).length,
        isEdited: isEdited ?? this.isEdited,
      );
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

class DiagnosticItem {
  final String path;
  final String message;
  final String severity; // 'error' | 'warning' | 'info'
  final int line;

  const DiagnosticItem({
    required this.path,
    required this.message,
    required this.severity,
    this.line = 0,
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

class WorkspaceService extends ChangeNotifier {
  static final WorkspaceService _i = WorkspaceService._();
  factory WorkspaceService() => _i;
  WorkspaceService._();

  // Open buffers, keyed by path
  final Map<String, WorkbenchBuffer> _buffers = {};
  List<WorkbenchBuffer> get buffers => _buffers.values.toList();

  // Active buffer path shown in the editor
  String? _activeBufferPath;
  String? get activeBufferPath => _activeBufferPath;
  WorkbenchBuffer? get activeBuffer =>
      _activeBufferPath != null ? _buffers[_activeBufferPath] : null;

  // Terminal history
  final List<TerminalEntry> _terminal = [];
  List<TerminalEntry> get terminal => List.unmodifiable(_terminal);

  // Diagnostics
  final List<DiagnosticItem> _diagnostics = [];
  List<DiagnosticItem> get diagnostics => List.unmodifiable(_diagnostics);
  int get errorCount => _diagnostics.where((d) => d.severity == 'error').length;
  int get warningCount => _diagnostics.where((d) => d.severity == 'warning').length;

  // Git status
  GitStatus? _gitStatus;
  GitStatus? get gitStatus => _gitStatus;

  // Active workspace tab
  String activeTab = 'files'; // 'files' | 'terminal' | 'diagnostics'

  // Counts for badges
  int get terminalCount => _terminal.length;
  bool get hasUnreadTerminal => _terminal.isNotEmpty;

  // ── Handle SSE workbench events ───────────────────────────────────────────

  /// Called from ChatPanel when a workbench_* event arrives via SSE
  void handleEvent(String type, Map<String, dynamic> data) {
    switch (type) {
      case 'workbench_read':
        _handleFileOpen(data, edited: false);
        break;
      case 'workbench_write':
        _handleFileOpen(data, edited: true);
        break;
      case 'workbench_edit':
        _handleFileOpen(data, edited: true);
        break;
      case 'terminal_output':
        _handleTerminal(data);
        break;
      case 'diagnostics':
        _handleDiagnostics(data);
        break;
    }
  }

  /// Strip daemon line numbers like "  1│code" or "  12│code" from content
  static String _stripLineNumbers(String text) {
    if (text.isEmpty) return text;
    final lines = text.split('\n');
    // Check if first non-empty line matches the pattern
    final pattern = RegExp(r'^\s*\d+│');
    final hasLineNos = lines.where((l) => l.trim().isNotEmpty).take(3)
        .every((l) => pattern.hasMatch(l));
    if (!hasLineNos) return text;
    return lines.map((l) {
      final match = RegExp(r'^\s*\d+│(.*)$').firstMatch(l);
      return match != null ? match.group(1)! : l;
    }).join('\n');
  }

  void _handleFileOpen(Map<String, dynamic> data, {required bool edited}) {
    final path = data['buffer'] as String? ?? '';
    final type = data['type'] as String? ?? 'text';
    final rawContent = data['content'] as String? ?? '';
    final rawPrev = data['previous_content'] as String? ?? '';
    final content = _stripLineNumbers(rawContent);
    final previousContent = _stripLineNumbers(rawPrev);

    if (path.isEmpty) return;

    final existing = _buffers[path];
    _buffers[path] = WorkbenchBuffer(
      path: path,
      type: type,
      content: content,
      previousContent: edited && previousContent.isNotEmpty
          ? previousContent
          : (existing?.content ?? ''),
      lines: content.split('\n').length,
      chars: content.length,
      isEdited: edited,
    );

    // Auto-select new buffer
    _activeBufferPath = path;
    activeTab = 'files';
    notifyListeners();
  }

  /// Last pending bash command (from tool_start) waiting for terminal_output
  String _pendingCommand = '';

  /// Call this from tool_start for bash/shell tools to capture the command
  void setPendingCommand(String command) {
    _pendingCommand = command;
  }

  void _handleTerminal(Map<String, dynamic> data) {
    final entry = TerminalEntry(
      command: data['command'] as String? ?? _pendingCommand,
      stdout: data['stdout'] as String? ?? data['output'] as String? ?? '',
      stderr: data['stderr'] as String? ?? '',
      exitCode: data['exit_code'] as int? ?? 0,
    );
    _pendingCommand = ''; // consumed
    _terminal.add(entry);
    if (_terminal.length > 200) _terminal.removeAt(0);
    activeTab = 'terminal';
    notifyListeners();
  }

  void _handleDiagnostics(Map<String, dynamic> data) {
    final filePath = data['path'] as String? ?? '';
    final items = data['items'] as List? ?? data['diagnostics'] as List? ?? [];

    // Replace diagnostics for this file
    _diagnostics.removeWhere((d) => d.path == filePath);
    for (final item in items) {
      if (item is Map) {
        _diagnostics.add(DiagnosticItem(
          path: filePath,
          message: item['message'] as String? ?? '',
          severity: item['severity'] as String? ?? 'info',
          line: item['line'] as int? ?? 0,
        ));
      }
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

  void setActiveBuffer(String path) {
    _activeBufferPath = path;
    notifyListeners();
  }

  void setActiveTab(String tab) {
    activeTab = tab;
    notifyListeners();
  }

  void closeBuffer(String path) {
    _buffers.remove(path);
    if (_activeBufferPath == path) {
      _activeBufferPath = _buffers.isNotEmpty ? _buffers.keys.last : null;
    }
    notifyListeners();
  }

  void clearAll() {
    _buffers.clear();
    _activeBufferPath = null;
    _terminal.clear();
    _diagnostics.clear();
    _gitStatus = null;
    notifyListeners();
  }
}
