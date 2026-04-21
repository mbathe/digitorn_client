import 'package:flutter/material.dart';

/// Artifact types we know how to render in the side panel.
/// Anything else falls back to a generic "code" block with syntax
/// highlighting and copy/download affordances.
enum ArtifactType {
  code,
  html,
  markdown,
  svg,
  mermaid,
  json,
  diff,
  csv,
  image,
  video,
}

extension ArtifactTypeX on ArtifactType {
  String get label => switch (this) {
        ArtifactType.code => 'Code',
        ArtifactType.html => 'HTML',
        ArtifactType.markdown => 'Markdown',
        ArtifactType.svg => 'SVG',
        ArtifactType.mermaid => 'Diagram',
        ArtifactType.json => 'JSON',
        ArtifactType.diff => 'Diff',
        ArtifactType.csv => 'Table',
        ArtifactType.image => 'Image',
        ArtifactType.video => 'Video',
      };

  IconData get icon => switch (this) {
        ArtifactType.code => Icons.code_rounded,
        ArtifactType.html => Icons.web_rounded,
        ArtifactType.markdown => Icons.article_outlined,
        ArtifactType.svg => Icons.image_outlined,
        ArtifactType.mermaid => Icons.account_tree_outlined,
        ArtifactType.json => Icons.data_object_rounded,
        ArtifactType.diff => Icons.difference_outlined,
        ArtifactType.csv => Icons.table_chart_outlined,
        ArtifactType.image => Icons.image_rounded,
        ArtifactType.video => Icons.movie_outlined,
      };

  /// True if the viewer supports a split "preview / source" toggle.
  /// Image and video default to preview (the "source" is just the
  /// URL / base64 blob — not useful to stare at).
  bool get hasPreview =>
      this == ArtifactType.html ||
      this == ArtifactType.markdown ||
      this == ArtifactType.svg ||
      this == ArtifactType.mermaid ||
      this == ArtifactType.diff ||
      this == ArtifactType.csv ||
      this == ArtifactType.image ||
      this == ArtifactType.video;
}

/// A chunk of content extracted from an assistant message that is
/// substantial enough to deserve its own viewer. Extracted by
/// [ArtifactDetector] and held in [ArtifactService].
///
/// When [isStreaming] is true the artifact represents an unclosed
/// fence still being generated — the pill renders a fixed-height
/// tail view so the user sees real-time progress. Gets flipped to
/// false at `message_done` when the closing fence arrives (or the
/// turn finishes).
class Artifact {
  final String id;
  final String messageId;
  final int index;
  final ArtifactType type;
  final String? language;
  final String? title;
  final String content;
  final DateTime createdAt;
  final bool isStreaming;

  const Artifact({
    required this.id,
    required this.messageId,
    required this.index,
    required this.type,
    required this.content,
    this.language,
    this.title,
    required this.createdAt,
    this.isStreaming = false,
  });

  Artifact copyWith({
    String? content,
    String? title,
    String? language,
    ArtifactType? type,
    bool? isStreaming,
  }) =>
      Artifact(
        id: id,
        messageId: messageId,
        index: index,
        type: type ?? this.type,
        content: content ?? this.content,
        language: language ?? this.language,
        title: title ?? this.title,
        createdAt: createdAt,
        isStreaming: isStreaming ?? this.isStreaming,
      );

  /// Convenience for the pill / panel title line.
  String get displayTitle {
    if (title != null && title!.isNotEmpty) return title!;
    if (language != null && language!.isNotEmpty) {
      return '${language!.toUpperCase()} · ${type.label}';
    }
    return type.label;
  }

  int get lineCount => content.split('\n').length;
}
