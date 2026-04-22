/// Workspace Module — virtual filesystem driven by `preview:*` events.
///
/// The daemon's agent writes files via WsWrite/WsEdit/WsDelete tools.
/// Each mutation emits a `preview:resource_set` (channel=files) or
/// `preview:resource_deleted` event. Metadata (render_mode, entry_file)
/// arrives via `preview:state_changed` (key=workspace).
///
/// This service listens to [PreviewStore] and exposes a typed API for
/// the UI layer: file tree, selected file, workspace metadata, and
/// the preview render mode.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import '../models/diagnostic.dart';
import 'preview_store.dart';

// ── Models ───────────────────────────────────────────────────────────────────

/// Full mirror of the backend's `WorkspaceFile` payload. Covers three
/// concerns in a single immutable struct:
///
///   1. **Content** — `content`, `language`, `size`, `lines`. Only
///      carried on the per-file endpoint (`/files/{path}`); the
///      code-snapshot endpoint strips it to stay light.
///   2. **Change lifecycle** — `status`, `operation`, cumulative
///      counters + **pending** counters reset on every approve()
///      (VS Code gutter semantics).
///   3. **Source control** — `git_status` when the workspace is a
///      git repo (untracked / unstaged / staged / committed /
///      conflict / ignored).
class WorkspaceFile {
  // ── Content (heavy — not always populated) ─────────────────────
  final String path;
  final String content;
  final String language;
  final int size;
  final int lines;

  // ── Change tracking ────────────────────────────────────────────
  /// "added" | "modified" | "deleted"
  final String status;
  /// "write" | "edit" | "delete"
  final String operation;
  /// Insertions from the most recent operation.
  final int insertions;
  final int deletions;
  /// Cumulative since session start.
  final int totalInsertions;
  final int totalDeletions;
  /// Unix seconds — bumps on every write. Drives editor auto-reload.
  final double? updatedAt;

  // ── Diffs ──────────────────────────────────────────────────────
  /// Short textual diff (previews, compact rendering).
  final String? diff;
  /// Full standard unified diff (from the last write).
  final String? unifiedDiff;
  /// Unified diff against the **last approved baseline** — this is
  /// what the editor should show in diff mode.
  final String? unifiedDiffPending;

  // ── Validation workflow (Lovable-style approve / reject) ──────
  /// "pending" | "approved" | "rejected". Drives the colored dot
  /// and the inline Approve / Reject actions in the file tree.
  final String validation;
  /// Insertions since the last approve() — fresh gutter counters
  /// after each accept cycle.
  final int insertionsPending;
  final int deletionsPending;
  /// Lines in the last-approved version. Used to compute
  /// "+N -M out of baselineLines" annotations.
  final int baselineLines;

  // ── Source control ────────────────────────────────────────────
  /// Null when the workspace isn't a git repo. Possible values:
  /// "staged" | "unstaged" | "untracked" | "committed" | "conflict"
  /// | "ignored".
  final String? gitStatus;

  /// The file's content BEFORE this operation — populated by the
  /// daemon on `preview:resource_patched` / `preview:resource_set`
  /// events for every write/edit. We use it to seed the session
  /// baseline in [WorkspaceModule] so the diff overlay can show
  /// deletions, not just additions, for never-approved files.
  /// Null when the event is a fresh read (no prior state).
  final String? previousContent;

  const WorkspaceFile({
    required this.path,
    this.content = '',
    this.language = '',
    this.size = 0,
    this.lines = 0,
    this.status = 'added',
    this.operation = 'write',
    this.insertions = 0,
    this.deletions = 0,
    this.totalInsertions = 0,
    this.totalDeletions = 0,
    this.updatedAt,
    this.diff,
    this.unifiedDiff,
    this.unifiedDiffPending,
    this.validation = 'pending',
    this.insertionsPending = 0,
    this.deletionsPending = 0,
    this.baselineLines = 0,
    this.gitStatus,
    this.previousContent,
  });

  /// Parse a raw map from the daemon (from snapshots or deltas).
  /// Every field has a sensible default so older daemon responses
  /// keep working.
  factory WorkspaceFile.fromJson(String path, Map payload) {
    final m = payload.cast<String, dynamic>();
    return WorkspaceFile(
      path: path,
      content: (m['content'] as String?) ?? '',
      language: (m['language'] as String?) ?? '',
      size: (m['size'] as num?)?.toInt() ?? 0,
      lines: (m['lines'] as num?)?.toInt() ?? 0,
      status: (m['status'] as String?) ?? 'added',
      operation: (m['operation'] as String?) ?? 'write',
      insertions: (m['insertions'] as num?)?.toInt() ?? 0,
      deletions: (m['deletions'] as num?)?.toInt() ?? 0,
      totalInsertions: (m['total_insertions'] as num?)?.toInt() ?? 0,
      totalDeletions: (m['total_deletions'] as num?)?.toInt() ?? 0,
      updatedAt: (m['updated_at'] as num?)?.toDouble(),
      diff: m['diff'] as String?,
      unifiedDiff: m['unified_diff'] as String?,
      unifiedDiffPending: m['unified_diff_pending'] as String?,
      validation: (m['validation'] as String?) ?? 'pending',
      insertionsPending: (m['insertions_pending'] as num?)?.toInt() ?? 0,
      deletionsPending: (m['deletions_pending'] as num?)?.toInt() ?? 0,
      baselineLines: (m['baseline_lines'] as num?)?.toInt() ?? 0,
      gitStatus: m['git_status'] as String?,
      previousContent: m['previous_content'] as String?,
    );
  }

  String get filename => path.replaceAll('\\', '/').split('/').last;

  String get extension {
    final parts = filename.split('.');
    return parts.length > 1 ? parts.last.toLowerCase() : '';
  }

  String get directory {
    final normalized = path.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    return idx > 0 ? normalized.substring(0, idx) : '';
  }

  bool get isAdded => status == 'added';
  bool get isModified => status == 'modified';
  bool get isDeleted => status == 'deleted';
  bool get hasChanges => totalInsertions > 0 || totalDeletions > 0;
  bool get hasPendingChanges =>
      pendingInsertionsEffective > 0 || pendingDeletionsEffective > 0;

  /// Pending counters (delta-vs-last-approved-baseline) shown as the
  /// `+N -M` badge next to file names in the explorer.
  ///
  /// Priority order — the daemon ships two potentially contradictory
  /// sources (the raw counters and the unified diff) and we've seen
  /// builds where the counters reflect only the LAST write while the
  /// unified diff is correctly cumulative. We therefore parse the
  /// unified diff first (guaranteed aggregate since it's the
  /// vs-baseline comparison) and fall back to the raw counters only
  /// when no diff is available (e.g. fresh session before any write).
  ///
  /// This matches what the user sees: three consecutive 1-line edits
  /// now produce `+3 -3`, not `+1 -1` that would hide the history.
  int get pendingInsertionsEffective {
    if ((unifiedDiffPending ?? '').isNotEmpty) {
      final parsed = _parsePendingDiffCounts();
      if (parsed.$1 > 0 || parsed.$2 > 0) return parsed.$1;
    }
    return insertionsPending;
  }

  int get pendingDeletionsEffective {
    if ((unifiedDiffPending ?? '').isNotEmpty) {
      final parsed = _parsePendingDiffCounts();
      if (parsed.$1 > 0 || parsed.$2 > 0) return parsed.$2;
    }
    return deletionsPending;
  }

  (int, int) _parsePendingDiffCounts() {
    final diff = unifiedDiffPending ?? '';
    if (diff.isEmpty) return (0, 0);
    var ins = 0, del = 0;
    for (final line in diff.split('\n')) {
      if (line.startsWith('+++') || line.startsWith('---') ||
          line.startsWith('@@')) {
        continue;
      }
      if (line.startsWith('+')) {
        ins++;
      } else if (line.startsWith('-')) {
        del++;
      }
    }
    return (ins, del);
  }

  // ── Validation helpers ────────────────────────────────────────
  bool get isPending => validation == 'pending';
  bool get isApproved => validation == 'approved';
  bool get isRejected => validation == 'rejected';

  // ── Git helpers ───────────────────────────────────────────────
  bool get isConflict => gitStatus == 'conflict';
  bool get isUntracked => gitStatus == 'untracked';
  bool get isStaged => gitStatus == 'staged';
  bool get isUnstaged => gitStatus == 'unstaged';
  bool get isCommitted => gitStatus == 'committed';

  String get changesSummary {
    final parts = <String>[];
    if (totalInsertions > 0) parts.add('+$totalInsertions');
    if (totalDeletions > 0) parts.add('-$totalDeletions');
    return parts.join(' ');
  }

  String get pendingSummary {
    final parts = <String>[];
    final ins = pendingInsertionsEffective;
    final del = pendingDeletionsEffective;
    if (ins > 0) parts.add('+$ins');
    if (del > 0) parts.add('-$del');
    return parts.join(' ');
  }

  /// Return a copy with [validation] overridden — used by optimistic
  /// updates before the daemon's delta echoes back.
  WorkspaceFile withValidation(String next) => WorkspaceFile(
        path: path,
        content: content,
        language: language,
        size: size,
        lines: lines,
        status: status,
        operation: operation,
        insertions: insertions,
        deletions: deletions,
        totalInsertions: totalInsertions,
        totalDeletions: totalDeletions,
        updatedAt: updatedAt,
        diff: diff,
        unifiedDiff: unifiedDiff,
        unifiedDiffPending: unifiedDiffPending,
        validation: next,
        insertionsPending:
            next == 'approved' ? 0 : insertionsPending,
        deletionsPending:
            next == 'approved' ? 0 : deletionsPending,
        baselineLines:
            next == 'approved' ? lines : baselineLines,
        gitStatus: gitStatus,
        previousContent: previousContent,
      );
}

class WorkspaceMeta {
  final String renderMode; // react, html, markdown, latex, slides, code
  final String? entryFile;
  final String? title;

  const WorkspaceMeta({
    this.renderMode = 'code',
    this.entryFile,
    this.title,
  });
}

// ── Service ──────────────────────────────────────────────────────────────────

class WorkspaceModule extends ChangeNotifier {
  static final WorkspaceModule _i = WorkspaceModule._();
  factory WorkspaceModule() => _i;
  WorkspaceModule._() {
    PreviewStore().addListener(_onStoreChanged);
  }

  WorkspaceMeta _meta = const WorkspaceMeta();
  WorkspaceMeta get meta => _meta;

  /// All files keyed by path.
  Map<String, WorkspaceFile> _files = {};
  Map<String, WorkspaceFile> get files => Map.unmodifiable(_files);

  /// Per-path "session baseline" — the file's content as it stood
  /// BEFORE the agent's first edit of this session. Used by the
  /// editor's diff overlay to show cumulative insertions AND
  /// deletions even when the daemon's `baseline` field is empty
  /// (the default for files that were never approved).
  ///
  /// Populated lazily: the first time a file is observed, we seed
  /// the baseline with `previous_content` from the event if the
  /// daemon provided one (the authoritative pre-edit content), or
  /// with `''` for files the agent created from nothing. On
  /// approve, the baseline slides forward to the current content
  /// so the next cycle diffs against the freshly-accepted state.
  final Map<String, String> _sessionBaselines = {};

  /// Best-effort baseline for [path] — the cached session origin if
  /// we have one, otherwise empty (fresh file, first time we see
  /// it). Consumers that already have a daemon-side baseline should
  /// prefer it when non-empty.
  String sessionBaselineFor(String path) => _sessionBaselines[path] ?? '';

  /// Client-side aggregate of +/- since the last approval, per path.
  ///
  /// The daemon ships `insertions_pending` / `deletions_pending` alongside
  /// each file payload, but in practice those counters reflect only the
  /// *last* write operation on several builds — they don't accumulate
  /// across consecutive edits, which is exactly the "always shows the
  /// last edit" bug users hit. We fix it client-side by adding every
  /// per-op `insertions`/`deletions` value (authoritative per-op, from
  /// the daemon) to a running total, and clearing the entry the moment
  /// the file flips to `approved` (= baseline bumped to current content).
  final Map<String, ({int ins, int del})> _pendingAggregate = {};

  /// Cumulative pending insertions for [path] since the last approval.
  int pendingInsertionsFor(String path) =>
      _pendingAggregate[path]?.ins ?? 0;

  /// Cumulative pending deletions for [path] since the last approval.
  int pendingDeletionsFor(String path) =>
      _pendingAggregate[path]?.del ?? 0;

  /// Currently selected file in the explorer.
  String? _selectedPath;
  String? get selectedPath => _selectedPath;

  WorkspaceFile? get selectedFile =>
      _selectedPath != null ? _files[_selectedPath] : null;

  // ── LSP diagnostics (phase 1) ──────────────────────────────────
  /// Per-path diagnostics, keyed by file path. Populated from the
  /// preview `diagnostics` resource channel. Entries with stale
  /// generation numbers are silently rejected (see [_rebuild]).
  Map<String, DiagnosticsEntry> _diagnostics = {};
  Map<String, DiagnosticsEntry> get diagnostics =>
      Map.unmodifiable(_diagnostics);

  DiagnosticsEntry? diagnosticsFor(String path) => _diagnostics[path];

  int get totalErrors =>
      _diagnostics.values.fold(0, (s, e) => s + e.errorCount);
  int get totalWarnings =>
      _diagnostics.values.fold(0, (s, e) => s + e.warningCount);
  int get totalInfos =>
      _diagnostics.values.fold(0, (s, e) => s + e.infoCount);
  int get totalHints =>
      _diagnostics.values.fold(0, (s, e) => s + e.hintCount);
  int get filesWithErrors =>
      _diagnostics.values.where((e) => e.errorCount > 0).length;
  int get filesWithWarnings => _diagnostics.values
      .where((e) => e.warningCount > 0 && e.errorCount == 0)
      .length;

  /// The worst severity across all files, or null if clean.
  DiagnosticSeverity? get worstSeverity {
    DiagnosticSeverity? worst;
    for (final e in _diagnostics.values) {
      final s = e.severityMax;
      if (s == null) continue;
      if (worst == null || s.rank > worst.rank) worst = s;
    }
    return worst;
  }

  // ── Reveal target (one-shot navigation from Problems panel) ───
  int _revealRequest = 0;
  String? _revealPath;
  int? _revealLine;
  int? _revealColumn;

  int get revealRequest => _revealRequest;
  String? get revealPath => _revealPath;
  int? get revealLine => _revealLine;
  int? get revealColumn => _revealColumn;

  /// Ask the UI to scroll [path] to [line] (1-based, Monaco-style).
  /// Selects the file if it isn't already selected. Every call bumps
  /// [revealRequest] so listeners can detect repeat clicks on the
  /// same line.
  void revealAt(String path, int line, {int? column}) {
    _revealRequest++;
    _revealPath = path;
    _revealLine = line;
    _revealColumn = column;
    _selectedPath = path;
    notifyListeners();
  }

  /// The entry file for the preview renderer.
  WorkspaceFile? get entryFile {
    if (_meta.entryFile != null) return _files[_meta.entryFile];
    return _files.values.firstOrNull;
  }

  /// Whether the workspace has any content.
  bool get hasFiles => _files.isNotEmpty;

  /// Whether the workspace has metadata (render_mode set by daemon).
  bool get hasMeta => _meta.renderMode != 'code' || _meta.entryFile != null;

  /// Sorted file paths — most recently modified first, then alphabetical.
  List<String> get sortedPaths {
    final paths = _files.keys.toList();
    paths.sort((a, b) {
      final fa = _files[a]!;
      final fb = _files[b]!;
      // Recent first if both have timestamps
      if (fa.updatedAt != null && fb.updatedAt != null) {
        final cmp = fb.updatedAt!.compareTo(fa.updatedAt!);
        if (cmp != 0) return cmp;
      }
      return a.compareTo(b);
    });
    return paths;
  }

  // ── Global stats ────────────────────────────────────────────────────────

  int get totalInsertions => _files.values.fold(0, (s, f) => s + f.totalInsertions);
  int get totalDeletions => _files.values.fold(0, (s, f) => s + f.totalDeletions);
  int get addedCount => _files.values.where((f) => f.isAdded).length;
  int get modifiedCount => _files.values.where((f) => f.isModified).length;
  int get deletedCount => _files.values.where((f) => f.isDeleted).length;

  // ── Validation stats (Lovable approve workflow) ─────────────
  int get pendingCount =>
      _files.values.where((f) => f.isPending).length;
  int get approvedCount =>
      _files.values.where((f) => f.isApproved).length;
  int get rejectedCount =>
      _files.values.where((f) => f.isRejected).length;
  int get conflictCount =>
      _files.values.where((f) => f.isConflict).length;

  /// Patch a single file in place — used by optimistic approve /
  /// reject before the daemon echoes back the delta. Silently no-op
  /// if the path isn't known.
  void patchFile(String path, WorkspaceFile next) {
    if (!_files.containsKey(path)) return;
    _files = {..._files, path: next};
    notifyListeners();
  }

  String get globalSummary {
    final parts = <String>[
      '${_files.length} file${_files.length == 1 ? '' : 's'}',
    ];
    final ins = totalInsertions;
    final del = totalDeletions;
    if (ins > 0 || del > 0) {
      final changeParts = <String>[];
      if (ins > 0) changeParts.add('+$ins');
      if (del > 0) changeParts.add('-$del');
      parts.add(changeParts.join(' '));
    }
    final statusParts = <String>[];
    final a = addedCount;
    final m = modifiedCount;
    final d = deletedCount;
    if (a > 0) statusParts.add('$a added');
    if (m > 0) statusParts.add('$m modified');
    if (d > 0) statusParts.add('$d deleted');
    if (statusParts.isNotEmpty) parts.add(statusParts.join(', '));
    return parts.join(' · ');
  }

  /// Select a file by path.
  void selectFile(String? path) {
    if (_selectedPath == path) return;
    _selectedPath = path;
    notifyListeners();
  }

  bool _scheduled = false;

  /// Called when PreviewStore changes. We defer the actual rebuild to
  /// a microtask so we never fire `notifyListeners` while another
  /// notifier is mid-flight (which corrupts the widget tree).
  void _onStoreChanged() {
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      _rebuild();
    });
  }

  /// Lightweight fingerprint over every [WorkspaceFile] field the UI
  /// consumes. `_rebuild` compares old vs new per path; any diff fires
  /// a listener notification so the gutter badges / diff view /
  /// editor refresh in real time.
  ///
  /// `content.length` + `updatedAt` catches content-level edits
  /// without hashing the whole buffer (updatedAt bumps on every
  /// daemon write, even when bytes coincidentally match). The rest
  /// catches validation flips, pending-count mutations, diff
  /// aggregation steps, and git_status transitions.
  static String _fileSignature(WorkspaceFile f) {
    final b = StringBuffer();
    b.write(f.content.length);
    b.write('|');
    b.write(f.updatedAt ?? 0);
    b.write('|');
    b.write(f.validation);
    b.write('|');
    b.write(f.insertionsPending);
    b.write('|');
    b.write(f.deletionsPending);
    b.write('|');
    b.write(f.totalInsertions);
    b.write('|');
    b.write(f.totalDeletions);
    b.write('|');
    b.write((f.unifiedDiffPending ?? '').length);
    b.write('|');
    b.write((f.unifiedDiff ?? '').length);
    b.write('|');
    b.write(f.gitStatus ?? '');
    b.write('|');
    b.write(f.status);
    return b.toString();
  }

  void _rebuild() {
    final store = PreviewStore();
    debugPrint('WorkspaceModule: rebuild — state keys: ${store.state.keys}, '
        'resource channels: ${store.resources.keys}, '
        'files count: ${store.resources['files']?.length ?? 0}');
    bool changed = false;

    // Extract workspace metadata from state
    final wsRaw = store.state['workspace'];
    if (wsRaw is Map) {
      final newMeta = WorkspaceMeta(
        renderMode: wsRaw['render_mode'] as String? ?? 'code',
        entryFile: wsRaw['entry_file'] as String?,
        title: wsRaw['title'] as String?,
      );
      if (newMeta.renderMode != _meta.renderMode ||
          newMeta.entryFile != _meta.entryFile ||
          newMeta.title != _meta.title) {
        _meta = newMeta;
        changed = true;
      }
    }

    // Extract files from resources["files"]
    final filesRaw = store.resources['files'];
    if (filesRaw != null) {
      final newFiles = <String, WorkspaceFile>{};
      for (final entry in filesRaw.entries) {
        final path = entry.key;
        final payload = entry.value;
        if (payload is Map) {
          final parsed = WorkspaceFile.fromJson(path, payload);
          // Fall back to the language guessed from extension when the
          // daemon hasn't emitted one (legacy payloads).
          newFiles[path] = parsed.language.isNotEmpty
              ? parsed
              : WorkspaceFile(
                  path: parsed.path,
                  content: parsed.content,
                  language: _guessLanguage(path),
                  size: parsed.size,
                  lines: parsed.lines,
                  status: parsed.status,
                  operation: parsed.operation,
                  insertions: parsed.insertions,
                  deletions: parsed.deletions,
                  totalInsertions: parsed.totalInsertions,
                  totalDeletions: parsed.totalDeletions,
                  updatedAt: parsed.updatedAt,
                  diff: parsed.diff,
                  unifiedDiff: parsed.unifiedDiff,
                  unifiedDiffPending: parsed.unifiedDiffPending,
                  validation: parsed.validation,
                  insertionsPending: parsed.insertionsPending,
                  deletionsPending: parsed.deletionsPending,
                  baselineLines: parsed.baselineLines,
                  gitStatus: parsed.gitStatus,
                  previousContent: parsed.previousContent,
                );
        }
      }

      // Detect any meaningful change. The previous impl compared
      // only `content`, which left the UI stuck whenever the daemon
      // bumped pending counters / validation / unifiedDiffPending /
      // gitStatus WITHOUT altering the bytes (very common: approve
      // clears `insertions_pending` without touching content; two
      // consecutive writes of the same line keep content identical
      // but grow the aggregate diff).
      final pathsDiffer = newFiles.length != _files.length ||
          !newFiles.keys.every(_files.containsKey);
      var filesDirty = pathsDiffer;
      if (!filesDirty) {
        for (final entry in newFiles.entries) {
          final old = _files[entry.key];
          if (old == null || _fileSignature(old) !=
              _fileSignature(entry.value)) {
            filesDirty = true;
            break;
          }
        }
      }
      if (filesDirty) {
        _updatePendingAggregate(newFiles);
        _files = newFiles;
        // Auto-select first file if nothing selected
        if (_selectedPath == null && _files.isNotEmpty) {
          _selectedPath = _meta.entryFile ?? _files.keys.first;
        }
        // Clear selection if selected file was deleted
        if (_selectedPath != null && !_files.containsKey(_selectedPath)) {
          _selectedPath = _files.isNotEmpty ? _files.keys.first : null;
        }
        changed = true;
      }
    } else if (_files.isNotEmpty) {
      // Store cleared
      _files = {};
      _selectedPath = null;
      _pendingAggregate.clear();
      _sessionBaselines.clear();
      changed = true;
    }

    if (_rebuildDiagnostics(store)) changed = true;

    if (changed) notifyListeners();
  }

  /// Walk [newFiles] and update [_pendingAggregate] so the `+N -M`
  /// badge on the file tree reflects the CUMULATIVE insertions /
  /// deletions since the last approval — not just the latest write.
  ///
  /// Why we key on `totalInsertions` / `totalDeletions` (session-wide
  /// cumulative) rather than `insertions` / `deletions` (per-op):
  /// store events are batched through a microtask in `_onStoreChanged`,
  /// so three consecutive writes collapse into a single `_rebuild`
  /// call — at which point `insertions`/`deletions` on the new
  /// WorkspaceFile reflect only the LAST operation in the batch.
  /// Subtracting consecutive session totals gives us the true delta
  /// over the whole batch.
  ///
  /// Rules:
  ///   1. `validation == 'approved'` → the baseline was just bumped
  ///      to the current content, so pending resets to zero.
  ///   2. File freshly introduced → seed the aggregate with the
  ///      file's session totals (these represent every write since
  ///      session start vs. an empty baseline).
  ///   3. `updatedAt` advanced (or a clean→pending flip) → add the
  ///      delta `newTotal - oldTotal` to the running count. Keying
  ///      on `updatedAt` means snapshot replays on reconnect don't
  ///      double-count because `updatedAt` doesn't move.
  ///   4. Path removed from the new map → clean up the entry.
  void _updatePendingAggregate(Map<String, WorkspaceFile> newFiles) {
    for (final entry in newFiles.entries) {
      final path = entry.key;
      final newFile = entry.value;
      final oldFile = _files[path];

      // Session baseline — captured the first time we see this path,
      // then slid forward on every approval. Used by the editor's
      // diff overlay so it can render BOTH deletions AND insertions
      // for files that have never been approved (the daemon-side
      // `baseline` is empty in that case, leaving the diff with only
      // the current content painted green).
      if (!_sessionBaselines.containsKey(path)) {
        // Prefer the daemon's `previous_content` when available —
        // that's the file's state BEFORE this write. Falling back
        // to '' is correct for fresh files the agent created from
        // nothing (nothing to delete before the first line).
        _sessionBaselines[path] = newFile.previousContent ?? '';
      } else if (oldFile != null &&
          !oldFile.isApproved &&
          newFile.isApproved) {
        // Approve slides the baseline forward so the next edit cycle
        // diffs against the freshly-accepted state.
        _sessionBaselines[path] = newFile.content;
      }

      if (newFile.isApproved) {
        _pendingAggregate.remove(path);
        continue;
      }

      if (oldFile == null) {
        final ins = newFile.totalInsertions;
        final del = newFile.totalDeletions;
        if (ins > 0 || del > 0) {
          _pendingAggregate[path] = (ins: ins, del: del);
        }
        continue;
      }

      final oldTs = oldFile.updatedAt;
      final newTs = newFile.updatedAt;
      final wroteSinceLastRebuild =
          newTs != null && (oldTs == null || newTs > oldTs);
      final flippedToPending = oldFile.isApproved && !newFile.isApproved;

      if (wroteSinceLastRebuild || flippedToPending) {
        final deltaIns =
            (newFile.totalInsertions - oldFile.totalInsertions)
                .clamp(0, 1 << 30);
        final deltaDel =
            (newFile.totalDeletions - oldFile.totalDeletions)
                .clamp(0, 1 << 30);
        if (deltaIns == 0 && deltaDel == 0) continue;
        final current = _pendingAggregate[path] ?? (ins: 0, del: 0);
        _pendingAggregate[path] = (
          ins: current.ins + deltaIns,
          del: current.del + deltaDel,
        );
      }
    }

    // Drop aggregates + baselines for files that disappeared from
    // the store.
    _pendingAggregate.removeWhere((k, _) => !newFiles.containsKey(k));
    _sessionBaselines.removeWhere((k, _) => !newFiles.containsKey(k));
  }

  /// Re-read `resources['diagnostics']` into typed entries with a
  /// generation guard. Returns true if anything changed (so the outer
  /// rebuild should notify listeners).
  ///
  /// Guard semantics:
  ///   * New path → accept.
  ///   * Same path, newer or equal generation → accept.
  ///   * Same path, older generation → reject (stale delta reordered
  ///     behind a fresher one by the socket layer).
  ///   * Path disappeared from the channel → drop our cached entry
  ///     (daemon emitted `resource_deleted`, e.g. file was deleted).
  bool _rebuildDiagnostics(PreviewStore store) {
    final raw = store.resources['diagnostics'];
    final next = <String, DiagnosticsEntry>{};

    if (raw != null) {
      for (final entry in raw.entries) {
        final path = entry.key;
        final payload = entry.value;
        if (payload is! Map) continue;
        final parsed = DiagnosticsEntry.fromJson(path, payload);
        final existing = _diagnostics[path];
        if (existing != null && parsed.generation < existing.generation) {
          // Stale — keep the newer cached entry.
          next[path] = existing;
          continue;
        }
        next[path] = parsed;
      }
    }

    // Detect change cheaply: size mismatch or any entry differs by
    // identity / generation / item count.
    if (next.length != _diagnostics.length) {
      _diagnostics = next;
      return true;
    }
    for (final e in next.entries) {
      final old = _diagnostics[e.key];
      if (old == null ||
          old.generation != e.value.generation ||
          old.items.length != e.value.items.length) {
        _diagnostics = next;
        return true;
      }
    }
    return false;
  }

  void reset() {
    _meta = const WorkspaceMeta();
    _files = {};
    _selectedPath = null;
    _diagnostics = {};
    _revealRequest = 0;
    _revealPath = null;
    _revealLine = null;
    _revealColumn = null;
    notifyListeners();
  }

  static String _guessLanguage(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'tsx' || 'jsx' => 'tsx',
      'ts' => 'typescript',
      'js' || 'mjs' || 'cjs' => 'javascript',
      'py' => 'python',
      'dart' => 'dart',
      'html' || 'htm' => 'html',
      'css' || 'scss' || 'sass' => 'css',
      'json' => 'json',
      'yaml' || 'yml' => 'yaml',
      'md' || 'mdx' => 'markdown',
      'tex' || 'latex' => 'latex',
      'sql' => 'sql',
      'sh' || 'bash' || 'zsh' => 'bash',
      'xml' || 'svg' => 'xml',
      'toml' => 'toml',
      'rs' => 'rust',
      'go' => 'go',
      'java' => 'java',
      'kt' => 'kotlin',
      'swift' => 'swift',
      'rb' => 'ruby',
      'php' => 'php',
      'c' || 'h' => 'cpp',
      'cpp' || 'cc' || 'hpp' => 'cpp',
      _ => ext,
    };
  }

  @override
  void dispose() {
    PreviewStore().removeListener(_onStoreChanged);
    super.dispose();
  }
}
