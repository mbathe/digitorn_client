import 'line_diff.dart';

/// Check if [text] looks like a standard unified diff. We don't need
/// a bulletproof parser — just enough signal to decide whether to
/// call [parseUnifiedDiff] or fall back to [computeLineDiff].
bool looksLikeUnifiedDiff(String text) {
  if (text.isEmpty) return false;
  return text.contains('@@') &&
      (text.contains('\n+') ||
          text.contains('\n-') ||
          text.startsWith('+') ||
          text.startsWith('-'));
}

/// One-shot resolver: given whatever diff artefacts the daemon sent,
/// return the best available rendering.
///
/// Priority:
///   1. [unifiedDiff] if it's actually in unified format.
///   2. [previousContent] + [newContent] via LCS.
///   3. An empty list — callers show a "no diff available" placeholder.
List<DiffLine> chooseDiff({
  String? unifiedDiff,
  String? previousContent,
  String? newContent,
}) {
  if (unifiedDiff != null &&
      unifiedDiff.trim().isNotEmpty &&
      looksLikeUnifiedDiff(unifiedDiff)) {
    final parsed = parseUnifiedDiff(unifiedDiff);
    if (parsed.isNotEmpty) return parsed;
  }
  if (previousContent != null && newContent != null) {
    return computeLineDiff(previousContent, newContent);
  }
  // New file with no diff: treat everything as additions.
  if (newContent != null && newContent.isNotEmpty) {
    return computeLineDiff('', newContent);
  }
  return const <DiffLine>[];
}

/// Parse a standard unified diff string into a list of [DiffLine].
///
/// Handles:
///   - File headers (`--- a/...`, `+++ b/...`) → ignored.
///   - Hunk headers (`@@ -10,5 +10,6 @@`) → reset line counters.
///   - Lines starting with `+` / `-` / ` ` inside a hunk.
///   - `\ No newline at end of file` → skipped.
///
/// Line numbers are assigned from the hunk header: added / context lines
/// get their *new* line number, removed lines get their *old* line number.
/// Passing [collapse] = true keeps the hunk framing without extra fluff
/// (there is no extra logic needed — the diff already contains the
/// context you want).
List<DiffLine> parseUnifiedDiff(String diff) {
  final lines = diff.split('\n');
  final out = <DiffLine>[];

  int oldLine = 0;
  int newLine = 0;
  bool inHunk = false;

  final hunkRe = RegExp(r'^@@\s*-(\d+)(?:,\d+)?\s+\+(\d+)(?:,\d+)?\s*@@');

  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (l.startsWith('diff ') ||
        l.startsWith('index ') ||
        l.startsWith('--- ') ||
        l.startsWith('+++ ') ||
        l.startsWith('\\ ')) {
      continue;
    }
    final m = hunkRe.firstMatch(l);
    if (m != null) {
      oldLine = int.parse(m.group(1)!);
      newLine = int.parse(m.group(2)!);
      inHunk = true;
      continue;
    }
    if (!inHunk) continue;

    // Inside a hunk, the first char determines line role. A truly
    // empty line is a context line with no content — rare but valid.
    if (l.isEmpty) {
      out.add(DiffLine(DiffLineType.context, '', newLine));
      oldLine++;
      newLine++;
      continue;
    }

    final head = l[0];
    final text = l.substring(1);
    switch (head) {
      case '+':
        out.add(DiffLine(DiffLineType.added, text, newLine));
        newLine++;
        break;
      case '-':
        out.add(DiffLine(DiffLineType.removed, text, oldLine));
        oldLine++;
        break;
      case ' ':
        out.add(DiffLine(DiffLineType.context, text, newLine));
        oldLine++;
        newLine++;
        break;
      default:
        // Unknown prefix — treat as raw text so nothing is silently lost.
        out.add(DiffLine(DiffLineType.context, l, newLine));
    }
  }

  return out;
}
