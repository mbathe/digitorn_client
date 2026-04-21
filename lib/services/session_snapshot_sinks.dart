/// Typed sinks for the 8 hydration snapshots emitted by the daemon
/// on `join_session`. Each snapshot lands in the sink that owns the
/// UI it drives:
///
///   connected            → [onConnected]         (handshake seq)
///   preview:snapshot     → [previewSnapshot]     (workspace preview)
///   queue:snapshot       → [queueSnapshot]       (pending messages)
///   active_ops:snapshot  → [activeOpsSnapshot]   (spinners / chips)
///   session:snapshot     → [sessionSnapshot]     (sidebar meta)
///   memory:snapshot      → [memorySnapshot]      (goal/todos/facts)
///   approvals:snapshot   → [approvalsSnapshot]   (pending modals)
///   workspace:snapshot   → [workspaceSnapshot]   (legacy alias)
///
/// Sinks are [ValueNotifier]s so widgets can bind with a plain
/// `ValueListenableBuilder` and always see the freshest payload —
/// the sink holds at most ONE snapshot per type (the most recent
/// `join_session` wins).
library;

import 'package:flutter/foundation.dart';

class SessionSnapshotSinks {
  final ValueNotifier<Map<String, dynamic>?> onConnected =
      ValueNotifier(null);
  final ValueNotifier<Map<String, dynamic>?> previewSnapshot =
      ValueNotifier(null);
  final ValueNotifier<Map<String, dynamic>?> queueSnapshot =
      ValueNotifier(null);
  final ValueNotifier<Map<String, dynamic>?> activeOpsSnapshot =
      ValueNotifier(null);
  final ValueNotifier<Map<String, dynamic>?> sessionSnapshot =
      ValueNotifier(null);
  final ValueNotifier<Map<String, dynamic>?> memorySnapshot =
      ValueNotifier(null);
  final ValueNotifier<Map<String, dynamic>?> approvalsSnapshot =
      ValueNotifier(null);
  final ValueNotifier<Map<String, dynamic>?> workspaceSnapshot =
      ValueNotifier(null);

  /// Called by the router for every snapshot type. [envelope]
  /// carries top-level transport fields (seq, ts, session_id) —
  /// sinks store the payload, but we keep the envelope for
  /// consumers that need the seq (e.g. to compute `since` for the
  /// next join).
  void handleSnapshot(
    String type,
    Map<String, dynamic> payload, {
    required Map<String, dynamic> envelope,
  }) {
    switch (type) {
      case 'connected':
        onConnected.value = envelope;
      case 'preview:snapshot':
        previewSnapshot.value = payload;
      case 'queue:snapshot':
        queueSnapshot.value = payload;
      case 'active_ops:snapshot':
        activeOpsSnapshot.value = payload;
      case 'session:snapshot':
        sessionSnapshot.value = payload;
      case 'memory:snapshot':
        memorySnapshot.value = payload;
      case 'approvals:snapshot':
        approvalsSnapshot.value = payload;
      case 'workspace:snapshot':
        workspaceSnapshot.value = payload;
      default:
        debugPrint('SessionSnapshotSinks: unknown snapshot type $type');
    }
  }

  /// Drop all sinks — on session switch / logout. Preserves the
  /// ValueNotifier instances (widgets keep their subscriptions).
  void reset() {
    onConnected.value = null;
    previewSnapshot.value = null;
    queueSnapshot.value = null;
    activeOpsSnapshot.value = null;
    sessionSnapshot.value = null;
    memorySnapshot.value = null;
    approvalsSnapshot.value = null;
    workspaceSnapshot.value = null;
  }

  void dispose() {
    onConnected.dispose();
    previewSnapshot.dispose();
    queueSnapshot.dispose();
    activeOpsSnapshot.dispose();
    sessionSnapshot.dispose();
    memorySnapshot.dispose();
    approvalsSnapshot.dispose();
    workspaceSnapshot.dispose();
  }
}
