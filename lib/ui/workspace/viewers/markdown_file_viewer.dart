import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../theme/app_theme.dart';
import 'file_viewer.dart';

/// Renders a Markdown buffer with a styled preview header.
class MarkdownFileViewer extends FileViewer {
  const MarkdownFileViewer();

  @override
  String get id => 'markdown';

  @override
  int get priority => 50;

  @override
  Set<String> get extensions => const {'md', 'markdown', 'mdown', 'mkd'};

  @override
  Widget build(BuildContext context, ViewerContext vctx) {
    return _MarkdownPreview(
      content: vctx.buffer.content,
      filename: vctx.buffer.filename,
    );
  }
}

class _MarkdownPreview extends StatelessWidget {
  final String content;
  final String filename;
  const _MarkdownPreview({required this.content, required this.filename});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: c.surface,
          child: Row(
            children: [
              Icon(Icons.description, size: 14, color: c.textMuted),
              const SizedBox(width: 8),
              Text(filename,
                  style: GoogleFonts.firaCode(fontSize: 12, color: c.text)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: c.border,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text('PREVIEW',
                    style:
                        GoogleFonts.firaCode(fontSize: 9, color: c.textMuted)),
              ),
            ],
          ),
        ),
        Expanded(
          child: Markdown(
            data: content,
            selectable: true,
            padding: const EdgeInsets.all(16),
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
        ),
      ],
    );
  }
}
