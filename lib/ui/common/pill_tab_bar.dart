/// Pill-style tab bar used inside the Hub for the second-level
/// sub-tabs (Discover/Library/Updates inside Apps, Discover/
/// Installed/Running inside MCP). Visually distinct from the
/// Hub's top-level [TabBar] which uses a classic underline
/// indicator — pills give the user a clear hierarchy:
///
///   Top tabs    →  underline bar (Apps · Modules · MCP)
///   Sub tabs    →  pill background (Discover · Library · Updates)
///
/// Driven by a [TabController] so the existing TabBarView keeps
/// working without any wiring change.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../theme/app_theme.dart';

/// Single tab entry — label + optional badge count.
class PillTabData {
  final String label;

  /// Optional small count chip rendered to the right of the label.
  final String? badge;

  /// When true the badge uses the accent colour (blue) instead of
  /// the muted surface — used to draw attention to non-zero update
  /// counts.
  final bool badgeIsAccent;

  const PillTabData({
    required this.label,
    this.badge,
    this.badgeIsAccent = false,
  });
}

class PillTabBar extends StatefulWidget {
  final TabController controller;
  final List<PillTabData> tabs;

  const PillTabBar({
    super.key,
    required this.controller,
    required this.tabs,
  });

  @override
  State<PillTabBar> createState() => _PillTabBarState();
}

class _PillTabBarState extends State<PillTabBar> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final selected = widget.controller.index;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < widget.tabs.length; i++)
            _PillTab(
              data: widget.tabs[i],
              selected: i == selected,
              onTap: () => widget.controller.animateTo(i),
            ),
        ],
      ),
    );
  }
}

class _PillTab extends StatefulWidget {
  final PillTabData data;
  final bool selected;
  final VoidCallback onTap;
  const _PillTab({
    required this.data,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_PillTab> createState() => _PillTabState();
}

class _PillTabState extends State<_PillTab> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            color: widget.selected
                ? c.surface
                : (_h ? c.surface.withValues(alpha: 0.6) : Colors.transparent),
            borderRadius: BorderRadius.circular(8),
            boxShadow: widget.selected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
            border: widget.selected
                ? Border.all(color: c.border)
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.data.label,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: widget.selected
                      ? FontWeight.w700
                      : FontWeight.w500,
                  color: widget.selected ? c.textBright : c.textMuted,
                  letterSpacing: -0.1,
                ),
              ),
              if (widget.data.badge != null) ...[
                const SizedBox(width: 7),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: widget.data.badgeIsAccent
                        ? c.blue
                        : c.surfaceAlt,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    widget.data.badge!,
                    style: GoogleFonts.firaCode(
                      fontSize: 9.5,
                      color: widget.data.badgeIsAccent
                          ? Colors.white
                          : c.textMuted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
