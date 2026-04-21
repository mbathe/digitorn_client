/// One entry in the approval history returned by
/// `GET /workspace/files/{path}/history`.
///
/// Scout-verified shape:
/// ```
/// {
///   "revision": 2,
///   "approved_at": 1776611400.9,
///   "approved_by": "user" | "auto",
///   "tokens_delta_ins": 3,
///   "tokens_delta_del": 1,
///   "bytes": 58
/// }
/// ```
library;

class FileRevision {
  final int revision;
  final DateTime? approvedAt;
  /// `"user"` — user-initiated: explicit approve, or a PUT writeback
  /// (even one passing `auto_approve: true` as a shortcut — the
  /// action is still user-driven, scout-verified).
  /// `"auto"` — the **module-level** `auto_approve: true` config
  /// caused the baseline bump automatically on an agent write.
  final String approvedBy;
  final int tokensDeltaIns;
  final int tokensDeltaDel;
  final int bytes;

  const FileRevision({
    required this.revision,
    required this.approvedAt,
    required this.approvedBy,
    required this.tokensDeltaIns,
    required this.tokensDeltaDel,
    required this.bytes,
  });

  factory FileRevision.fromJson(Map<String, dynamic> json) {
    final ts = json['approved_at'];
    DateTime? at;
    if (ts is num) {
      at = DateTime.fromMillisecondsSinceEpoch((ts * 1000).toInt());
    }
    return FileRevision(
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      approvedAt: at,
      approvedBy: (json['approved_by'] as String?) ?? 'user',
      tokensDeltaIns: (json['tokens_delta_ins'] as num?)?.toInt() ?? 0,
      tokensDeltaDel: (json['tokens_delta_del'] as num?)?.toInt() ?? 0,
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
    );
  }

  bool get isAutoApproved => approvedBy == 'auto';
}
