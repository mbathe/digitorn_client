/// Parser for git merge-conflict markers.
///
/// A conflict block is the canonical 3-line-marker shape git inserts:
///
/// ```
/// <<<<<<< HEAD
/// ours
/// =======
/// theirs
/// >>>>>>> branch-name
/// ```
///
/// This parser handles the plain-3-way shape and the diff3 variant
/// (`|||||||` base marker between ours and theirs). Nested conflicts
/// are NOT supported — git itself rarely emits them and the UI flow
/// punts to "reject whole file" as an escape hatch.
library;

class ConflictBlock {
  /// Line index (0-based) where `<<<<<<<` starts in the source.
  final int startLine;
  /// Line index (0-based) where `>>>>>>>` ends.
  final int endLine;
  /// Label after `<<<<<<<` (often `HEAD` or a branch name).
  final String oursLabel;
  /// Label after `>>>>>>>`.
  final String theirsLabel;
  /// Optional diff3 base label (`|||||||` line).
  final String? baseLabel;
  /// Ours content — lines between `<<<<<<<` and `|||||||`/`=======`.
  final List<String> ours;
  /// Base content — lines between `|||||||` and `=======` (diff3 only).
  final List<String>? base;
  /// Theirs content — lines between `=======` and `>>>>>>>`.
  final List<String> theirs;

  const ConflictBlock({
    required this.startLine,
    required this.endLine,
    required this.oursLabel,
    required this.theirsLabel,
    required this.ours,
    required this.theirs,
    this.baseLabel,
    this.base,
  });
}

class ConflictParseResult {
  /// Full source split into lines (preserves blank lines).
  final List<String> lines;
  /// Parsed conflict blocks in document order.
  final List<ConflictBlock> blocks;

  const ConflictParseResult({
    required this.lines,
    required this.blocks,
  });

  bool get hasConflicts => blocks.isNotEmpty;
}

ConflictParseResult parseConflicts(String source) {
  final lines = source.split('\n');
  final blocks = <ConflictBlock>[];

  int i = 0;
  while (i < lines.length) {
    final line = lines[i];
    if (!line.startsWith('<<<<<<<')) {
      i++;
      continue;
    }
    final oursLabel = line.substring(7).trim();
    final startLine = i;
    final ours = <String>[];
    final base = <String>[];
    final theirs = <String>[];
    String? baseLabel;
    int section = 0; // 0 = ours, 1 = base, 2 = theirs
    i++;
    int? endLine;
    String theirsLabel = '';
    while (i < lines.length) {
      final cur = lines[i];
      if (cur.startsWith('|||||||')) {
        baseLabel = cur.substring(7).trim();
        section = 1;
        i++;
        continue;
      }
      if (cur.startsWith('=======') && section < 2) {
        section = 2;
        i++;
        continue;
      }
      if (cur.startsWith('>>>>>>>')) {
        theirsLabel = cur.substring(7).trim();
        endLine = i;
        i++;
        break;
      }
      switch (section) {
        case 0:
          ours.add(cur);
        case 1:
          base.add(cur);
        case 2:
          theirs.add(cur);
      }
      i++;
    }
    if (endLine == null) {
      // Unterminated block — treat as no conflict, bail to avoid
      // infinite loops on malformed content.
      break;
    }
    blocks.add(ConflictBlock(
      startLine: startLine,
      endLine: endLine,
      oursLabel: oursLabel,
      theirsLabel: theirsLabel,
      baseLabel: baseLabel,
      ours: ours,
      base: base.isEmpty ? null : base,
      theirs: theirs,
    ));
  }

  return ConflictParseResult(lines: lines, blocks: blocks);
}

enum ConflictResolution { ours, theirs, both }

/// Rebuild the file content after applying [choices] to each
/// conflict block by index. Blocks without an entry in [choices]
/// stay untouched (render as markers) — the caller can enforce
/// "all resolved" before PUTting the result.
String applyResolutions(
  ConflictParseResult parsed,
  Map<int, ConflictResolution> choices,
) {
  final out = <String>[];
  int cursor = 0;
  for (var idx = 0; idx < parsed.blocks.length; idx++) {
    final block = parsed.blocks[idx];
    // Emit everything between cursor and the block start unchanged.
    for (int j = cursor; j < block.startLine; j++) {
      out.add(parsed.lines[j]);
    }
    final choice = choices[idx];
    if (choice == null) {
      // Leave markers intact.
      for (int j = block.startLine; j <= block.endLine; j++) {
        out.add(parsed.lines[j]);
      }
    } else {
      switch (choice) {
        case ConflictResolution.ours:
          out.addAll(block.ours);
        case ConflictResolution.theirs:
          out.addAll(block.theirs);
        case ConflictResolution.both:
          out.addAll(block.ours);
          out.addAll(block.theirs);
      }
    }
    cursor = block.endLine + 1;
  }
  // Tail after the last block.
  for (int j = cursor; j < parsed.lines.length; j++) {
    out.add(parsed.lines[j]);
  }
  return out.join('\n');
}
