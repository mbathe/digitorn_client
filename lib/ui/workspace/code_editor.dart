import 'package:digitorn_client/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';
import 'package:diff_match_patch/diff_match_patch.dart' as dmp;

class CodeEditorPane extends StatefulWidget {
  final String content;
  final String previousContent;
  final String filename;
  final bool readOnly;
  final bool isEdited;
  const CodeEditorPane({
    super.key,
    this.content = '',
    this.previousContent = '',
    this.filename = 'untitled',
    this.readOnly = true,
    this.isEdited = false,
  });

  @override
  State<CodeEditorPane> createState() => _CodeEditorPaneState();
}

class _CodeEditorPaneState extends State<CodeEditorPane> {
  bool _showDiff = false;

  @override
  void initState() {
    super.initState();
    _showDiff = widget.isEdited && widget.previousContent.isNotEmpty;
  }

  @override
  void didUpdateWidget(CodeEditorPane old) {
    super.didUpdateWidget(old);
    if (old.content != widget.content &&
        widget.isEdited && widget.previousContent.isNotEmpty) {
      _showDiff = true;
    }
  }

  String get _extension {
    final parts = widget.filename.split('.');
    return parts.length > 1 ? parts.last : '';
  }

  bool get _hasDiff => widget.previousContent.isNotEmpty && widget.isEdited;

  int get _lineCount => widget.content.split('\n').length;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      color: c.bg,
      child: Column(
        children: [
          // File tab header
          Container(
            height: 36,
            color: c.surface,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Icon(_fileIcon(_extension), size: 14, color: _fileColor(_extension)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.filename,
                    style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Diff toggle
                if (_hasDiff)
                  GestureDetector(
                    onTap: () => setState(() => _showDiff = !_showDiff),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        color: _showDiff
                            ? c.green.withValues(alpha: 0.12)
                            : c.border,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(
                          color: _showDiff
                              ? c.green.withValues(alpha: 0.3)
                              : Colors.transparent,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.compare_arrows_rounded,
                              size: 11,
                              color: _showDiff ? c.green : c.textMuted),
                          const SizedBox(width: 3),
                          Text('Diff',
                            style: GoogleFonts.firaCode(
                              fontSize: 9,
                              color: _showDiff ? c.green : c.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (widget.isEdited)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      color: c.orange.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text('EDITED',
                      style: GoogleFonts.firaCode(fontSize: 9, color: c.orange)),
                  )
                else if (widget.readOnly)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: c.border,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text('READ-ONLY',
                      style: GoogleFonts.firaCode(fontSize: 9, color: c.textMuted)),
                  ),
              ],
            ),
          ),
          Container(height: 1, color: c.border),
          // Editor or Diff view
          Expanded(
            child: _showDiff && _hasDiff
                ? _DiffView(
                    oldContent: widget.previousContent,
                    newContent: widget.content,
                  )
                : _CodeViewer(
                    content: widget.content,
                    language: _hlLanguage(_extension),
                  ),
          ),
          // Status bar
          Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: c.surface,
              border: Border(top: BorderSide(color: c.border)),
            ),
            child: Row(
              children: [
                Text(
                  _extension.isNotEmpty ? _extension.toUpperCase() : 'PLAIN',
                  style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted),
                ),
                const Spacer(),
                Text(
                  '$_lineCount lines',
                  style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Code Viewer with line numbers + syntax highlighting ────────────────────

class _CodeViewer extends StatelessWidget {
  final String content;
  final String language;
  const _CodeViewer({required this.content, required this.language});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lines = content.split('\n');
    final lineNoWidth = '${lines.length}'.length;

    // Build syntax theme with transparent background
    final syntaxTheme = Map<String, TextStyle>.from(
      isDark ? atomOneDarkTheme : atomOneLightTheme,
    );
    syntaxTheme['root'] = (syntaxTheme['root'] ?? const TextStyle())
        .copyWith(backgroundColor: Colors.transparent);

    return Container(
      color: c.bg,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Line number gutter
          Container(
            width: (lineNoWidth * 8.5) + 20,
            padding: const EdgeInsets.only(top: 12),
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: c.border)),
            ),
            child: SelectionArea(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: lines.length,
                itemExtent: 20, // Fixed line height for alignment
                itemBuilder: (_, i) => SizedBox(
                  height: 20,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Text(
                      '${i + 1}'.padLeft(lineNoWidth),
                      textAlign: TextAlign.right,
                      style: GoogleFonts.firaCode(
                        fontSize: 12,
                        height: 20 / 12,
                        color: c.textDim,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Code content with syntax highlighting
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: HighlightView(
                content,
                language: language,
                theme: syntaxTheme,
                textStyle: GoogleFonts.firaCode(fontSize: 12, height: 20 / 12),
                padding: EdgeInsets.zero,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Helpers ────────────────────────────────────────────────────────────────

/// Map file extension to highlight.js language name
String _hlLanguage(String ext) => switch (ext) {
  'py'        => 'python',
  'dart'      => 'dart',
  'js'        => 'javascript',
  'jsx'       => 'javascript',
  'ts'        => 'typescript',
  'tsx'       => 'typescript',
  'html'      => 'xml',
  'css'       => 'css',
  'json'      => 'json',
  'yaml' || 'yml' => 'yaml',
  'md'        => 'markdown',
  'sh' || 'bash' => 'bash',
  'sql'       => 'sql',
  'xml'       => 'xml',
  'c'         => 'cpp',
  'cpp' || 'cc' || 'cxx' => 'cpp',
  'h' || 'hpp' => 'cpp',
  'java'      => 'java',
  'kt'        => 'kotlin',
  'swift'     => 'swift',
  'rs'        => 'rust',
  'go'        => 'go',
  'rb'        => 'ruby',
  'php'       => 'php',
  'toml'      => 'ini',
  'ini' || 'cfg' => 'ini',
  'dockerfile' => 'dockerfile',
  'makefile'  => 'makefile',
  _           => 'plaintext',
};

IconData _fileIcon(String ext) => switch (ext) {
  'py'   => Icons.code,
  'dart' => Icons.flutter_dash,
  'js' || 'jsx' || 'ts' || 'tsx' => Icons.javascript,
  'html' => Icons.html,
  'css'  => Icons.css,
  'json' => Icons.data_object,
  'yaml' || 'yml' => Icons.settings,
  'md'   => Icons.description,
  'sh' || 'bash' => Icons.terminal,
  'sql'  => Icons.storage,
  _ => Icons.insert_drive_file,
};

Color _fileColor(String ext) => switch (ext) {
  'py'   => const Color(0xFF3572A5),
  'dart' => const Color(0xFF02569B),
  'js' || 'jsx' => const Color(0xFFF7DF1E),
  'ts' || 'tsx' => const Color(0xFF3178C6),
  'html' => const Color(0xFFE34C26),
  'css'  => const Color(0xFF563D7C),
  'json' => const Color(0xFF555555),
  'yaml' || 'yml' => const Color(0xFFCB171E),
  'md'   => const Color(0xFF555555),
  'sh' || 'bash' => const Color(0xFF3FB950),
  'sql'  => const Color(0xFFE38C00),
  _ => const Color(0xFF555555),
};

// ─── Inline Diff View ────────────────────────────────────────────────────────

class _DiffView extends StatelessWidget {
  final String oldContent;
  final String newContent;
  const _DiffView({required this.oldContent, required this.newContent});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final oldLines = oldContent.split('\n');
    final newLines = newContent.split('\n');
    final diff = _computeDiff(oldLines, newLines);

    return Container(
      color: c.bg,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: diff.length,
        itemBuilder: (_, i) {
          final line = diff[i];
          final isAdd = line.type == _DiffType.added;
          final isDel = line.type == _DiffType.removed;

          final bg = isAdd
              ? c.green.withValues(alpha: 0.10)
              : isDel
                  ? c.red.withValues(alpha: 0.10)
                  : Colors.transparent;

          final textColor = isAdd
              ? c.green
              : isDel
                  ? c.red
                  : c.textMuted;

          final prefix = isAdd ? '+' : isDel ? '-' : ' ';

          return Container(
            color: bg,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                // Line number
                SizedBox(
                  width: 40,
                  child: Text(
                    line.lineNum > 0 ? '${line.lineNum}' : '',
                    textAlign: TextAlign.right,
                    style: GoogleFonts.firaCode(fontSize: 12, color: c.textDim),
                  ),
                ),
                // +/- prefix
                Container(
                  width: 20,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(
                        color: isAdd || isDel
                            ? textColor.withValues(alpha: 0.3)
                            : c.border.withValues(alpha: 0.3),
                        width: 1,
                      ),
                    ),
                  ),
                  child: Text(
                    prefix,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.firaCode(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: textColor,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Content
                Expanded(
                  child: Text(
                    line.text,
                    style: GoogleFonts.firaCode(
                      fontSize: 12, color: textColor, height: 1.5),
                    overflow: TextOverflow.clip,
                    softWrap: false,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

enum _DiffType { context, added, removed }

class _DiffLine {
  final _DiffType type;
  final String text;
  final int lineNum;
  const _DiffLine(this.type, this.text, this.lineNum);
}

/// Compute line-based diff using Google's diff_match_patch algorithm
List<_DiffLine> _computeDiff(List<String> oldLines, List<String> newLines) {
  final oldText = oldLines.join('\n');
  final newText = newLines.join('\n');

  final diffs = dmp.diff(oldText, newText);
  dmp.cleanupSemantic(diffs);

  final all = <_DiffLine>[];
  int lineNum = 1;

  for (final d in diffs) {
    final lines = d.text.split('\n');
    final trimmed = lines.last.isEmpty && lines.length > 1
        ? lines.sublist(0, lines.length - 1)
        : lines;

    for (final line in trimmed) {
      switch (d.operation) {
        case dmp.DIFF_EQUAL:
          all.add(_DiffLine(_DiffType.context, line, lineNum++));
        case dmp.DIFF_INSERT:
          all.add(_DiffLine(_DiffType.added, line, lineNum++));
        case dmp.DIFF_DELETE:
          all.add(_DiffLine(_DiffType.removed, line, 0));
        default:
          break;
      }
    }
  }

  // Collapse: show only 3 context lines around changes
  final result = <_DiffLine>[];
  for (int i = 0; i < all.length; i++) {
    if (all[i].type != _DiffType.context) {
      for (int j = (i - 3).clamp(0, i); j < i; j++) {
        if (!result.contains(all[j])) result.add(all[j]);
      }
      result.add(all[i]);
    } else {
      final hasRecentChange = all.skip((i - 3).clamp(0, i)).take(4).any(
          (r) => r.type != _DiffType.context);
      if (hasRecentChange && !result.contains(all[i])) {
        result.add(all[i]);
      }
    }
  }

  return result.isEmpty ? all : result;
}
