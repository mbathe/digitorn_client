/// Client-side view of a daemon-persisted message queue entry.
///
/// The daemon is the authoritative source — every field mirrors the
/// shape of `GET /api/apps/{app_id}/sessions/{sid}/queue`. Each entry
/// has a stable server-assigned id plus a client-generated
/// [correlationId] so the UI can optimistic-add before the POST
/// response lands and reconcile later.
library;

import 'package:flutter/foundation.dart';

enum QueueEntryStatus {
  /// Waiting in the FIFO queue, not yet picked by the dispatcher.
  queued,
  /// Being processed by the agent loop right now.
  running,
  /// Turn ended successfully.
  completed,
  /// Cancelled via DELETE /queue/{id}, POST /queue/clear, or POST /abort.
  cancelled,
  /// Turn failed (error from LLM, tool, etc.).
  failed;

  static QueueEntryStatus parse(String? s) {
    switch (s) {
      case 'queued':
        return QueueEntryStatus.queued;
      case 'running':
        return QueueEntryStatus.running;
      case 'completed':
        return QueueEntryStatus.completed;
      case 'cancelled':
        return QueueEntryStatus.cancelled;
      case 'failed':
        return QueueEntryStatus.failed;
    }
    return QueueEntryStatus.queued;
  }

  String get wireName => name;

  bool get isPending => this == QueueEntryStatus.queued;
  bool get isRunning => this == QueueEntryStatus.running;
  bool get isTerminal =>
      this == QueueEntryStatus.completed ||
      this == QueueEntryStatus.cancelled ||
      this == QueueEntryStatus.failed;
}

@immutable
class QueueEntry {
  /// Server-assigned row id — required for DELETE /queue/{id}. For
  /// optimistic entries not yet reconciled, this is the client-generated
  /// uuid used as [correlationId] too.
  final String id;
  /// Position in the FIFO queue (1-based). The running entry is at
  /// position 0 by convention; pending entries start at 1.
  final int position;
  /// Raw text of the user message.
  final String message;
  final QueueEntryStatus status;
  /// Client-generated correlation id set when the message was
  /// enqueued. Used to reconcile optimistic UI and to tie error
  /// events to the original submission.
  final String correlationId;
  final double? enqueuedAt;
  final double? startedAt;
  final double? finishedAt;
  final String errorCode;
  /// Only true for locally-added rows that haven't been confirmed by
  /// the daemon yet. `optimistic=true` implies [id] equals
  /// [correlationId] (both client-generated); on reconcile we replace
  /// the entry with the server's canonical row.
  final bool optimistic;

  const QueueEntry({
    required this.id,
    required this.position,
    required this.message,
    required this.status,
    required this.correlationId,
    this.enqueuedAt,
    this.startedAt,
    this.finishedAt,
    this.errorCode = '',
    this.optimistic = false,
  });

  factory QueueEntry.fromJson(Map<String, dynamic> m) => QueueEntry(
        id: (m['id'] ?? '') as String,
        position: (m['position'] as num?)?.toInt() ?? 0,
        message: (m['message'] ?? '') as String,
        status: QueueEntryStatus.parse(m['status'] as String?),
        correlationId: (m['correlation_id'] ?? '') as String,
        enqueuedAt: (m['enqueued_at'] as num?)?.toDouble(),
        startedAt: (m['started_at'] as num?)?.toDouble(),
        finishedAt: (m['finished_at'] as num?)?.toDouble(),
        errorCode: (m['error_code'] ?? '') as String,
      );

  /// Build the optimistic placeholder added to the local queue the
  /// moment the user hits Send — before the HTTP round-trip resolves.
  factory QueueEntry.optimistic({
    required String correlationId,
    required String message,
    required int position,
  }) =>
      QueueEntry(
        id: correlationId,
        position: position,
        message: message,
        status: QueueEntryStatus.queued,
        correlationId: correlationId,
        enqueuedAt: DateTime.now().microsecondsSinceEpoch / 1e6,
        optimistic: true,
      );

  QueueEntry copyWith({
    String? id,
    int? position,
    String? message,
    QueueEntryStatus? status,
    String? correlationId,
    double? enqueuedAt,
    double? startedAt,
    double? finishedAt,
    String? errorCode,
    bool? optimistic,
  }) =>
      QueueEntry(
        id: id ?? this.id,
        position: position ?? this.position,
        message: message ?? this.message,
        status: status ?? this.status,
        correlationId: correlationId ?? this.correlationId,
        enqueuedAt: enqueuedAt ?? this.enqueuedAt,
        startedAt: startedAt ?? this.startedAt,
        finishedAt: finishedAt ?? this.finishedAt,
        errorCode: errorCode ?? this.errorCode,
        optimistic: optimistic ?? this.optimistic,
      );
}

/// Outcome of `POST /messages` — the daemon either dispatches the
/// turn immediately (session was idle) or parks it in the queue.
/// `429` is returned to the HTTP client as [EnqueueResult.queueFull].
@immutable
class EnqueueResult {
  /// "accepted" | "queued" | "queue_full" | "error"
  final String status;
  /// Server-chosen correlation id (echoes the client's when provided).
  final String? correlationId;
  final int? position;
  final int? queueDepth;
  /// Error message for non-success results (transport, 5xx, etc.).
  /// Empty when [status] is "accepted" or "queued".
  final String? error;

  const EnqueueResult._({
    required this.status,
    this.correlationId,
    this.position,
    this.queueDepth,
    this.error,
  });

  factory EnqueueResult.accepted({String? correlationId}) =>
      EnqueueResult._(status: 'accepted', correlationId: correlationId);

  factory EnqueueResult.queued({
    required String correlationId,
    required int position,
    required int queueDepth,
  }) =>
      EnqueueResult._(
        status: 'queued',
        correlationId: correlationId,
        position: position,
        queueDepth: queueDepth,
      );

  factory EnqueueResult.queueFull({int? depth, int? max}) =>
      EnqueueResult._(
        status: 'queue_full',
        queueDepth: depth,
        error: max != null ? 'Queue full ($depth/$max)' : 'Queue full',
      );

  factory EnqueueResult.errored(String message) =>
      EnqueueResult._(status: 'error', error: message);

  bool get isOk => status == 'accepted' || status == 'queued';
  bool get wasQueued => status == 'queued';
  bool get wasAccepted => status == 'accepted';
  bool get wasRejected => status == 'queue_full' || status == 'error';
}
