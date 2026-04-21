import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../design/tokens.dart';
import '../../../theme/app_theme.dart';
import 'attachment_helpers.dart';

/// Premium attachment bar shown above the composer whenever the
/// `_attachments` list is non-empty. Rich pills carry:
///
///   * a 40×40 preview — live image thumbnail for image paths,
///     MIME-typed icon in an accent square otherwise;
///   * the filename (truncated with ellipsis);
///   * a size line + a tiny extension badge;
///   * a close × affordance that shows on hover or stays visible
///     on touch devices.
///
/// Up to 4 pills render inline; an `+N` chip follows when the user
/// attached more and wants to see the overflow count before sending.
class AttachmentsBar extends StatelessWidget {
  final List<AttachmentEntry> attachments;
  final void Function(int index) onRemove;
  const AttachmentsBar({
    super.key,
    required this.attachments,
    required this.onRemove,
  });

  static const int _maxVisible = 4;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final visible = attachments.take(_maxVisible).toList();
    final overflow = attachments.length - _maxVisible;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: SizedBox(
        height: 34,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (int i = 0; i < visible.length; i++)
              _AttachmentPill(
                attachment: visible[i],
                onRemove: () => onRemove(i),
              ),
            if (overflow > 0)
              Container(
                margin: const EdgeInsets.only(right: 6),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(DsRadius.xs),
                  border: Border.all(color: c.border),
                ),
                child: Center(
                  child: Text(
                    '+$overflow more',
                    style: GoogleFonts.firaCode(
                      fontSize: 10,
                      color: c.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentPill extends StatefulWidget {
  final AttachmentEntry attachment;
  final VoidCallback onRemove;
  const _AttachmentPill({
    required this.attachment,
    required this.onRemove,
  });

  @override
  State<_AttachmentPill> createState() => _AttachmentPillState();
}

class _AttachmentPillState extends State<_AttachmentPill> {
  bool _hover = false;
  int? _size;

  @override
  void initState() {
    super.initState();
    _resolveSize();
  }

  @override
  void didUpdateWidget(covariant _AttachmentPill old) {
    super.didUpdateWidget(old);
    if (old.attachment.path != widget.attachment.path) {
      _resolveSize();
    }
  }

  Future<void> _resolveSize() async {
    if (kIsWeb) return;
    try {
      final stat = await File(widget.attachment.path).stat();
      if (!mounted) return;
      setState(() => _size = stat.size);
    } catch (_) {
      // stat can fail for recently-created tmp files on some FS —
      // the pill just renders without a size.
    }
  }

  String get _ext {
    final n = widget.attachment.name.toLowerCase();
    final dot = n.lastIndexOf('.');
    if (dot < 0 || dot == n.length - 1) return '';
    return n.substring(dot + 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final a = widget.attachment;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        constraints: const BoxConstraints(maxWidth: 220),
        decoration: BoxDecoration(
          color: _hover ? c.surfaceAlt : c.surface,
          borderRadius: BorderRadius.circular(DsRadius.xs),
          border: Border.all(
            color: _hover
                ? c.accentPrimary.withValues(alpha: 0.35)
                : c.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Preview(
              path: a.path,
              isImage: a.isImage,
              colors: c,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                a.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: c.textBright,
                  letterSpacing: -0.1,
                ),
              ),
            ),
            if (_ext.isNotEmpty) ...[
              const SizedBox(width: 5),
              Text(
                _ext,
                style: GoogleFonts.firaCode(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: c.accentPrimary,
                  letterSpacing: 0.3,
                ),
              ),
            ],
            if (_size != null) ...[
              const SizedBox(width: 5),
              Text(
                formatFileSize(_size!),
                style: GoogleFonts.firaCode(
                  fontSize: 9,
                  color: c.textDim,
                ),
              ),
            ],
            const SizedBox(width: 4),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onRemove,
              child: Container(
                width: 16,
                height: 16,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _hover
                      ? c.red.withValues(alpha: 0.15)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Icon(
                  Icons.close_rounded,
                  size: 10,
                  color: _hover ? c.red : c.textDim,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  final String path;
  final bool isImage;
  final AppColors colors;
  const _Preview({
    required this.path,
    required this.isImage,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 22,
      height: 22,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: isImage && !kIsWeb
            ? _thumbnail()
            : _iconBox(),
      ),
    );
  }

  Widget _thumbnail() {
    return Container(
      color: colors.bg,
      child: Image.file(
        File(path),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _iconBox(),
      ),
    );
  }

  Widget _iconBox() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.accentPrimary.withValues(alpha: 0.18),
            colors.accentSecondary.withValues(alpha: 0.12),
          ],
        ),
      ),
      alignment: Alignment.center,
      child: Icon(
        iconForExtension(path),
        size: 12,
        color: colors.accentPrimary,
      ),
    );
  }
}
