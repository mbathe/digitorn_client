import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../design/ds.dart';
import '../../../theme/app_theme.dart';
import 'artifact.dart';
import 'artifact_service.dart';

/// Inline pill replacing a heavy code block in a chat bubble.
/// Clicking opens the artifact in the side panel. Carries a
/// preview of the artifact's metadata (type, language, line count).
///
/// When [Artifact.isStreaming] is true, renders the "streaming card"
/// variant: a fixed-height viewport that tails the last lines of
/// content as they arrive — the user can see generation progressing
/// without the chat bubble growing vertically.
class ArtifactPill extends StatefulWidget {
  final Artifact artifact;

  const ArtifactPill({super.key, required this.artifact});

  @override
  State<ArtifactPill> createState() => _ArtifactPillState();
}

class _ArtifactPillState extends State<ArtifactPill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    if (widget.artifact.isStreaming) {
      return _StreamingArtifactCard(artifact: widget.artifact);
    }
    final c = context.colors;
    final a = widget.artifact;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: DsSpacing.x3),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => ArtifactService().select(a.id),
          child: AnimatedContainer(
            duration: DsDuration.fast,
            curve: DsCurve.decelSnap,
            padding: EdgeInsets.symmetric(
              horizontal: DsSpacing.x4,
              vertical: DsSpacing.x3,
            ),
            decoration: BoxDecoration(
              color: _hover
                  ? Color.lerp(c.surface, c.accentPrimary, 0.06)
                  : c.surface,
              borderRadius: BorderRadius.circular(DsRadius.card),
              border: Border.all(
                color: _hover
                    ? c.accentPrimary.withValues(alpha: 0.5)
                    : c.border,
                width: _hover ? DsStroke.normal : DsStroke.hairline,
              ),
              boxShadow: _hover
                  ? DsElevation.accentGlow(c.accentPrimary, strength: 0.3)
                  : DsElevation.raise(c.shadow),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        c.accentPrimary,
                        Color.lerp(c.accentPrimary, c.accentSecondary, 0.6) ??
                            c.accentPrimary,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(DsRadius.xs),
                    boxShadow:
                        DsElevation.accentGlow(c.accentPrimary, strength: 0.4),
                  ),
                  child: Icon(a.type.icon, color: c.onAccent, size: 18),
                ),
                SizedBox(width: DsSpacing.x4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        a.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DsType.label(color: c.textBright),
                      ),
                      SizedBox(height: 2),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            a.type.label.toUpperCase(),
                            style: DsType.eyebrow(color: c.accentPrimary)
                                .copyWith(fontSize: 10),
                          ),
                          Text(
                            '  ·  ${a.lineCount} line${a.lineCount == 1 ? '' : 's'}',
                            style: DsType.micro(color: c.textMuted),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                SizedBox(width: DsSpacing.x4),
                Icon(
                  Icons.open_in_new_rounded,
                  size: 14,
                  color: _hover ? c.accentPrimary : c.textMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Streaming variant of the inline pill: a fixed-height card that
/// tails the last few lines of the artifact content as tokens
/// arrive. Click opens the partial artifact in the side panel.
class _StreamingArtifactCard extends StatefulWidget {
  final Artifact artifact;
  const _StreamingArtifactCard({required this.artifact});

  @override
  State<_StreamingArtifactCard> createState() =>
      _StreamingArtifactCardState();
}

class _StreamingArtifactCardState extends State<_StreamingArtifactCard>
    with SingleTickerProviderStateMixin {
  final _scroll = ScrollController();
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _StreamingArtifactCard old) {
    super.didUpdateWidget(old);
    if (old.artifact.content != widget.artifact.content) {
      // Auto-scroll to the tail so the user follows the stream.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final a = widget.artifact;
    final lines = a.lineCount;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: DsSpacing.x3),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => ArtifactService().select(a.id),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 560),
            decoration: BoxDecoration(
              color: c.codeBlockBg,
              borderRadius: BorderRadius.circular(DsRadius.card),
              border: Border.all(
                color: c.accentPrimary.withValues(alpha: 0.45),
                width: DsStroke.normal,
              ),
              boxShadow: DsElevation.accentGlow(c.accentPrimary,
                  strength: 0.35),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                _header(c, a, lines),
                SizedBox(
                  height: 144,
                  child: _TailView(
                    content: a.content,
                    scroll: _scroll,
                    colors: c,
                  ),
                ),
                _footer(c, lines),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(AppColors c, Artifact a, int lines) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        DsSpacing.x4,
        DsSpacing.x3,
        DsSpacing.x3,
        DsSpacing.x3,
      ),
      decoration: BoxDecoration(
        color: c.codeBlockHeader,
        border: Border(
          bottom:
              BorderSide(color: c.border, width: DsStroke.hairline),
        ),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(DsRadius.card),
          topRight: Radius.circular(DsRadius.card),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  c.accentPrimary,
                  Color.lerp(c.accentPrimary, c.accentSecondary, 0.6) ??
                      c.accentPrimary,
                ],
              ),
              borderRadius: BorderRadius.circular(DsRadius.xs),
            ),
            child: Icon(a.type.icon, size: 14, color: c.onAccent),
          ),
          SizedBox(width: DsSpacing.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  a.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DsType.label(color: c.textBright)
                      .copyWith(fontSize: 12.5),
                ),
                Row(
                  children: [
                    _pulsingDot(c),
                    const SizedBox(width: 5),
                    Text(
                      'Generating',
                      style: DsType.micro(color: c.accentPrimary)
                          .copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 6),
                    Text('·',
                        style: DsType.micro(color: c.textDim)),
                    const SizedBox(width: 6),
                    Text('$lines line${lines == 1 ? '' : 's'}',
                        style: DsType.micro(color: c.textMuted)),
                  ],
                ),
              ],
            ),
          ),
          Icon(Icons.open_in_new_rounded, size: 13, color: c.textDim),
        ],
      ),
    );
  }

  Widget _pulsingDot(AppColors c) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, _) {
        final alpha = 0.45 + (0.45 * _pulse.value);
        return Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.accentPrimary.withValues(alpha: alpha),
            boxShadow: [
              BoxShadow(
                color: c.accentPrimary.withValues(alpha: alpha * 0.5),
                blurRadius: 5,
                spreadRadius: 1,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _footer(AppColors c, int lines) {
    return Container(
      height: 28,
      padding: EdgeInsets.symmetric(horizontal: DsSpacing.x4),
      decoration: BoxDecoration(
        color: c.codeBlockHeader,
        border: Border(
          top: BorderSide(color: c.border, width: DsStroke.hairline),
        ),
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(DsRadius.card),
          bottomRight: Radius.circular(DsRadius.card),
        ),
      ),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Text(
            'Tap to open full artifact',
            style: DsType.micro(color: c.textMuted),
          ),
          const Spacer(),
          Icon(Icons.arrow_forward_rounded,
              size: 11, color: c.textDim),
        ],
      ),
    );
  }
}

/// Code-styled tail view that auto-scrolls to the bottom as content
/// grows. Fixed-height so the chat bubble doesn't bloat.
class _TailView extends StatelessWidget {
  final String content;
  final ScrollController scroll;
  final AppColors colors;

  const _TailView({
    required this.content,
    required this.scroll,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Scrollbar(
            controller: scroll,
            thumbVisibility: false,
            child: SingleChildScrollView(
              controller: scroll,
              padding: EdgeInsets.symmetric(
                horizontal: DsSpacing.x4,
                vertical: DsSpacing.x3,
              ),
              child: Text(
                content,
                style: GoogleFonts.firaCode(
                  fontSize: 11.5,
                  color: colors.text,
                  height: 1.55,
                ),
              ),
            ),
          ),
          // Subtle top fade to hint at content scrolled off-screen.
          IgnorePointer(
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                height: 18,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      colors.codeBlockBg,
                      colors.codeBlockBg.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
