/// Layout primitives shared across every settings section.
///
/// Keep the visual language consistent: same title style, same
/// section spacing, same card chrome, same row layout. Sections that
/// need a completely custom layout can still render whatever they
/// want — these are the defaults.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../theme/app_theme.dart';

/// Standard scrollable container for one settings section. Renders a
/// premium H1 + optional subtitle + optional hero icon + the body
/// inside a 820px-max column, with a subtle fade-in animation.
class SectionScaffold extends StatefulWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final List<Widget> children;
  final List<Widget> actions;
  const SectionScaffold({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    required this.children,
    this.actions = const [],
  });

  @override
  State<SectionScaffold> createState() => _SectionScaffoldState();
}

class _SectionScaffoldState extends State<SectionScaffold>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entry;

  @override
  void initState() {
    super.initState();
    _entry = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    )..forward();
  }

  @override
  void dispose() {
    _entry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListView(
      padding: const EdgeInsets.fromLTRB(44, 32, 44, 56),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: AnimatedBuilder(
            animation: _entry,
            builder: (_, child) {
              final t = Curves.easeOutCubic.transform(_entry.value);
              return Opacity(
                opacity: t,
                child: Transform.translate(
                  offset: Offset(0, (1 - t) * 8),
                  child: child,
                ),
              );
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header row — hero icon + title + actions.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.icon != null) ...[
                      _HeroIcon(icon: widget.icon!),
                      const SizedBox(width: 18),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            style: GoogleFonts.inter(
                              fontSize: 30,
                              fontWeight: FontWeight.w700,
                              color: c.textBright,
                              letterSpacing: -0.6,
                              height: 1.1,
                            ),
                          ),
                          if (widget.subtitle != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              widget.subtitle!,
                              style: GoogleFonts.inter(
                                fontSize: 14.5,
                                color: c.textMuted,
                                height: 1.55,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    ...widget.actions,
                  ],
                ),
                const SizedBox(height: 4),
                Container(
                  height: 1,
                  margin: const EdgeInsets.only(top: 26, bottom: 8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        c.border,
                        c.border.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                ...widget.children,
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _HeroIcon extends StatelessWidget {
  final IconData icon;
  const _HeroIcon({required this.icon});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            c.accentPrimary.withValues(alpha: 0.18),
            c.accentSecondary.withValues(alpha: 0.10),
          ],
        ),
        border: Border.all(
          color: c.accentPrimary.withValues(alpha: 0.28),
        ),
      ),
      child: Icon(icon, color: c.accentPrimary, size: 22),
    );
  }
}

/// Card grouping a set of related rows. Premium chrome: soft shadow,
/// optional label + description + icon, dividers palette-aware.
class SettingsCard extends StatelessWidget {
  /// Small uppercase group label rendered above the card.
  final String? label;

  /// Optional description sitting next to the label.
  final String? description;

  /// Optional icon rendered next to the label.
  final IconData? icon;

  final List<Widget> children;
  final EdgeInsets padding;

  const SettingsCard({
    super.key,
    this.label,
    this.description,
    this.icon,
    required this.children,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (label != null) ...[
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 13, color: c.accentPrimary),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label!,
                          style: GoogleFonts.firaCode(
                            fontSize: 11.5,
                            color: c.textMuted,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                          ),
                        ),
                        if (description != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            description!,
                            style: GoogleFonts.inter(
                              fontSize: 12.5,
                              color: c.textMuted,
                              height: 1.45,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          Container(
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.border),
              boxShadow: [
                BoxShadow(
                  color: c.shadow.withValues(alpha: 0.15),
                  blurRadius: 14,
                  spreadRadius: -6,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Padding(
              padding: padding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    children[i],
                    if (i < children.length - 1)
                      Divider(
                          height: 1,
                          thickness: 1,
                          color: c.border.withValues(alpha: 0.6)),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One row inside a [SettingsCard]: icon tile + label / subtitle on
/// the left, arbitrary trailing widget on the right.
class SettingsRow extends StatefulWidget {
  final IconData? icon;
  final String label;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? iconTint;

  const SettingsRow({
    super.key,
    this.icon,
    required this.label,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.iconTint,
  });

  @override
  State<SettingsRow> createState() => _SettingsRowState();
}

class _SettingsRowState extends State<SettingsRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tint = widget.iconTint ?? c.accentPrimary;
    final body = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      color: _hover && widget.onTap != null
          ? c.surfaceAlt.withValues(alpha: 0.5)
          : null,
      child: Row(
        children: [
          if (widget.icon != null) ...[
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                    color: tint.withValues(alpha: 0.22), width: 1),
              ),
              child: Icon(widget.icon, size: 17, color: tint),
            ),
            const SizedBox(width: 14),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.label,
                  style: GoogleFonts.inter(
                    fontSize: 14.5,
                    color: c.textBright,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.1,
                  ),
                ),
                if (widget.subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    widget.subtitle!,
                    style: GoogleFonts.inter(
                      fontSize: 12.5,
                      color: c.textMuted,
                      height: 1.45,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (widget.trailing != null) ...[
            const SizedBox(width: 12),
            widget.trailing!,
          ],
          if (widget.onTap != null && widget.trailing == null) ...[
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded,
                size: 18, color: c.textMuted),
          ],
        ],
      ),
    );
    if (widget.onTap == null) return body;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(onTap: widget.onTap, child: body),
    );
  }
}

/// Big-number stat tile — hero numbers for sections like Usage.
/// Subtle accent glow on hover so the tile feels interactive even if
/// it's static.
class StatTile extends StatefulWidget {
  final String label;
  final String value;
  final String? subValue;
  final IconData? icon;
  final Color? tint;
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.subValue,
    this.icon,
    this.tint,
  });

  @override
  State<StatTile> createState() => _StatTileState();
}

class _StatTileState extends State<StatTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final colour = widget.tint ?? c.accentPrimary;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _hover
                ? colour.withValues(alpha: 0.45)
                : c.border,
          ),
          boxShadow: [
            BoxShadow(
              color: colour.withValues(alpha: _hover ? 0.18 : 0),
              blurRadius: 24,
              spreadRadius: -6,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: 15, color: colour),
                  const SizedBox(width: 8),
                ],
                Text(
                  widget.label,
                  style: GoogleFonts.firaCode(
                    fontSize: 11.5,
                    color: c.textMuted,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              widget.value,
              style: GoogleFonts.inter(
                fontSize: 32,
                fontWeight: FontWeight.w800,
                color: colour,
                letterSpacing: -0.6,
                height: 1.05,
              ),
            ),
            if (widget.subValue != null) ...[
              const SizedBox(height: 4),
              Text(
                widget.subValue!,
                style: GoogleFonts.firaCode(
                  fontSize: 12,
                  color: c.textMuted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
