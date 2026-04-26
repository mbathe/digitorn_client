/// Server-authored approval request — emitted on the `approval_request`
/// SSE event. The chat renders these inline with the rest of the
/// timeline (pinned to the envelope seq) so the card flows with the
/// conversation instead of sticking to the bottom of the pane.
library;

class ApprovalRequest {
  final String id;
  final String agentId;
  final String toolName;
  final Map<String, dynamic> params;
  final String riskLevel;
  final String description;
  final double createdAt;

  ApprovalRequest({
    required this.id,
    this.agentId = '',
    required this.toolName,
    required this.params,
    this.riskLevel = 'medium',
    this.description = '',
    double? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch / 1000;

  bool get isAskUser => toolName == 'ask_user';
  String get question =>
      isAskUser ? (params['question'] as String? ?? description) : description;
  String? get content => isAskUser ? params['content'] as String? : null;
  bool get hasLongContent => content != null && content!.length > 100;

  List<String>? get choices =>
      isAskUser ? (params['choices'] as List?)?.cast<String>() : null;
  bool get allowMultiple => params['allow_multiple'] as bool? ?? false;
  List<Map<String, dynamic>>? get formFields =>
      isAskUser ? (params['form'] as List?)?.cast<Map<String, dynamic>>() : null;
  bool get isSimpleQuestion =>
      isAskUser && choices == null && formFields == null && content == null;
  bool get isChoices => choices != null && choices!.isNotEmpty;
  bool get isForm => formFields != null && formFields!.isNotEmpty;
  bool get isContentReview =>
      isAskUser && content != null && content!.isNotEmpty && !isChoices && !isForm;
}
