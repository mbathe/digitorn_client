import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../design/ds.dart';
import '../../../models/app_manifest.dart';
import '../../../theme/app_theme.dart';

/// Premium hero block rendered when an app is freshly opened and
/// has no messages yet. Layouts a staggered entry (icon → title →
/// greeting → tags) with a subtle breathing animation on the icon
/// tile so it feels alive without demanding attention.
class ChatEmptyStateHero extends StatefulWidget {
  final String emoji;
  final String name;
  final String greeting;
  final Color accent;
  final List<String> tags;

  const ChatEmptyStateHero({
    super.key,
    required this.emoji,
    required this.name,
    required this.greeting,
    required this.accent,
    required this.tags,
  });

  @override
  State<ChatEmptyStateHero> createState() => _ChatEmptyStateHeroState();
}

class _ChatEmptyStateHeroState extends State<ChatEmptyStateHero>
    with TickerProviderStateMixin {
  late final AnimationController _entry;
  late final AnimationController _breathe;

  @override
  void initState() {
    super.initState();
    _entry = AnimationController(vsync: this, duration: DsDuration.hero)
      ..forward();
    _breathe = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _entry.dispose();
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final compact = DsBreakpoint.isCompact(context);
    return AnimatedBuilder(
      animation: _entry,
      builder: (_, _) {
        final t = DsCurve.decelSoft.transform(_entry.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 12),
            child: Column(
              children: [
                _StaggeredFade(
                  delay: 0,
                  controller: _entry,
                  child: _BreathingTile(
                    breathe: _breathe,
                    accent: widget.accent,
                    emoji: widget.emoji,
                  ),
                ),
                SizedBox(height: DsSpacing.x6),
                _StaggeredFade(
                  delay: 0.12,
                  controller: _entry,
                  child: Text(
                    widget.name,
                    textAlign: TextAlign.center,
                    style: DsType.display(
                      size: compact ? 30 : 40,
                      color: c.textBright,
                    ),
                  ),
                ),
                if (widget.greeting.isNotEmpty) ...[
                  SizedBox(height: DsSpacing.x3),
                  _StaggeredFade(
                    delay: 0.22,
                    controller: _entry,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: Text(
                        widget.greeting,
                        textAlign: TextAlign.center,
                        style: DsType.body(color: c.textMuted)
                            .copyWith(fontSize: 15, height: 1.6),
                      ),
                    ),
                  ),
                ],
                if (widget.tags.isNotEmpty) ...[
                  SizedBox(height: DsSpacing.x5),
                  _StaggeredFade(
                    delay: 0.32,
                    controller: _entry,
                    child: Wrap(
                      spacing: DsSpacing.x2,
                      runSpacing: DsSpacing.x2,
                      alignment: WrapAlignment.center,
                      children: [
                        for (final tag in widget.tags.take(5))
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: DsSpacing.x3,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: c.surface.withValues(alpha: 0.8),
                              borderRadius:
                                  BorderRadius.circular(DsRadius.xs),
                              border: Border.all(color: c.border),
                            ),
                            child: Text(
                              tag,
                              style: DsType.mono(size: 10.5, color: c.textMuted)
                                  .copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BreathingTile extends StatelessWidget {
  final AnimationController breathe;
  final Color accent;
  final String emoji;
  const _BreathingTile({
    required this.breathe,
    required this.accent,
    required this.emoji,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AnimatedBuilder(
      animation: breathe,
      builder: (_, _) {
        final t = breathe.value;
        final scale = 1.0 + 0.02 * math.sin(t * math.pi);
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 80,
            height: 80,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.lerp(accent, c.accentPrimary, 0.25) ?? accent,
                  Color.lerp(accent, c.accentSecondary, 0.55) ?? accent,
                ],
              ),
              borderRadius: BorderRadius.circular(22),
              boxShadow: DsElevation.accentGlow(accent, strength: 0.9),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(22),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.center,
                        colors: [
                          Colors.white.withValues(alpha: 0.24),
                          Colors.white.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
                emoji.isNotEmpty
                    ? Text(
                        emoji,
                        style: const TextStyle(fontSize: 40, height: 1),
                      )
                    : Icon(
                        Icons.auto_awesome_rounded,
                        color: c.onAccent,
                        size: 36,
                      ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StaggeredFade extends StatelessWidget {
  final double delay;
  final AnimationController controller;
  final Widget child;

  const _StaggeredFade({
    required this.delay,
    required this.controller,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, c) {
        final raw = ((controller.value - delay) / (1 - delay)).clamp(0.0, 1.0);
        final t = DsCurve.decelSoft.transform(raw);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 8),
            child: c,
          ),
        );
      },
      child: child,
    );
  }
}

/// Premium chip card for a quick prompt. Stays wider on desktop
/// (card feel), shrinks to a pill on compact viewports.
class ChatQuickPromptCard extends StatefulWidget {
  final QuickPrompt prompt;
  final Color accent;
  final VoidCallback onTap;

  const ChatQuickPromptCard({
    super.key,
    required this.prompt,
    required this.accent,
    required this.onTap,
  });

  @override
  State<ChatQuickPromptCard> createState() => _ChatQuickPromptCardState();
}

class _ChatQuickPromptCardState extends State<ChatQuickPromptCard> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          duration: DsDuration.fast,
          curve: DsCurve.decelSnap,
          scale: _pressed ? 0.985 : 1.0,
          child: AnimatedContainer(
            duration: DsDuration.fast,
            curve: DsCurve.decelSnap,
            width: 280,
            padding: EdgeInsets.all(DsSpacing.x4),
            decoration: BoxDecoration(
              color: _hover
                  ? Color.lerp(c.surface, widget.accent, 0.06) ?? c.surface
                  : c.surface,
              borderRadius: BorderRadius.circular(DsRadius.card),
              border: Border.all(
                color: _hover
                    ? widget.accent.withValues(alpha: 0.5)
                    : c.border,
                width: _hover ? DsStroke.normal : DsStroke.hairline,
              ),
              boxShadow: _hover
                  ? DsElevation.accentGlow(widget.accent, strength: 0.25)
                  : DsElevation.raise(c.shadow),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: widget.accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(DsRadius.xs),
                    border: Border.all(
                      color: widget.accent.withValues(alpha: 0.28),
                    ),
                  ),
                  child: widget.prompt.icon.isNotEmpty
                      ? Text(widget.prompt.icon,
                          style: const TextStyle(fontSize: 16, height: 1))
                      : Icon(
                          Icons.auto_awesome_rounded,
                          size: 15,
                          color: widget.accent,
                        ),
                ),
                SizedBox(width: DsSpacing.x4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.prompt.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DsType.h3(
                          color: _hover ? c.textBright : c.text,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        widget.prompt.message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: DsType.micro(color: c.textMuted)
                            .copyWith(fontSize: 11.5, height: 1.45),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: DsSpacing.x2),
                AnimatedOpacity(
                  duration: DsDuration.fast,
                  opacity: _hover ? 1 : 0,
                  child: Icon(
                    Icons.arrow_forward_rounded,
                    size: 14,
                    color: widget.accent,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
