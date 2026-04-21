import 'artifact.dart';

/// Scans assistant message text for content blocks substantial
/// enough to be promoted into the artifact side panel. Everything
/// else (small snippets, inline code) stays rendered in the chat
/// bubble.
///
/// Heuristics:
///   - code block with `lang == html | svg | mermaid` → always artifact
///   - code block with `lang == markdown | mdx` and ≥ 20 lines
///   - code block with `lang == json` and ≥ 40 lines (or first
///     line looks like an object/array and content ≥ 40 lines)
///   - any other code block ≥ 40 lines → artifact (as plain code)
class ArtifactDetector {
  // Lowered from 40 to 20: a 20+ line code block is already enough
  // to bloat a chat bubble and benefit from a dedicated viewer.
  static const _codeBlockMinLines = 20;
  static const _markdownMinLines = 20;
  static const _jsonMinLines = 40;

  /// Regex matching ```lang\n...\n``` with named groups.
  /// Multiline greedy with DOTALL equivalent.
  static final _fenceRe = RegExp(
    r'```([a-zA-Z0-9_+\-]*)\s*\n([\s\S]*?)\n?```',
    multiLine: true,
  );

  /// Same shape as [_fenceRe] but tolerates a missing closing fence
  /// — the tail matches `\n```` OR end-of-string. Used by
  /// [extractStreaming] so an in-progress artefact surfaces as a
  /// pill the moment we see its opening fence, not only once the
  /// turn is done.
  static final _partialFenceRe = RegExp(
    r'```([a-zA-Z0-9_+\-]*)\s*\n([\s\S]*?)(?:\n```|$)',
    multiLine: true,
  );

  /// Extract artifacts from a message's text. Returns the list of
  /// artifacts AND a rewritten message where each artifact span is
  /// replaced by a placeholder `[[artifact:<id>]]` that the bubble
  /// renderer swaps for an inline pill.
  static ArtifactExtractionResult extract({
    required String messageId,
    required String text,
  }) {
    return _run(
      messageId: messageId,
      text: text,
      regex: _fenceRe,
      allowStreaming: false,
    );
  }

  /// Streaming-aware variant. Matches both closed and unclosed
  /// fences (the trailing ``` is optional), so we can show a live
  /// pill while the agent is still generating the body. Artifacts
  /// built from an unclosed fence carry `isStreaming: true`.
  ///
  /// Unclosed fences below the promotion threshold are emitted as
  /// streaming artefacts anyway — we can't know the final size yet,
  /// and showing the live pill for a file that later stays short is
  /// acceptable (the pill just disappears at message_done).
  static ArtifactExtractionResult extractStreaming({
    required String messageId,
    required String text,
  }) {
    return _run(
      messageId: messageId,
      text: text,
      regex: _partialFenceRe,
      allowStreaming: true,
    );
  }

  static ArtifactExtractionResult _run({
    required String messageId,
    required String text,
    required RegExp regex,
    required bool allowStreaming,
  }) {
    final matches = regex.allMatches(text).toList();
    if (matches.isEmpty) {
      return ArtifactExtractionResult(artifacts: const [], rewritten: text);
    }
    final artifacts = <Artifact>[];
    final buffer = StringBuffer();
    int cursor = 0;
    int artifactIndex = 0;
    for (final m in matches) {
      final lang = (m.group(1) ?? '').trim().toLowerCase();
      final body = m.group(2) ?? '';
      final matchEndsBeforeEof = m.end < text.length;
      // If the regex consumed the body up to end-of-string without a
      // closing fence, the artefact is still streaming.
      final isStreaming = allowStreaming && !matchEndsBeforeEof &&
          !text.substring(m.start).contains('\n```');
      final lineCount = body.split('\n').length;
      final shouldPromote = isStreaming
          ? _shouldPromoteStreaming(lang, lineCount)
          : _shouldPromote(lang, lineCount);
      if (!shouldPromote) continue;
      final type = _typeForLang(lang);
      final id = '$messageId-art-$artifactIndex';
      final title = _inferTitle(type, lang, body);
      artifacts.add(Artifact(
        id: id,
        messageId: messageId,
        index: artifactIndex,
        type: type,
        language: lang.isEmpty ? null : lang,
        title: title,
        content: body,
        createdAt: DateTime.now(),
        isStreaming: isStreaming,
      ));
      buffer.write(text.substring(cursor, m.start));
      buffer.write('[[artifact:$id]]');
      cursor = m.end;
      artifactIndex++;
    }
    buffer.write(text.substring(cursor));
    return ArtifactExtractionResult(
      artifacts: artifacts,
      rewritten: buffer.toString(),
    );
  }

  // Diff / CSV are valuable even when short (a 5-line diff is
  // already worth its own viewer) — lower threshold than generic
  // code so agents emitting small patches get nice rendering.
  static const _diffMinLines = 4;
  static const _csvMinLines = 4;

  static bool _shouldPromote(String lang, int lineCount) {
    switch (lang) {
      case 'html':
      case 'svg':
      case 'mermaid':
      case 'image':
      case 'img':
      case 'video':
        return true;
      case 'markdown':
      case 'mdx':
      case 'md':
        return lineCount >= _markdownMinLines;
      case 'json':
        return lineCount >= _jsonMinLines;
      case 'diff':
      case 'patch':
        return lineCount >= _diffMinLines;
      case 'csv':
      case 'tsv':
        return lineCount >= _csvMinLines;
      default:
        return lineCount >= _codeBlockMinLines;
    }
  }

  /// During streaming we don't yet know the final size. We still
  /// promote as soon as we see the opening fence for the "preview-
  /// heavy" languages (html/svg/mermaid — those are always artefacts
  /// at any size). For everything else we wait until the streaming
  /// body passes the threshold — avoids flashing a pill for a
  /// 5-line snippet that would never have been an artefact anyway.
  static bool _shouldPromoteStreaming(String lang, int lineCount) {
    switch (lang) {
      case 'html':
      case 'svg':
      case 'mermaid':
      case 'image':
      case 'img':
      case 'video':
        return true;
      case 'markdown':
      case 'mdx':
      case 'md':
        return lineCount >= _markdownMinLines;
      case 'json':
        return lineCount >= _jsonMinLines;
      case 'diff':
      case 'patch':
        return lineCount >= _diffMinLines;
      case 'csv':
      case 'tsv':
        return lineCount >= _csvMinLines;
      default:
        return lineCount >= _codeBlockMinLines;
    }
  }

  static ArtifactType _typeForLang(String lang) {
    switch (lang) {
      case 'html':
        return ArtifactType.html;
      case 'svg':
        return ArtifactType.svg;
      case 'mermaid':
        return ArtifactType.mermaid;
      case 'markdown':
      case 'mdx':
      case 'md':
        return ArtifactType.markdown;
      case 'json':
        return ArtifactType.json;
      case 'diff':
      case 'patch':
        return ArtifactType.diff;
      case 'csv':
      case 'tsv':
        return ArtifactType.csv;
      case 'image':
      case 'img':
        return ArtifactType.image;
      case 'video':
        return ArtifactType.video;
      default:
        return ArtifactType.code;
    }
  }

  /// Best-effort title extraction. Looks for the first markdown
  /// heading, HTML `<title>`, code-style leading comment, or the
  /// first non-empty line — whichever produces a short, readable
  /// label.
  static String? _inferTitle(ArtifactType type, String lang, String body) {
    final lines = body.split('\n');
    if (type == ArtifactType.html) {
      final title = RegExp(
        r'<title[^>]*>([^<]+)</title>',
        caseSensitive: false,
      ).firstMatch(body)?.group(1)?.trim();
      if (title != null && title.isNotEmpty) return _cap(title);
    }
    if (type == ArtifactType.markdown) {
      for (final l in lines) {
        final h = RegExp(r'^\s*#{1,3}\s+(.+?)\s*$').firstMatch(l);
        if (h != null) return _cap(h.group(1)!);
      }
    }
    // Leading comment line (//, #, /*).
    for (final l in lines.take(4)) {
      final c = RegExp(r'^\s*(?://|#|/\*|\*)\s*(.{4,80})')
          .firstMatch(l);
      if (c != null) {
        final raw = c.group(1)!.trim().replaceAll(RegExp(r'\*+\s*\$'), '');
        if (raw.isNotEmpty && !raw.startsWith('-')) {
          return _cap(raw);
        }
      }
    }
    return null;
  }

  static String _cap(String s, {int max = 60}) {
    final trimmed = s.trim();
    if (trimmed.length <= max) return trimmed;
    return '${trimmed.substring(0, max - 1)}…';
  }
}

class ArtifactExtractionResult {
  final List<Artifact> artifacts;
  final String rewritten;

  const ArtifactExtractionResult({
    required this.artifacts,
    required this.rewritten,
  });

  bool get hasArtifacts => artifacts.isNotEmpty;
}
