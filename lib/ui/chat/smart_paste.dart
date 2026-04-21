/// Smart-paste transformer for the chat input. Detects what the user
/// just pasted (URL / JSON / structured code) and reformats it so the
/// chat looks tidy without the user having to re-format manually.
///
/// Pure functions — easy to unit-test, no Flutter imports.
library;

import 'dart:convert';

class SmartPasteResult {
  final String text;
  final String? hint;
  const SmartPasteResult(this.text, [this.hint]);
}

/// Take whatever the clipboard handed us and return either the
/// original string (when nothing matches) or a friendlier rendering.
SmartPasteResult transformPaste(String raw) {
  if (raw.isEmpty) return SmartPasteResult(raw);

  // 1. JSON — pretty-print if it parses, leave otherwise.
  final trimmed = raw.trim();
  if ((trimmed.startsWith('{') && trimmed.endsWith('}')) ||
      (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
    try {
      final parsed = jsonDecode(trimmed);
      final pretty = const JsonEncoder.withIndent('  ').convert(parsed);
      return SmartPasteResult('```json\n$pretty\n```', 'pretty-printed JSON');
    } catch (_) {
      // Not valid JSON — fall through.
    }
  }

  // 2. Single URL on its own line — leave as-is (the chat renderer
  //    already auto-links). No wrapping, no fancy markdown card —
  //    that would be visually noisy.
  if (_looksLikeBareUrl(trimmed)) {
    return SmartPasteResult(raw);
  }

  // 3. Already-fenced code block — leave it alone, the user knew
  //    what they were doing.
  if (trimmed.startsWith('```')) {
    return SmartPasteResult(raw);
  }

  // 4. Looks like code (multi-line, starts with whitespace or has
  //    `;`/`{}`/keywords) — auto-fence with a guessed language.
  if (_looksLikeCode(trimmed)) {
    final lang = _guessLanguage(trimmed);
    return SmartPasteResult(
      '```$lang\n$trimmed\n```',
      lang.isNotEmpty ? 'wrapped as $lang code' : 'wrapped as code',
    );
  }

  // 5. Default: pass through unchanged.
  return SmartPasteResult(raw);
}

bool _looksLikeBareUrl(String s) {
  if (s.contains('\n')) return false;
  final u = Uri.tryParse(s);
  return u != null &&
      (u.scheme == 'http' || u.scheme == 'https') &&
      u.host.isNotEmpty;
}

bool _looksLikeCode(String s) {
  if (!s.contains('\n')) return false;
  final lines = s.split('\n');
  if (lines.length < 2) return false;
  // Heuristic: at least 2 lines AND any of these signals.
  final indented = lines.where((l) => l.startsWith(RegExp(r'\s{2,}'))).length;
  final hasBraces = s.contains('{') && s.contains('}');
  final hasSemicolons = s.split(';').length > 2;
  final hasKeywords = RegExp(
          r'\b(function|class|def|import|return|const|let|var|public|private|void|fn)\b')
      .hasMatch(s);
  final hasArrows = s.contains('=>') || s.contains('->');
  return indented > 0 || hasBraces || hasSemicolons || hasKeywords || hasArrows;
}

String _guessLanguage(String s) {
  final lower = s.toLowerCase();
  if (lower.contains('def ') && lower.contains(':\n')) return 'python';
  if (lower.contains('import ') &&
      (lower.contains('from ') || lower.contains(' as '))) {
    return 'python';
  }
  if (lower.contains('package ') && lower.contains('func ')) return 'go';
  if (lower.contains('fn ') && lower.contains('->')) return 'rust';
  if (lower.contains('public class') ||
      lower.contains('public static void main')) {
    return 'java';
  }
  if (lower.contains('const ') ||
      lower.contains('let ') ||
      lower.contains('=>') ||
      lower.contains('console.log')) {
    return 'typescript';
  }
  if (lower.contains('#include') || lower.contains('std::')) return 'cpp';
  if (lower.contains('void ') && lower.contains(';')) return 'c';
  if (lower.contains('select ') &&
      lower.contains(' from ') &&
      !lower.contains('def ')) {
    return 'sql';
  }
  if (lower.contains('<html') || lower.contains('</div>')) return 'html';
  if (lower.contains('apiVersion:') || lower.contains('kind:')) return 'yaml';
  return '';
}
