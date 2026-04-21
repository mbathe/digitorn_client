import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:webview_flutter/webview_flutter.dart' as wvf;
import 'package:webview_windows/webview_windows.dart' as wvw;

import '../../../design/ds.dart';
import '../../../services/theme_service.dart';
import '../../../theme/app_theme.dart';
import '../../ds/ds.dart';
import '../../workspace/viewers/csv/csv_parser.dart';
import 'artifact.dart';
import 'artifact_service.dart';

/// Premium side panel that renders the currently selected artifact.
/// Slides in from the right with spring easing. Supports a code
/// / preview toggle for types that have a rendered form, a copy
/// action and a close affordance.
class ArtifactPanel extends StatefulWidget {
  final double? width;

  const ArtifactPanel({super.key, this.width});

  @override
  State<ArtifactPanel> createState() => _ArtifactPanelState();
}

enum _ViewMode { preview, source }

class _ArtifactPanelState extends State<ArtifactPanel> {
  _ViewMode _mode = _ViewMode.preview;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListenableBuilder(
      listenable: ArtifactService(),
      builder: (_, _) {
        final service = ArtifactService();
        final artifact = service.selected;
        if (!service.isOpen || artifact == null) {
          return const SizedBox.shrink();
        }
        final effectiveMode =
            artifact.type.hasPreview ? _mode : _ViewMode.source;
        final screen = MediaQuery.sizeOf(context).width;
        final w = widget.width ??
            (screen < 720 ? screen * 0.92 : (screen * 0.42).clamp(420.0, 560.0));
        return Container(
          width: w,
          decoration: BoxDecoration(
            color: c.surface,
            border: Border(
              left: BorderSide(color: c.border, width: DsStroke.hairline),
            ),
            boxShadow: DsElevation.hero(c.shadow),
          ),
          child: Column(
            children: [
              _Header(
                artifact: artifact,
                mode: effectiveMode,
                canSwitch: artifact.type.hasPreview,
                onChangeMode: (m) => setState(() => _mode = m),
                onClose: service.close,
              ),
              Expanded(
                child: _Body(
                  artifact: artifact,
                  mode: effectiveMode,
                ),
              ),
              _Footer(artifact: artifact),
            ],
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final Artifact artifact;
  final _ViewMode mode;
  final bool canSwitch;
  final ValueChanged<_ViewMode> onChangeMode;
  final VoidCallback onClose;

  const _Header({
    required this.artifact,
    required this.mode,
    required this.canSwitch,
    required this.onChangeMode,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: EdgeInsets.fromLTRB(
        DsSpacing.x5,
        DsSpacing.x4,
        DsSpacing.x3,
        DsSpacing.x4,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: c.border, width: DsStroke.hairline),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      c.accentPrimary,
                      Color.lerp(c.accentPrimary, c.accentSecondary, 0.5) ??
                          c.accentPrimary,
                    ],
                  ),
                  borderRadius: BorderRadius.circular(DsRadius.xs),
                ),
                child: Icon(artifact.type.icon, color: c.onAccent, size: 15),
              ),
              SizedBox(width: DsSpacing.x3),
              Expanded(
                child: Text(
                  artifact.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DsType.h2(color: c.textBright).copyWith(fontSize: 15),
                ),
              ),
              DsInputAction(
                icon: Icons.content_copy_rounded,
                tooltip: 'Copy to clipboard',
                onTap: () async {
                  await Clipboard.setData(
                    ClipboardData(text: artifact.content),
                  );
                  if (!context.mounted) return;
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    const SnackBar(
                      content: Text('Copied'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
              DsInputAction(
                icon: Icons.close_rounded,
                tooltip: 'Close',
                onTap: onClose,
              ),
            ],
          ),
          const _ArtifactNavBar(),
          if (canSwitch) ...[
            SizedBox(height: DsSpacing.x3),
            _ModeToggle(mode: mode, onChange: onChangeMode),
          ],
        ],
      ),
    );
  }
}

/// Navigation strip shown under the header when more than one
/// artifact exists — lets the user cycle with `←` / `→` and see
/// where they are in the list via a compact `n / total` counter.
/// Hidden when there is only a single artifact (avoids clutter).
class _ArtifactNavBar extends StatelessWidget {
  const _ArtifactNavBar();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ArtifactService(),
      builder: (_, _) {
        final svc = ArtifactService();
        final total = svc.total;
        if (total < 2) return const SizedBox.shrink();
        final idx = svc.selectedIndex;
        final c = context.colors;
        return Padding(
          padding: EdgeInsets.only(top: DsSpacing.x3),
          child: Row(
            children: [
              _NavArrow(
                icon: Icons.chevron_left_rounded,
                enabled: svc.canGoPrevious,
                onTap: svc.selectPrevious,
              ),
              SizedBox(width: DsSpacing.x2),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: DsSpacing.x3, vertical: 3),
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(DsRadius.xs),
                  border: Border.all(color: c.border),
                ),
                child: Text(
                  '${idx + 1} / $total',
                  style: DsType.mono(size: 11, color: c.textMuted)
                      .copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              SizedBox(width: DsSpacing.x2),
              _NavArrow(
                icon: Icons.chevron_right_rounded,
                enabled: svc.canGoNext,
                onTap: svc.selectNext,
              ),
              const Spacer(),
              Text(
                _nextLabel(svc),
                style: DsType.micro(color: c.textDim),
              ),
            ],
          ),
        );
      },
    );
  }

  String _nextLabel(ArtifactService svc) {
    if (!svc.canGoNext) return svc.canGoPrevious ? 'last' : '';
    final list = svc.artifacts;
    final idx = svc.selectedIndex;
    if (idx < 0 || idx + 1 >= list.length) return '';
    final nextTitle = list[idx + 1].displayTitle;
    if (nextTitle.isEmpty) return '';
    // Small teaser: "next → My diagram"
    final trimmed =
        nextTitle.length > 28 ? '${nextTitle.substring(0, 27)}…' : nextTitle;
    return 'next · $trimmed';
  }
}

class _NavArrow extends StatefulWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;
  const _NavArrow({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  State<_NavArrow> createState() => _NavArrowState();
}

class _NavArrowState extends State<_NavArrow> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = !widget.enabled
        ? c.textDim
        : (_h ? c.accentPrimary : c.textMuted);
    return MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) {
        if (widget.enabled && mounted) setState(() => _h = true);
      },
      onExit: (_) {
        if (_h && mounted) setState(() => _h = false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: DsDuration.fast,
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: widget.enabled && _h
                ? c.accentPrimary.withValues(alpha: 0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(DsRadius.xs),
            border: Border.all(
              color: widget.enabled && _h
                  ? c.accentPrimary.withValues(alpha: 0.4)
                  : c.border,
            ),
          ),
          child: Icon(widget.icon, size: 15, color: fg),
        ),
      ),
    );
  }
}

class _ModeToggle extends StatelessWidget {
  final _ViewMode mode;
  final ValueChanged<_ViewMode> onChange;

  const _ModeToggle({required this.mode, required this.onChange});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(DsRadius.xs),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ModeButton(
            label: 'Preview',
            icon: Icons.visibility_outlined,
            selected: mode == _ViewMode.preview,
            onTap: () => onChange(_ViewMode.preview),
          ),
          SizedBox(width: 2),
          _ModeButton(
            label: 'Source',
            icon: Icons.code_rounded,
            selected: mode == _ViewMode.source,
            onTap: () => onChange(_ViewMode.source),
          ),
        ],
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _ModeButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: DsDuration.fast,
          curve: DsCurve.decelSnap,
          padding: EdgeInsets.symmetric(
            horizontal: DsSpacing.x3,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            color: selected ? c.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(DsRadius.xs - 2),
            boxShadow: selected ? DsElevation.raise(c.shadow) : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 13,
                color: selected ? c.textBright : c.textMuted,
              ),
              SizedBox(width: DsSpacing.x2),
              Text(
                label,
                style: DsType.caption(
                  color: selected ? c.textBright : c.textMuted,
                ).copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final Artifact artifact;
  final _ViewMode mode;

  const _Body({required this.artifact, required this.mode});

  @override
  Widget build(BuildContext context) {
    if (mode == _ViewMode.source) {
      return _SourceView(artifact: artifact);
    }
    switch (artifact.type) {
      case ArtifactType.markdown:
        return _MarkdownPreview(artifact: artifact);
      case ArtifactType.html:
      case ArtifactType.svg:
      case ArtifactType.mermaid:
      case ArtifactType.video:
        return _WebArtifactPreview(artifact: artifact);
      case ArtifactType.diff:
        return _DiffPreview(artifact: artifact);
      case ArtifactType.csv:
        return _CsvPreview(artifact: artifact);
      case ArtifactType.image:
        return _ImagePreview(artifact: artifact);
      case ArtifactType.json:
      case ArtifactType.code:
        return _SourceView(artifact: artifact);
    }
  }
}

class _SourceView extends StatelessWidget {
  final Artifact artifact;
  const _SourceView({required this.artifact});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = ThemeService().isDark;
    return Scrollbar(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(DsSpacing.x4),
        child: HighlightView(
          artifact.content,
          language: artifact.language ?? 'plaintext',
          theme: isDark ? atomOneDarkTheme : atomOneLightTheme,
          padding: EdgeInsets.all(DsSpacing.x4),
          textStyle: DsType.mono(size: 13, color: c.textBright),
        ),
      ),
    );
  }
}

// ─── Unified diff viewer — colour +/- lines, highlight hunks ──────────────

class _DiffPreview extends StatelessWidget {
  final Artifact artifact;
  const _DiffPreview({required this.artifact});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final lines = artifact.content.split('\n');
    return Scrollbar(
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(vertical: DsSpacing.x3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < lines.length; i++)
              _DiffLine(index: i, raw: lines[i], colors: c),
          ],
        ),
      ),
    );
  }
}

class _DiffLine extends StatelessWidget {
  final int index;
  final String raw;
  final AppColors colors;
  const _DiffLine({
    required this.index,
    required this.raw,
    required this.colors,
  });

  /// Classify a diff line. Returns bg / fg / leading-char styling.
  ({Color? bg, Color fg, FontWeight weight}) _style() {
    if (raw.startsWith('+++') || raw.startsWith('---')) {
      return (
        bg: colors.surfaceAlt,
        fg: colors.textMuted,
        weight: FontWeight.w600,
      );
    }
    if (raw.startsWith('@@')) {
      return (
        bg: colors.accentPrimary.withValues(alpha: 0.1),
        fg: colors.accentPrimary,
        weight: FontWeight.w600,
      );
    }
    if (raw.startsWith('diff ') || raw.startsWith('index ')) {
      return (
        bg: colors.surfaceAlt,
        fg: colors.textDim,
        weight: FontWeight.w500,
      );
    }
    if (raw.startsWith('+')) {
      return (
        bg: colors.green.withValues(alpha: 0.13),
        fg: colors.green,
        weight: FontWeight.w500,
      );
    }
    if (raw.startsWith('-')) {
      return (
        bg: colors.red.withValues(alpha: 0.13),
        fg: colors.red,
        weight: FontWeight.w500,
      );
    }
    return (bg: null, fg: colors.text, weight: FontWeight.w400);
  }

  @override
  Widget build(BuildContext context) {
    final s = _style();
    return Container(
      color: s.bg,
      padding: EdgeInsets.symmetric(
        horizontal: DsSpacing.x5,
        vertical: 1,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 36,
            child: Text(
              '${index + 1}',
              textAlign: TextAlign.right,
              style: GoogleFonts.firaCode(
                fontSize: 11,
                color: colors.textDim,
                height: 1.55,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              raw.isEmpty ? ' ' : raw,
              style: GoogleFonts.firaCode(
                fontSize: 12.5,
                color: s.fg,
                fontWeight: s.weight,
                height: 1.55,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── CSV / TSV viewer — tabular preview via workspace csv parser ──────────

class _CsvPreview extends StatelessWidget {
  final Artifact artifact;
  const _CsvPreview({required this.artifact});

  static const int _maxPreviewRows = 500;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    ParsedCsv parsed;
    try {
      parsed = parseCsv(artifact.content);
    } catch (e) {
      return _CsvError(message: 'Failed to parse CSV: $e', colors: c);
    }
    if (parsed.rows.isEmpty) {
      return _CsvError(message: 'No rows detected.', colors: c);
    }
    final truncated = parsed.rows.length > _maxPreviewRows;
    final rows = truncated
        ? parsed.rows.sublist(0, _maxPreviewRows)
        : parsed.rows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Scrollbar(
            thumbVisibility: true,
            child: SingleChildScrollView(
              scrollDirection: Axis.vertical,
              child: Scrollbar(
                thumbVisibility: false,
                notificationPredicate: (n) => n.depth == 1,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.all(DsSpacing.x4),
                  child: _buildTable(c, parsed, rows),
                ),
              ),
            ),
          ),
        ),
        Container(
          height: 28,
          padding: EdgeInsets.symmetric(horizontal: DsSpacing.x4),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            border: Border(top: BorderSide(color: c.border)),
          ),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              Text(
                '${parsed.columnCount} cols · ${parsed.rowCount} rows · '
                '${parsed.separatorLabel}-separated',
                style: DsType.micro(color: c.textMuted),
              ),
              if (truncated) ...[
                const SizedBox(width: 8),
                Text('·',
                    style: DsType.micro(color: c.textDim)),
                const SizedBox(width: 8),
                Text(
                  'preview capped at $_maxPreviewRows rows',
                  style: DsType.micro(color: c.orange)
                      .copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTable(
    AppColors c,
    ParsedCsv parsed,
    List<List<String>> rows,
  ) {
    TextAlign alignOf(CsvAlign a) => switch (a) {
          CsvAlign.left => TextAlign.left,
          CsvAlign.center => TextAlign.center,
          CsvAlign.right => TextAlign.right,
        };
    return DataTable(
      headingRowHeight: 34,
      dataRowMinHeight: 28,
      dataRowMaxHeight: 40,
      columnSpacing: DsSpacing.x6,
      horizontalMargin: DsSpacing.x4,
      headingRowColor: WidgetStateProperty.all(c.surfaceAlt),
      dividerThickness: 0.6,
      columns: [
        for (final col in parsed.columns)
          DataColumn(
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  col.name,
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: c.textBright,
                    letterSpacing: 0.1,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: c.accentPrimary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(DsRadius.xs - 2),
                  ),
                  child: Text(
                    col.type.label,
                    style: GoogleFonts.firaCode(
                      fontSize: 9,
                      color: c.accentPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
      rows: [
        for (final row in rows)
          DataRow(
            cells: [
              for (var i = 0; i < parsed.columns.length; i++)
                DataCell(
                  Container(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: Text(
                      i < row.length ? row[i] : '',
                      textAlign: alignOf(parsed.columns[i].type.alignment),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.firaCode(
                        fontSize: 12,
                        color: c.text,
                      ),
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _CsvError extends StatelessWidget {
  final String message;
  final AppColors colors;
  const _CsvError({required this.message, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(DsSpacing.x7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.table_rows_outlined,
                size: 32, color: colors.textDim),
            SizedBox(height: DsSpacing.x3),
            Text(
              message,
              textAlign: TextAlign.center,
              style: DsType.caption(color: colors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Image viewer — URL or base64 data-URI, pan/zoom on tap ───────────────

class _ImagePreview extends StatelessWidget {
  final Artifact artifact;
  const _ImagePreview({required this.artifact});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final raw = artifact.content.trim();
    final image = _buildImage(raw, c);
    return Container(
      color: c.codeBlockBg,
      child: InteractiveViewer(
        minScale: 0.5,
        maxScale: 6,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(DsSpacing.x4),
            child: image,
          ),
        ),
      ),
    );
  }

  Widget _buildImage(String raw, AppColors c) {
    // Case 1: data: URI (base64) — decode inline.
    if (raw.startsWith('data:image/')) {
      final comma = raw.indexOf(',');
      if (comma > 0) {
        final header = raw.substring(0, comma);
        final payload = raw.substring(comma + 1);
        if (header.contains(';base64')) {
          try {
            return Image.memory(
              base64Decode(payload.replaceAll(RegExp(r'\s+'), '')),
              fit: BoxFit.contain,
              errorBuilder: (_, err, _) =>
                  _imageError(c, 'Corrupt base64 image: $err'),
            );
          } catch (e) {
            return _imageError(c, 'Base64 decode failed: $e');
          }
        }
      }
      return _imageError(c, 'Unrecognised data URI.');
    }
    // Case 2: HTTP(S) URL.
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return Image.network(
        raw,
        fit: BoxFit.contain,
        loadingBuilder: (_, child, progress) {
          if (progress == null) return child;
          return Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                value: progress.expectedTotalBytes != null
                    ? progress.cumulativeBytesLoaded /
                        progress.expectedTotalBytes!
                    : null,
                color: c.accentPrimary,
              ),
            ),
          );
        },
        errorBuilder: (_, err, _) =>
            _imageError(c, 'Could not load image:\n$err'),
      );
    }
    // Case 3: maybe raw base64 (no data: prefix).
    final cleaned = raw.replaceAll(RegExp(r'\s+'), '');
    if (RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(cleaned) &&
        cleaned.length >= 128) {
      try {
        return Image.memory(
          base64Decode(cleaned),
          fit: BoxFit.contain,
          errorBuilder: (_, err, _) =>
              _imageError(c, 'Decode failed: $err'),
        );
      } catch (_) {}
    }
    return _imageError(c,
        'Unsupported image body — expected a URL or data:image/…;base64,… URI.');
  }

  Widget _imageError(AppColors c, String msg) => Padding(
        padding: EdgeInsets.all(DsSpacing.x6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, size: 30, color: c.textDim),
            SizedBox(height: DsSpacing.x3),
            Text(msg,
                textAlign: TextAlign.center,
                style: DsType.caption(color: c.textMuted)),
          ],
        ),
      );
}

class _MarkdownPreview extends StatelessWidget {
  final Artifact artifact;
  const _MarkdownPreview({required this.artifact});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scrollbar(
      child: Markdown(
        data: artifact.content,
        padding: EdgeInsets.all(DsSpacing.x6),
        selectable: true,
        styleSheet: MarkdownStyleSheet(
          p: DsType.body(color: c.text).copyWith(height: 1.6),
          h1: DsType.display(size: 28, color: c.textBright, height: 1.2),
          h2: DsType.display2(size: 22, color: c.textBright),
          h3: DsType.h1(color: c.textBright),
          h4: DsType.h2(color: c.textBright),
          code: DsType.mono(size: 12.5, color: c.textBright).copyWith(
            backgroundColor: c.codeBlockBg,
          ),
          codeblockDecoration: BoxDecoration(
            color: c.codeBlockBg,
            borderRadius: BorderRadius.circular(DsRadius.xs),
          ),
          blockquoteDecoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: c.accentPrimary, width: 3),
            ),
            color: c.surface,
          ),
          blockquote: DsType.body(color: c.textMuted).copyWith(
            fontStyle: FontStyle.italic,
            height: 1.55,
          ),
          listBullet: DsType.body(color: c.accentPrimary),
          a: DsType.body(color: c.accentPrimary).copyWith(
            decoration: TextDecoration.underline,
            decorationColor: c.accentPrimary,
          ),
        ),
      ),
    );
  }
}

// ─── Cross-platform HTML / SVG / Mermaid preview ──────────────────────────
//
// Same backend split as the widgets_v1 html primitive (keeps the
// workspace preview code untouched):
//
//   * Windows desktop  → `webview_windows` (WebView2)
//   * mobile / macOS   → `webview_flutter`
//   * Web / Linux      → graceful fallback (rendered-source placeholder)
//
// The raw content is embedded into a themed HTML shell so the render
// picks up the chat palette's bg/text colours, and SVG / Mermaid
// both map to the same webview path via small wrapper templates.

enum _WebPreviewBackend { windows, flutter, unsupported }

_WebPreviewBackend _pickBackend() {
  if (kIsWeb) return _WebPreviewBackend.unsupported;
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
      return _WebPreviewBackend.windows;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return _WebPreviewBackend.flutter;
    default:
      return _WebPreviewBackend.unsupported;
  }
}

class _WebArtifactPreview extends StatefulWidget {
  final Artifact artifact;
  const _WebArtifactPreview({required this.artifact});

  @override
  State<_WebArtifactPreview> createState() => _WebArtifactPreviewState();
}

class _WebArtifactPreviewState extends State<_WebArtifactPreview> {
  late final _WebPreviewBackend _backend;
  wvw.WebviewController? _wvwCtl;
  wvf.WebViewController? _wvfCtl;
  bool _ready = false;
  String? _error;
  String _lastUrl = '';

  @override
  void initState() {
    super.initState();
    _backend = _pickBackend();
    if (_backend != _WebPreviewBackend.unsupported) {
      _init();
    }
  }

  @override
  void didUpdateWidget(covariant _WebArtifactPreview old) {
    super.didUpdateWidget(old);
    if (!_ready) return;
    if (old.artifact.id == widget.artifact.id &&
        old.artifact.content == widget.artifact.content) {
      return;
    }
    _reload();
  }

  @override
  void dispose() {
    try {
      _wvwCtl?.dispose();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _init() async {
    try {
      switch (_backend) {
        case _WebPreviewBackend.windows:
          final ctrl = wvw.WebviewController();
          await ctrl.initialize();
          _wvwCtl = ctrl;
          break;
        case _WebPreviewBackend.flutter:
          final ctrl = wvf.WebViewController()
            ..setJavaScriptMode(wvf.JavaScriptMode.unrestricted)
            ..setBackgroundColor(const Color(0x00000000));
          _wvfCtl = ctrl;
          break;
        case _WebPreviewBackend.unsupported:
          break;
      }
      if (!mounted) return;
      setState(() => _ready = true);
      await _reload();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _reload() async {
    final c = context.colors;
    final html = _wrap(widget.artifact, c);
    final url = 'data:text/html;base64,${base64Encode(utf8.encode(html))}';
    if (url == _lastUrl) return;
    _lastUrl = url;
    try {
      switch (_backend) {
        case _WebPreviewBackend.windows:
          await _wvwCtl?.loadUrl(url);
          break;
        case _WebPreviewBackend.flutter:
          await _wvfCtl?.loadRequest(Uri.parse(url));
          break;
        case _WebPreviewBackend.unsupported:
          break;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  /// Build an HTML shell around [artifact.content] that adopts the
  /// chat's palette for bg/text so the preview doesn't look like a
  /// bright white island inside the dark chat.
  String _wrap(Artifact artifact, AppColors c) {
    final bg = _hex(c.bg);
    final fg = _hex(c.text);
    final accent = _hex(c.accentPrimary);
    final css = '''
      html,body{margin:0;padding:16px;background:$bg;color:$fg;
        font-family:-apple-system,BlinkMacSystemFont,'Inter',sans-serif;
        font-size:14px;line-height:1.5;}
      a{color:$accent}
      img,svg{max-width:100%;height:auto;}
      pre,code{background:rgba(255,255,255,.04);padding:2px 4px;
        border-radius:4px;font-family:'JetBrains Mono',Menlo,monospace;}
      ::-webkit-scrollbar{width:8px;height:8px}
      ::-webkit-scrollbar-thumb{background:rgba(255,255,255,.15);border-radius:4px}
    ''';

    switch (artifact.type) {
      case ArtifactType.html:
        final hasHtml = artifact.content.contains('<html');
        if (hasHtml) {
          // User shipped a full document — inject our palette-tuned
          // style block just before </head> so their CSS still wins.
          return artifact.content.replaceFirst(
            RegExp(r'</head>', caseSensitive: false),
            '<style>$css</style></head>',
          );
        }
        return '<!doctype html><html><head><meta charset="utf-8">'
            '<style>$css</style></head>'
            '<body>${artifact.content}</body></html>';
      case ArtifactType.svg:
        return '<!doctype html><html><head><meta charset="utf-8">'
            '<style>$css body{display:flex;align-items:center;'
            'justify-content:center;min-height:100vh}</style></head>'
            '<body>${artifact.content}</body></html>';
      case ArtifactType.mermaid:
        final safe = const HtmlEscape().convert(artifact.content);
        final theme = ThemeService().isDark ? 'dark' : 'default';
        return '''
<!doctype html><html><head><meta charset="utf-8">
<style>$css .mermaid{display:flex;justify-content:center;min-height:calc(100vh - 32px);align-items:center}</style>
<script src="https://cdn.jsdelivr.net/npm/mermaid/dist/mermaid.min.js"></script>
</head><body>
<pre class="mermaid">$safe</pre>
<script>mermaid.initialize({startOnLoad:true,theme:'$theme',securityLevel:'loose'});</script>
</body></html>''';
      case ArtifactType.video:
        final src = artifact.content.trim();
        final safe = const HtmlEscape(HtmlEscapeMode.attribute).convert(src);
        return '''
<!doctype html><html><head><meta charset="utf-8">
<style>$css html,body{height:100%;padding:0}
video{width:100%;height:100%;background:$bg;object-fit:contain}
.fallback{display:flex;align-items:center;justify-content:center;height:100%;color:$fg;opacity:.7}</style>
</head><body>
<video controls autoplay preload="metadata" playsinline>
  <source src="$safe">
  <div class="fallback">Your platform does not support this video format.</div>
</video>
</body></html>''';
      default:
        return '<!doctype html><html><head><style>$css</style></head>'
            '<body><pre>${const HtmlEscape().convert(artifact.content)}</pre></body></html>';
    }
  }

  String _hex(Color c) {
    int to8(double v) => (v * 255).round().clamp(0, 255).toInt();
    final r = to8(c.r).toRadixString(16).padLeft(2, '0');
    final g = to8(c.g).toRadixString(16).padLeft(2, '0');
    final b = to8(c.b).toRadixString(16).padLeft(2, '0');
    return '#$r$g$b';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (_backend == _WebPreviewBackend.unsupported) {
      return _PreviewUnavailable(artifact: widget.artifact, colors: c);
    }
    if (_error != null) {
      return Padding(
        padding: EdgeInsets.all(DsSpacing.x5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded, color: c.red, size: 32),
            SizedBox(height: DsSpacing.x3),
            Text('Preview failed to load',
                style: DsType.h2(color: c.textBright)),
            SizedBox(height: DsSpacing.x2),
            Text(_error!,
                textAlign: TextAlign.center,
                style: DsType.micro(color: c.textMuted)),
          ],
        ),
      );
    }
    if (!_ready) {
      return Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
              strokeWidth: 1.5, color: c.accentPrimary),
        ),
      );
    }
    switch (_backend) {
      case _WebPreviewBackend.windows:
        return wvw.Webview(_wvwCtl!);
      case _WebPreviewBackend.flutter:
        return wvf.WebViewWidget(controller: _wvfCtl!);
      case _WebPreviewBackend.unsupported:
        return _PreviewUnavailable(artifact: widget.artifact, colors: c);
    }
  }
}

class _PreviewUnavailable extends StatelessWidget {
  final Artifact artifact;
  final AppColors colors;
  const _PreviewUnavailable({required this.artifact, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(DsSpacing.x7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: colors.accentPrimary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(DsRadius.card),
                border: Border.all(
                  color: colors.accentPrimary.withValues(alpha: 0.35),
                ),
              ),
              child: Icon(Icons.public_off_rounded,
                  color: colors.accentPrimary, size: 26),
            ),
            SizedBox(height: DsSpacing.x5),
            Text('Preview unavailable here',
                style: DsType.h2(color: colors.textBright)),
            SizedBox(height: DsSpacing.x2),
            Text(
              'Live rendering of ${artifact.type.label} needs a webview '
              'backend (not bundled on this platform). Use Source for now.',
              textAlign: TextAlign.center,
              style: DsType.caption(color: colors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final Artifact artifact;
  const _Footer({required this.artifact});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 36,
      padding: EdgeInsets.symmetric(horizontal: DsSpacing.x5),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        border: Border(
          top: BorderSide(color: c.border, width: DsStroke.hairline),
        ),
      ),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Text(
            '${artifact.type.label.toUpperCase()}'
            '${artifact.language != null ? ' · ${artifact.language}' : ''}',
            style: DsType.eyebrow(color: c.textMuted).copyWith(fontSize: 10),
          ),
          const Spacer(),
          Text(
            '${artifact.lineCount} line${artifact.lineCount == 1 ? '' : 's'}',
            style: DsType.micro(color: c.textDim),
          ),
        ],
      ),
    );
  }
}
