import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../theme/app_theme.dart';
import 'file_viewer.dart';
import 'notebook/notebook_parser.dart';

/// Renders Jupyter notebooks (.ipynb) with code cells, markdown cells,
/// and the full menagerie of cell outputs (stream stdout/stderr,
/// text/plain, image/png+jpeg base64, errors with stripped ANSI
/// tracebacks). Markdown cells are rendered with the same style as
/// the dedicated [MarkdownFileViewer] for visual consistency, and
/// code cells use [HighlightView] like [CodeEditorPane].
///
/// HTML and SVG outputs are *recognised* but rendered as collapsed
/// "rich output" placeholders for now (Flutter has no first-class
/// HTML renderer, and `flutter_svg` is not yet a project dependency).
/// The text/plain fallback that Jupyter always emits alongside rich
/// outputs is used as the visible representation, so dataframes /
/// numpy arrays / etc. still display correctly as text.
class NotebookFileViewer extends FileViewer {
  const NotebookFileViewer();

  @override
  String get id => 'notebook';

  @override
  int get priority => 100;

  @override
  Set<String> get extensions => const {'ipynb'};

  @override
  Widget build(BuildContext context, ViewerContext vctx) {
    return _NotebookPane(
      key: ValueKey('notebook-${vctx.buffer.path}'),
      content: vctx.buffer.content,
      filename: vctx.buffer.filename,
    );
  }
}

class _NotebookPane extends StatefulWidget {
  final String content;
  final String filename;
  const _NotebookPane({
    super.key,
    required this.content,
    required this.filename,
  });

  @override
  State<_NotebookPane> createState() => _NotebookPaneState();
}

class _NotebookPaneState extends State<_NotebookPane> {
  late NotebookDocument _doc;

  @override
  void initState() {
    super.initState();
    _doc = NotebookDocument.parse(widget.content);
  }

  @override
  void didUpdateWidget(_NotebookPane old) {
    super.didUpdateWidget(old);
    if (old.content != widget.content) {
      _doc = NotebookDocument.parse(widget.content);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      color: c.bg,
      child: Column(
        children: [
          _buildHeader(c),
          Container(height: 1, color: c.border),
          Expanded(child: _buildBody(c)),
          _buildStatusBar(c),
        ],
      ),
    );
  }

  Widget _buildHeader(AppColors c) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      color: c.surface,
      child: Row(
        children: [
          Icon(Icons.book_outlined, size: 14, color: c.orange),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.filename,
              style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_doc.isValid && _doc.kernelSummary.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: c.border),
              ),
              child: Text(
                _doc.kernelSummary,
                style: GoogleFonts.firaCode(
                    fontSize: 9, color: c.textMuted),
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: c.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: c.orange.withValues(alpha: 0.3)),
            ),
            child: Text(
              'IPYNB',
              style: GoogleFonts.firaCode(
                  fontSize: 9,
                  color: c.orange,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(AppColors c) {
    if (!_doc.isValid) {
      return _buildErrorState(c, _doc.parseError ?? 'Unknown error');
    }
    if (_doc.isEmpty) {
      return _buildEmptyState(c);
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      itemCount: _doc.cells.length,
      itemBuilder: (_, i) => _CellView(
        cell: _doc.cells[i],
        cellIndex: i,
        language: _doc.language ?? 'python',
      ),
    );
  }

  Widget _buildStatusBar(AppColors c) {
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Text(
            '${_doc.cells.length} cells '
            '(${_doc.codeCellCount} code, ${_doc.markdownCellCount} md)',
            style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted),
          ),
          const Spacer(),
          Text(
            'nbformat ${_doc.nbformat}.${_doc.nbformatMinor}',
            style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(AppColors c) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.book_outlined, size: 36, color: c.textMuted),
          const SizedBox(height: 12),
          Text('Empty notebook',
              style: GoogleFonts.inter(
                  fontSize: 13,
                  color: c.textMuted,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _buildErrorState(AppColors c, String error) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 36, color: c.red),
              const SizedBox(height: 12),
              Text('Cannot parse notebook',
                  style: GoogleFonts.inter(
                      fontSize: 14,
                      color: c.text,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(
                error,
                textAlign: TextAlign.center,
                style: GoogleFonts.firaCode(
                    fontSize: 11, color: c.textMuted, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Cell rendering ────────────────────────────────────────────────────────

class _CellView extends StatelessWidget {
  final NotebookCell cell;
  final int cellIndex;
  final String language;
  const _CellView({
    required this.cell,
    required this.cellIndex,
    required this.language,
  });

  @override
  Widget build(BuildContext context) {
    final cell = this.cell;
    if (cell is CodeCell) return _CodeCellView(cell: cell, language: language);
    if (cell is MarkdownCell) return _MarkdownCellView(cell: cell);
    if (cell is RawCell) return _RawCellView(cell: cell);
    return const SizedBox.shrink();
  }
}

class _CodeCellView extends StatelessWidget {
  final CodeCell cell;
  final String language;
  const _CodeCellView({required this.cell, required this.language});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: c.codeBlockBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Code source row ────────────────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CellPrompt(label: cell.prompt, color: c.blue),
              Expanded(
                child: _CodeBlock(
                    source: cell.source, language: language),
              ),
            ],
          ),
          // ── Outputs (if any) ───────────────────────────────────────
          if (cell.outputs.isNotEmpty) ...[
            Container(height: 1, color: c.border),
            for (final out in cell.outputs)
              _OutputView(output: out),
          ],
        ],
      ),
    );
  }
}

class _MarkdownCellView extends StatelessWidget {
  final MarkdownCell cell;
  const _MarkdownCellView({required this.cell});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: MarkdownBody(
        data: cell.source,
        selectable: true,
        styleSheet: MarkdownStyleSheet(
          p: GoogleFonts.inter(
              fontSize: 14, color: c.text, height: 1.65),
          h1: GoogleFonts.inter(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: c.text),
          h2: GoogleFonts.inter(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: c.text),
          h3: GoogleFonts.inter(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: c.text),
          code: GoogleFonts.firaCode(
              fontSize: 12.5,
              color: c.purple,
              backgroundColor: c.codeBg),
          codeblockDecoration: BoxDecoration(
            color: c.codeBlockBg,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: c.border),
          ),
          blockquoteDecoration: BoxDecoration(
            border: Border(
                left: BorderSide(color: c.borderHover, width: 2.5)),
          ),
          strong: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: c.text),
        ),
      ),
    );
  }
}

class _RawCellView extends StatelessWidget {
  final RawCell cell;
  const _RawCellView({required this.cell});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.border),
      ),
      child: SelectableText(
        cell.source,
        style: GoogleFonts.firaCode(
            fontSize: 12, color: c.textMuted, height: 1.5),
      ),
    );
  }
}

// ─── Output rendering ──────────────────────────────────────────────────────

class _OutputView extends StatelessWidget {
  final NotebookOutput output;
  const _OutputView({required this.output});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final out = output;

    if (out is StreamOutput) {
      return _OutputContainer(
        prompt: null,
        child: SelectableText(
          out.text,
          style: GoogleFonts.firaCode(
            fontSize: 11.5,
            height: 1.45,
            color: out.isStderr ? c.red : c.text,
          ),
        ),
      );
    }

    if (out is DisplayDataOutput) {
      return _DisplayDataView(output: out);
    }

    if (out is ErrorOutput) {
      return _OutputContainer(
        prompt: null,
        background: c.red.withValues(alpha: 0.07),
        leftBorder: c.red,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline_rounded, size: 13, color: c.red),
                const SizedBox(width: 6),
                Flexible(
                  child: SelectableText(
                    '${out.ename}: ${out.evalue}',
                    style: GoogleFonts.firaCode(
                        fontSize: 12,
                        color: c.red,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            if (out.traceback.isNotEmpty) ...[
              const SizedBox(height: 6),
              SelectableText(
                out.prettyTraceback,
                style: GoogleFonts.firaCode(
                    fontSize: 11, color: c.text, height: 1.45),
              ),
            ],
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }
}

class _DisplayDataView extends StatelessWidget {
  final DisplayDataOutput output;
  const _DisplayDataView({required this.output});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    // Priority: PNG > JPEG > SVG (placeholder) > HTML (placeholder) >
    // application/json (pretty) > text/plain.
    final png = output.imagePng;
    final jpeg = output.imageJpeg;
    final svg = output.imageSvg;
    final html = output.textHtml;
    final json = output.json;
    final plain = output.textPlain;

    Widget child;
    if (png != null && png.isNotEmpty) {
      child = _Base64Image(data: png);
    } else if (jpeg != null && jpeg.isNotEmpty) {
      child = _Base64Image(data: jpeg);
    } else if (svg != null && svg.isNotEmpty) {
      child = _RichOutputPlaceholder(
        label: 'SVG output',
        fallback: plain,
      );
    } else if (json != null && json.isNotEmpty) {
      child = _JsonPretty(raw: json);
    } else if (html != null && html.isNotEmpty) {
      // We don't render arbitrary HTML, but plain almost always exists
      // alongside it (DataFrame.repr_html() etc.) so prefer plain.
      if (plain != null && plain.isNotEmpty) {
        child = SelectableText(
          plain,
          style: GoogleFonts.firaCode(
              fontSize: 11.5, color: c.text, height: 1.45),
        );
      } else {
        child = _RichOutputPlaceholder(
          label: 'HTML output',
          fallback: null,
        );
      }
    } else if (plain != null && plain.isNotEmpty) {
      child = SelectableText(
        plain,
        style: GoogleFonts.firaCode(
            fontSize: 11.5, color: c.text, height: 1.45),
      );
    } else {
      // Unknown / empty output — show its mime keys for debugging.
      child = Text(
        '[empty output: ${output.data.keys.join(", ")}]',
        style: GoogleFonts.firaCode(fontSize: 10, color: c.textDim),
      );
    }

    return _OutputContainer(
      prompt: output.prompt,
      promptColor: c.red,
      child: child,
    );
  }
}

class _Base64Image extends StatelessWidget {
  final String data;
  const _Base64Image({required this.data});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    try {
      // Some payloads include `data:image/png;base64,` prefix; strip it.
      final stripped =
          data.contains(',') ? data.substring(data.indexOf(',') + 1) : data;
      final bytes = base64Decode(stripped.replaceAll(RegExp(r'\s'), ''));
      return Container(
        constraints: const BoxConstraints(maxHeight: 600),
        alignment: Alignment.centerLeft,
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => _imageError(c),
        ),
      );
    } catch (_) {
      return _imageError(c);
    }
  }

  Widget _imageError(AppColors c) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined, size: 14, color: c.red),
          const SizedBox(width: 6),
          Text('Cannot decode image output',
              style: GoogleFonts.firaCode(fontSize: 11, color: c.red)),
        ],
      );
}

class _JsonPretty extends StatelessWidget {
  final String raw;
  const _JsonPretty({required this.raw});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    String pretty;
    try {
      final parsed = jsonDecode(raw);
      pretty = const JsonEncoder.withIndent('  ').convert(parsed);
    } catch (_) {
      pretty = raw;
    }
    return SelectableText(
      pretty,
      style: GoogleFonts.firaCode(
          fontSize: 11, color: c.text, height: 1.45),
    );
  }
}

class _RichOutputPlaceholder extends StatelessWidget {
  final String label;
  final String? fallback;
  const _RichOutputPlaceholder({required this.label, required this.fallback});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            label,
            style: GoogleFonts.firaCode(
                fontSize: 9,
                color: c.textMuted,
                fontWeight: FontWeight.w600),
          ),
        ),
        if (fallback != null && fallback!.isNotEmpty) ...[
          const SizedBox(height: 6),
          SelectableText(
            fallback!,
            style: GoogleFonts.firaCode(
                fontSize: 11.5, color: c.text, height: 1.45),
          ),
        ],
      ],
    );
  }
}

// ─── Shared layout helpers ─────────────────────────────────────────────────

/// Fixed-width prompt column on the left of every cell row, e.g.
/// `In [5]:` or `Out[5]:`. Empty space when [label] is null.
class _CellPrompt extends StatelessWidget {
  final String? label;
  final Color color;
  const _CellPrompt({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 70,
      child: Padding(
        padding: const EdgeInsets.only(top: 12, left: 10, right: 8),
        child: label == null
            ? const SizedBox.shrink()
            : Text(
                label!,
                style: GoogleFonts.firaCode(
                    fontSize: 10,
                    color: color,
                    fontWeight: FontWeight.w600),
              ),
      ),
    );
  }
}

/// Background container used by every output, with optional left
/// accent border for errors and an optional Out[N] prompt column.
class _OutputContainer extends StatelessWidget {
  final String? prompt;
  final Color? promptColor;
  final Widget child;
  final Color? background;
  final Color? leftBorder;
  const _OutputContainer({
    required this.prompt,
    this.promptColor,
    required this.child,
    this.background,
    this.leftBorder,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      color: background,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CellPrompt(label: prompt, color: promptColor ?? c.red),
          if (leftBorder != null)
            Container(width: 2, color: leftBorder),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 10, 12, 12),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

/// Syntax-highlighted code block. Shares the same theme as
/// [CodeEditorPane] for visual consistency, but does not include
/// line numbers — notebook cells are usually short.
class _CodeBlock extends StatelessWidget {
  final String source;
  final String language;
  const _CodeBlock({required this.source, required this.language});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final theme = Map<String, TextStyle>.from(
        isDark ? atomOneDarkTheme : atomOneLightTheme);
    theme['root'] = (theme['root'] ?? const TextStyle())
        .copyWith(backgroundColor: Colors.transparent);

    return SelectionArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
        child: HighlightView(
          source,
          language: language,
          theme: theme,
          textStyle: GoogleFonts.firaCode(fontSize: 12, height: 1.5),
          padding: EdgeInsets.zero,
        ),
      ),
    );
  }
}
