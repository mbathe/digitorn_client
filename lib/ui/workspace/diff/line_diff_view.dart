import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../theme/app_theme.dart';
import 'line_diff.dart';

/// VSCode-style diff renderer.
///
/// • Insertions get a subtle blue background, with a darker left rail.
/// • Deletions get a subtle red background with a darker left rail.
/// • Context lines are neutral.
///
/// A single gutter column shows the line number (new-side for added /
/// context lines, old-side for removed lines) so there is never a
/// duplicate rendering of the line number.
class LineDiffView extends StatelessWidget {
  final List<DiffLine> diff;

  /// When true, wraps the rows in an internal [ListView]. When false,
  /// returns a plain [Column] so the caller can embed it inside an
  /// outer scroll view (Changes panel, chat bubble, …).
  final bool scrollable;

  /// Font size, defaults to 12. Chat bubbles use a slightly smaller
  /// value to fit tightly.
  final double fontSize;

  const LineDiffView({
    super.key,
    required this.diff,
    this.scrollable = true,
    this.fontSize = 12,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final maxLineNum = diff.fold<int>(
      0, (m, l) => l.lineNum > m ? l.lineNum : m);
    // Width tracks the widest line number so columns stay aligned.
    final gutter = _gutterWidth(maxLineNum, fontSize);

    if (scrollable) {
      return Container(
        color: c.bg,
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: diff.length,
          itemBuilder: (_, i) => _DiffRow(
            line: diff[i], gutterWidth: gutter, fontSize: fontSize),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final l in diff)
          _DiffRow(line: l, gutterWidth: gutter, fontSize: fontSize),
      ],
    );
  }

  static double _gutterWidth(int maxLineNum, double fontSize) {
    final digits = maxLineNum <= 0 ? 2 : maxLineNum.toString().length;
    return (digits * (fontSize * 0.62)) + 14;
  }
}

class _DiffRow extends StatelessWidget {
  final DiffLine line;
  final double gutterWidth;
  final double fontSize;
  const _DiffRow({
    required this.line,
    required this.gutterWidth,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isAdd = line.type == DiffLineType.added;
    final isDel = line.type == DiffLineType.removed;

    final accent = isAdd ? c.green : isDel ? c.red : Colors.transparent;
    final bg = isAdd
        ? c.green.withValues(alpha: 0.12)
        : isDel
            ? c.red.withValues(alpha: 0.12)
            : Colors.transparent;
    final textColor = isAdd
        ? c.green
        : isDel
            ? c.red
            : c.text;
    final prefix = isAdd ? '+' : isDel ? '-' : ' ';

    return Container(
      color: bg,
      child: IntrinsicHeight(
        child: Row(
          children: [
            // Left rail — 2px strip in accent color for added/removed.
            Container(
              width: 2,
              color: accent,
            ),
            // Gutter: line number (right-aligned, monospace).
            SizedBox(
              width: gutterWidth,
              child: Padding(
                padding: const EdgeInsets.only(right: 6, left: 4),
                child: Text(
                  line.lineNum > 0 ? '${line.lineNum}' : '',
                  textAlign: TextAlign.right,
                  style: GoogleFonts.firaCode(
                      fontSize: fontSize - 1,
                      color: c.textDim,
                      height: 1.5),
                ),
              ),
            ),
            // +/-/space marker.
            SizedBox(
              width: 14,
              child: Text(
                prefix,
                textAlign: TextAlign.center,
                style: GoogleFonts.firaCode(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w600,
                    color: isAdd || isDel ? accent : c.textDim,
                    height: 1.5),
              ),
            ),
            // Code.
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  line.text,
                  style: GoogleFonts.firaCode(
                      fontSize: fontSize, color: textColor, height: 1.5),
                  overflow: TextOverflow.clip,
                  softWrap: false,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
