/// Classification of a single line in a diff output.
enum DiffLineType { context, added, removed }

/// One line of a computed diff.
class DiffLine {
  final DiffLineType type;
  final String text;
  /// 1-based line number in the *new* file for added/context lines,
  /// or in the *old* file for removed lines. Zero means "no number".
  final int lineNum;

  const DiffLine(this.type, this.text, this.lineNum);
}

/// Summary of a diff's changes, useful for status bars / card headers.
class DiffStats {
  final int additions;
  final int deletions;
  const DiffStats({required this.additions, required this.deletions});

  static const empty = DiffStats(additions: 0, deletions: 0);
  int get total => additions + deletions;
  bool get isEmpty => total == 0;
}

/// Compute a line-level diff between [oldContent] and [newContent]
/// using a standard LCS (longest common subsequence) algorithm, then
/// collapse the output to keep **3 lines of context** around each
/// change for readability.
///
/// Special case: if [oldContent] is empty, every line of [newContent]
/// is reported as an addition — this is how "new file" diffs render.
///
/// Guard: LCS is O(m*n) in time and space. For files larger than
/// [_maxLcsCells] cells we fall back to a simple "delete old + add
/// new" diff to keep the UI thread free. 2000 × 2000 = 4M cells is
/// the practical ceiling before 60fps frames start dropping.
const int _maxLcsCells = 4000000;

List<DiffLine> computeLineDiff(String oldContent, String newContent) {
  final oldLines = oldContent.split('\n');
  final newLines = newContent.split('\n');

  if (oldContent.isEmpty) {
    return [
      for (var i = 0; i < newLines.length; i++)
        DiffLine(DiffLineType.added, newLines[i], i + 1),
    ];
  }

  final m = oldLines.length;
  final n = newLines.length;

  // Fall back to a trivial "all-remove + all-add" diff when the LCS
  // table would be enormous. The result is less compact but renders
  // correctly and doesn't freeze the app.
  if (m * n > _maxLcsCells) {
    return [
      for (var i = 0; i < m; i++) DiffLine(DiffLineType.removed, oldLines[i], i + 1),
      for (var i = 0; i < n; i++) DiffLine(DiffLineType.added, newLines[i], i + 1),
    ];
  }

  // Full LCS table needed for backtracking.
  final table = List.generate(m + 1, (_) => List.filled(n + 1, 0));
  for (var i = 1; i <= m; i++) {
    for (var j = 1; j <= n; j++) {
      if (oldLines[i - 1] == newLines[j - 1]) {
        table[i][j] = table[i - 1][j - 1] + 1;
      } else {
        table[i][j] = table[i - 1][j] > table[i][j - 1]
            ? table[i - 1][j]
            : table[i][j - 1];
      }
    }
  }

  // Backtrack to produce the raw diff.
  final result = <DiffLine>[];
  var i = m, j = n;
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && oldLines[i - 1] == newLines[j - 1]) {
      result.add(DiffLine(DiffLineType.context, newLines[j - 1], j));
      i--;
      j--;
    } else if (j > 0 && (i == 0 || table[i][j - 1] >= table[i - 1][j])) {
      result.add(DiffLine(DiffLineType.added, newLines[j - 1], j));
      j--;
    } else if (i > 0) {
      result.add(DiffLine(DiffLineType.removed, oldLines[i - 1], i));
      i--;
    }
  }

  final fullDiff = result.reversed.toList();

  // Collapse: keep 3 lines of context around each change. We track
  // "already included" indexes in a Set — previously this was
  // `collapsed.contains(...)` which scanned a growing list, turning
  // the collapse pass into O(n²) on large diffs.
  final included = <int>{};
  final collapsed = <DiffLine>[];
  void addIdx(int k) {
    if (k < 0 || k >= fullDiff.length) return;
    if (included.add(k)) collapsed.add(fullDiff[k]);
  }

  for (var k = 0; k < fullDiff.length; k++) {
    if (fullDiff[k].type == DiffLineType.context) continue;
    for (var c = (k - 3).clamp(0, k); c < k; c++) {
      addIdx(c);
    }
    addIdx(k);
    for (var c = k + 1; c <= (k + 3).clamp(0, fullDiff.length - 1); c++) {
      addIdx(c);
    }
  }

  return collapsed.isEmpty ? fullDiff : collapsed;
}

/// Count additions / deletions in a diff.
DiffStats summarise(List<DiffLine> diff) {
  var add = 0;
  var del = 0;
  for (final l in diff) {
    if (l.type == DiffLineType.added) add++;
    if (l.type == DiffLineType.removed) del++;
  }
  return DiffStats(additions: add, deletions: del);
}
