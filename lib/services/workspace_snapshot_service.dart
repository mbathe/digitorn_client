/// Drives the "Saving… / Saved ✓" indicator in the chat header.
///
/// The daemon's workspace persistence pipeline debounces writes and
/// emits a monotonically-increasing `preview_seq` on every snapshot.
/// We watch that seq:
///
///   1. When it grows   → flip to "Saving…".
///   2. Once it has stayed unchanged for [_settleDelay] ms → flip
///      to "Saved ✓" with the current timestamp.
///
/// No explicit REST call is needed — persistence is transparent
/// daemon-side. This service is purely **observational** on top of
/// [PreviewStore.seq].
///
/// A secondary state machine tracks the lifecycle of the three user-
/// facing actions (export / import / fork) via [busy] + [lastError]
/// so the UI can disable menu items and surface failures.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'preview_store.dart';

class WorkspaceSnapshotService extends ChangeNotifier {
  static final WorkspaceSnapshotService _i = WorkspaceSnapshotService._();
  factory WorkspaceSnapshotService() => _i;
  WorkspaceSnapshotService._() {
    _bind();
  }

  /// How long the seq must stay unchanged before we flip "Saving…" →
  /// "Saved ✓". Matches the daemon's 500ms debounce + a little buffer
  /// for the post-debounce DB write to complete.
  static const _settleDelay = Duration(milliseconds: 800);

  int _lastSeenSeq = 0;
  int get lastSeenSeq => _lastSeenSeq;

  DateTime? _lastSavedAt;
  DateTime? get lastSavedAt => _lastSavedAt;

  bool _hasPendingWrites = false;
  bool get hasPendingWrites => _hasPendingWrites;

  // ── Action state ──────────────────────────────────────────────
  bool _busy = false;
  bool get busy => _busy;

  String? _lastError;
  String? get lastError => _lastError;

  Timer? _settleTimer;

  void _bind() {
    PreviewStore().addListener(_onStoreChanged);
    // Seed so we don't treat the initial seq as "a new write".
    _lastSeenSeq = PreviewStore().seq;
  }

  void _onStoreChanged() {
    final nextSeq = PreviewStore().seq;
    if (nextSeq == _lastSeenSeq) return;
    _lastSeenSeq = nextSeq;
    if (!_hasPendingWrites) {
      _hasPendingWrites = true;
      notifyListeners();
    }
    _settleTimer?.cancel();
    _settleTimer = Timer(_settleDelay, () {
      _hasPendingWrites = false;
      _lastSavedAt = DateTime.now();
      notifyListeners();
    });
  }

  /// Called on session switch — every session has its own daemon-
  /// side row, so we reset our observations to avoid showing a
  /// stale "Saved 14:02" from the previous session.
  void resetForNewSession() {
    _settleTimer?.cancel();
    _settleTimer = null;
    _lastSeenSeq = PreviewStore().seq;
    _lastSavedAt = null;
    _hasPendingWrites = false;
    _lastError = null;
    notifyListeners();
  }

  // ── Actions ───────────────────────────────────────────────────

  /// Export the current session snapshot as a portable envelope.
  /// Returns null on failure — caller shows [lastError].
  Future<WorkspaceSnapshotEnvelope?> export({
    required String appId,
    required String sessionId,
  }) async {
    _beginBusy();
    try {
      final env = await DigitornApiClient()
          .exportWorkspaceSnapshot(appId, sessionId);
      if (env == null) {
        _lastError = 'Could not export workspace — endpoint unreachable.';
      }
      return env;
    } catch (e) {
      _lastError = 'Export failed: $e';
      return null;
    } finally {
      _endBusy();
    }
  }

  /// Push an envelope into this session. `replace=true` wipes first.
  Future<bool> import({
    required String appId,
    required String sessionId,
    required WorkspaceSnapshotEnvelope envelope,
    bool replace = true,
  }) async {
    _beginBusy();
    try {
      final ok = await DigitornApiClient().importWorkspaceSnapshot(
        appId,
        sessionId,
        envelope: envelope,
        replace: replace,
      );
      if (!ok) {
        _lastError = 'Import failed — daemon rejected the snapshot.';
      }
      return ok;
    } catch (e) {
      _lastError = 'Import failed: $e';
      return false;
    } finally {
      _endBusy();
    }
  }

  /// Fork the session into a new one and return the daemon's
  /// response. The UI is responsible for switching to the new
  /// session after a successful fork.
  Future<WorkspaceForkResult?> fork({
    required String appId,
    required String sessionId,
    String? title,
    String? targetSessionId,
  }) async {
    _beginBusy();
    try {
      final result = await DigitornApiClient().forkWorkspace(
        appId,
        sessionId,
        targetSessionId: targetSessionId,
        title: title,
      );
      if (result == null) {
        _lastError = 'Fork failed — daemon could not copy the workspace.';
      }
      return result;
    } catch (e) {
      _lastError = 'Fork failed: $e';
      return null;
    } finally {
      _endBusy();
    }
  }

  void _beginBusy() {
    _busy = true;
    _lastError = null;
    notifyListeners();
  }

  void _endBusy() {
    _busy = false;
    notifyListeners();
  }

  @override
  void dispose() {
    PreviewStore().removeListener(_onStoreChanged);
    _settleTimer?.cancel();
    super.dispose();
  }
}
