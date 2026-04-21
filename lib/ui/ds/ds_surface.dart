import 'package:flutter/material.dart';

import '../../design/ds.dart';
import '../../theme/app_theme.dart';

enum DsSurfaceElevation { flat, raise, float, hero }

/// Layered container — inner 1px border + elevation shadow.
/// The building block under every card, panel, popover.
class DsSurface extends StatelessWidget {
  final Widget child;
  final DsSurfaceElevation elevation;
  final double? radius;
  final EdgeInsetsGeometry? padding;
  final Color? background;
  final Color? borderColor;
  final double? width;
  final double? height;
  final VoidCallback? onTap;

  const DsSurface({
    super.key,
    required this.child,
    this.elevation = DsSurfaceElevation.flat,
    this.radius,
    this.padding,
    this.background,
    this.borderColor,
    this.width,
    this.height,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final r = BorderRadius.circular(radius ?? DsRadius.card);
    final shadows = switch (elevation) {
      DsSurfaceElevation.flat => DsElevation.flat,
      DsSurfaceElevation.raise => DsElevation.raise(c.shadow),
      DsSurfaceElevation.float => DsElevation.float(c.shadow),
      DsSurfaceElevation.hero => DsElevation.hero(c.shadow),
    };
    final box = Container(
      width: width,
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        color: background ?? c.surface,
        borderRadius: r,
        border: Border.all(
          color: borderColor ?? c.border,
          width: DsStroke.hairline,
        ),
        boxShadow: shadows,
      ),
      child: child,
    );
    if (onTap == null) return box;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: r,
        onTap: onTap,
        child: box,
      ),
    );
  }
}

/// Interactive card — same shape as DsSurface but with hover +
/// press feedback. Use for selection grids (palette picker, app
/// picker, role picker).
class DsCard extends StatefulWidget {
  final Widget child;
  final bool selected;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? padding;
  final double? radius;

  const DsCard({
    super.key,
    required this.child,
    this.selected = false,
    this.onTap,
    this.padding,
    this.radius,
  });

  @override
  State<DsCard> createState() => _DsCardState();
}

class _DsCardState extends State<DsCard> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final r = BorderRadius.circular(widget.radius ?? DsRadius.card);
    final borderColor = widget.selected
        ? c.accentPrimary
        : (_hover ? c.borderHover : c.border);
    final shadow = widget.selected
        ? DsElevation.accentGlow(c.accentPrimary, strength: 0.3)
        : (_hover
            ? DsElevation.float(c.shadow)
            : DsElevation.raise(c.shadow));
    return MouseRegion(
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown:
            widget.onTap == null ? null : (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          duration: DsDuration.fast,
          curve: DsCurve.decelSnap,
          scale: _pressed ? 0.99 : 1.0,
          child: AnimatedContainer(
            duration: DsDuration.base,
            curve: DsCurve.decelSnap,
            padding: widget.padding,
            decoration: BoxDecoration(
              color: widget.selected
                  ? Color.lerp(c.surface, c.accentPrimary, 0.06)
                  : (_hover ? c.surfaceAlt : c.surface),
              borderRadius: r,
              border: Border.all(
                color: borderColor,
                width: widget.selected ? DsStroke.normal : DsStroke.hairline,
              ),
              boxShadow: shadow,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
