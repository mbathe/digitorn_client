/// Lovable-style approve / reject / refresh-git actions on workspace
/// files.
///
/// Optimistic updates: the UI flips `validation` locally before the
/// HTTP round-trip completes. The daemon's subsequent `resource_
/// patched` delta is the source of truth — if our optimistic write
/// diverges, the module applies the authoritative value.
///
/// On failure we rollback.
library;

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'file_content_service.dart';
import 'file_history_service.dart';
import 'session_service.dart';
import 'workspace_module.dart';

class FileActionsService extends ChangeNotifier {
  static final FileActionsService _i = FileActionsService._();
  factory FileActionsService() => _i;
  FileActionsService._();

  bool _busy = false;
  bool get busy => _busy;

  String? _lastError;
  String? get lastError => _lastError;

  Future<bool> approve(String path) async {
    final session = SessionService().activeSession;
    if (session == null) {
      _setError('No active session.');
      return false;
    }
    final module = WorkspaceModule();
    final original = module.files[path];
    if (original == null) {
      _setError('File not tracked: $path');
      return false;
    }
    // Optimistic update → daemon delta will confirm / override.
    module.patchFile(path, original.withValidation('approved'));
    _setBusy(true);
    try {
      final ok = await DigitornApiClient()
          .approveFile(session.appId, session.sessionId, path);
      if (!ok) {
        module.patchFile(path, original); // rollback
        _setError('Approve failed — daemon rejected.');
        return false;
      }
      FileContentService().invalidate(path);
      FileHistoryService().invalidate(
          session.appId, session.sessionId, path);
      return true;
    } catch (e) {
      module.patchFile(path, original);
      _setError('Approve failed: $e');
      return false;
    } finally {
      _setBusy(false);
    }
  }

  Future<bool> reject(String path) async {
    final session = SessionService().activeSession;
    if (session == null) {
      _setError('No active session.');
      return false;
    }
    final module = WorkspaceModule();
    final original = module.files[path];
    if (original == null) {
      _setError('File not tracked: $path');
      return false;
    }
    module.patchFile(path, original.withValidation('rejected'));
    _setBusy(true);
    try {
      final ok = await DigitornApiClient()
          .rejectFile(session.appId, session.sessionId, path);
      if (!ok) {
        module.patchFile(path, original);
        _setError('Reject failed — daemon rejected.');
        return false;
      }
      FileContentService().invalidate(path);
      FileHistoryService().invalidate(
          session.appId, session.sessionId, path);
      return true;
    } catch (e) {
      module.patchFile(path, original);
      _setError('Reject failed: $e');
      return false;
    } finally {
      _setBusy(false);
    }
  }

  /// Stage a subset of hunks — identified by stable 12-char sha256
  /// hash (preferred; survives races) or 0-based index (fallback).
  /// After a successful response, the daemon pushes a
  /// `resource_patched` with the new content + refreshed pending
  /// counts, which flows into [WorkspaceModule] via [PreviewStore].
  Future<Map<String, dynamic>?> approveHunks(
    String path,
    List<Object> hunks,
  ) async {
    final session = SessionService().activeSession;
    if (session == null) {
      _setError('No active session.');
      return null;
    }
    _setBusy(true);
    try {
      final data = await DigitornApiClient().approveFileHunks(
          session.appId, session.sessionId, path, hunks);
      if (data == null) {
        _setError('Approve hunks failed.');
        return null;
      }
      FileContentService().invalidate(path);
      FileHistoryService().invalidate(
          session.appId, session.sessionId, path);
      return data;
    } finally {
      _setBusy(false);
    }
  }

  /// Revert a subset of hunks.
  Future<Map<String, dynamic>?> rejectHunks(
    String path,
    List<Object> hunks,
  ) async {
    final session = SessionService().activeSession;
    if (session == null) {
      _setError('No active session.');
      return null;
    }
    _setBusy(true);
    try {
      final data = await DigitornApiClient().rejectFileHunks(
          session.appId, session.sessionId, path, hunks);
      if (data == null) {
        _setError('Reject hunks failed.');
        return null;
      }
      FileContentService().invalidate(path);
      FileHistoryService().invalidate(
          session.appId, session.sessionId, path);
      return data;
    } finally {
      _setBusy(false);
    }
  }

  /// PUT user edits back to the daemon. Default `autoApprove: false`
  /// keeps the manual validation flow; `true` skips straight to
  /// baseline (used by conflict-resolution dialogs).
  Future<bool> writeback(
    String path,
    String content, {
    bool autoApprove = false,
    String source = 'user',
  }) async {
    final session = SessionService().activeSession;
    if (session == null) {
      _setError('No active session.');
      return false;
    }
    _setBusy(true);
    try {
      final ok = await DigitornApiClient().writebackFile(
        session.appId,
        session.sessionId,
        path,
        content,
        autoApprove: autoApprove,
        source: source,
      );
      if (!ok) {
        _setError('Writeback failed.');
        return false;
      }
      FileContentService().invalidate(path);
      FileHistoryService().invalidate(
          session.appId, session.sessionId, path);
      return true;
    } finally {
      _setBusy(false);
    }
  }

  /// Commit staged files through the daemon. Returns the
  /// [CommitOutcome] so the UI can differentiate success
  /// (commit_sha, files_committed, pushed) from a 400 with a
  /// readable error message.
  Future<CommitOutcome?> commit({
    required String message,
    List<String>? files,
    bool push = false,
  }) async {
    final session = SessionService().activeSession;
    if (session == null) {
      _setError('No active session.');
      return null;
    }
    _setBusy(true);
    try {
      final outcome = await DigitornApiClient().commitSession(
        session.appId,
        session.sessionId,
        message: message,
        files: files,
        push: push,
      );
      if (outcome == null) {
        _setError('Commit request failed (transport).');
      } else if (!outcome.ok) {
        _setError(outcome.error ?? 'Commit failed.');
      }
      return outcome;
    } finally {
      _setBusy(false);
    }
  }

  /// Approve every file currently marked pending. One HTTP call per
  /// file — batching is a daemon-side concern.
  Future<int> approveAll() async {
    final module = WorkspaceModule();
    final pending = module.files.values
        .where((f) => f.isPending)
        .map((f) => f.path)
        .toList();
    var ok = 0;
    for (final path in pending) {
      if (await approve(path)) ok++;
    }
    return ok;
  }

  /// POST /workspace/git-status — asks the daemon to re-run
  /// `git status --porcelain` and push a resource_patched per file
  /// with the updated git_status. The UI picks them up through the
  /// usual delta path.
  Future<bool> refreshGitStatus() async {
    final session = SessionService().activeSession;
    if (session == null) return false;
    _setBusy(true);
    try {
      final ok = await DigitornApiClient()
          .refreshWorkspaceGitStatus(session.appId, session.sessionId);
      if (!ok) _setError('Git refresh failed.');
      return ok;
    } finally {
      _setBusy(false);
    }
  }

  void _setBusy(bool v) {
    if (_busy == v) return;
    _busy = v;
    if (v) _lastError = null;
    notifyListeners();
  }

  void _setError(String msg) {
    _lastError = msg;
    notifyListeners();
  }
}
