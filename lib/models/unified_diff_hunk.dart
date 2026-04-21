/// Parser for `unified_diff_pending` that mirrors the daemon's exact
/// hash algorithm so per-hunk approve/reject calls can reference a
/// stable identifier even when an agent races the user mid-diff.
///
/// Scout-verified 1:1 against `_parse_unified_diff_hunks` +
/// `_finalize_hunk` in `digitorn-bridge/packages/digitorn/modules/
/// workspace/module.py`. The formulas match on:
///
///   * hash = `sha256(header + "\n" + body.join("\n"))[:12]`
///   * body only keeps lines whose first char is ` `, `-`, or `+`
///     (empty strings from the trailing split + `---/+++` file
///     markers are filtered — they never reach the body)
///
/// If the daemon's formula ever changes, the scout
/// `scout/scout_workspace_validation.py` will fail on
/// "approve-hunks HTTP 200" — that's the early-warning gate.
library;

import 'dart:convert';
import 'package:crypto/crypto.dart';

class UnifiedDiffHunk {
  final int index;
  final String hash;
  final String header;
  final int oldStart;
  final int oldLen;
  final int newStart;
  final int newLen;
  final List<String> body;

  const UnifiedDiffHunk({
    required this.index,
    required this.hash,
    required this.header,
    required this.oldStart,
    required this.oldLen,
    required this.newStart,
    required this.newLen,
    required this.body,
  });

  int get insertions =>
      body.where((l) => l.isNotEmpty && l[0] == '+').length;
  int get deletions =>
      body.where((l) => l.isNotEmpty && l[0] == '-').length;
}

final _hunkHeader = RegExp(
  r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@',
);

String _hunkHash(String header, List<String> body) {
  final src = '$header\n${body.join("\n")}';
  final digest = sha256.convert(utf8.encode(src));
  return digest.toString().substring(0, 12);
}

List<UnifiedDiffHunk> parseUnifiedDiffHunks(String diff) {
  if (diff.isEmpty) return const [];
  final hunks = <UnifiedDiffHunk>[];
  String? header;
  int oldStart = 0, oldLen = 1, newStart = 0, newLen = 1;
  final body = <String>[];

  void flush() {
    if (header == null) return;
    final hash = _hunkHash(header!, body);
    hunks.add(UnifiedDiffHunk(
      index: hunks.length,
      hash: hash,
      header: header!,
      oldStart: oldStart,
      oldLen: oldLen,
      newStart: newStart,
      newLen: newLen,
      body: List.unmodifiable(body),
    ));
    header = null;
    body.clear();
  }

  for (final line in diff.split('\n')) {
    if (line.startsWith('@@')) {
      flush();
      final m = _hunkHeader.firstMatch(line);
      if (m == null) continue;
      header = line;
      oldStart = int.parse(m.group(1)!);
      oldLen = int.tryParse(m.group(2) ?? '1') ?? 1;
      newStart = int.parse(m.group(3)!);
      newLen = int.tryParse(m.group(4) ?? '1') ?? 1;
    } else if (header != null &&
        line.isNotEmpty &&
        (line[0] == ' ' || line[0] == '-' || line[0] == '+')) {
      body.add(line);
    }
  }
  flush();
  return hunks;
}
