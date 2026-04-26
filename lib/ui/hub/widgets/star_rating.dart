/// Displays a rating as 5 stars with fractional fill.
///
/// - [value] is in `[0, 5]`.
/// - When [onChange] is supplied the widget becomes interactive
///   (1-5 integer picker with hover preview) — used by the review
///   form. Otherwise it's a static read-only row used in cards and
///   the package detail header.
///
/// Mirror of web `StarRating`
/// (`digitorn_web/src/components/hub/star-rating.tsx`).
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../theme/app_theme.dart';

class StarRating extends StatefulWidget {
  final double value;
  final double size;
  final bool showValue;
  final int? count;
  final ValueChanged<int>? onChange;

  const StarRating({
    super.key,
    required this.value,
    this.size = 14,
    this.showValue = false,
    this.count,
    this.onChange,
  });

  @override
  State<StarRating> createState() => _StarRatingState();
}

class _StarRatingState extends State<StarRating> {
  int? _hover;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final interactive = widget.onChange != null;
    final display = interactive && _hover != null
        ? _hover!.toDouble()
        : widget.value;

    return MouseRegion(
      onExit: (_) {
        if (_hover != null) setState(() => _hover = null);
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 1; i <= 5; i++) ...[
            _StarCell(
              size: widget.size,
              fill: (display - (i - 1)).clamp(0.0, 1.0),
              interactive: interactive,
              onHover: () {
                if (!interactive) return;
                if (_hover != i) setState(() => _hover = i);
              },
              onTap: () => widget.onChange?.call(i),
            ),
            if (i < 5) const SizedBox(width: 3),
          ],
          if (widget.showValue && widget.value > 0) ...[
            const SizedBox(width: 4),
            Text(
              widget.value.toStringAsFixed(1),
              style: GoogleFonts.jetBrainsMono(
                fontSize: widget.size - 2,
                fontWeight: FontWeight.w600,
                color: c.text,
              ),
            ),
          ],
          if (widget.count != null && widget.count! > 0) ...[
            const SizedBox(width: 4),
            Text(
              '(${_formatCount(widget.count!)})',
              style: TextStyle(
                fontSize: widget.size - 3,
                color: c.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StarCell extends StatelessWidget {
  final double size;
  final double fill;
  final bool interactive;
  final VoidCallback onHover;
  final VoidCallback onTap;

  const _StarCell({
    required this.size,
    required this.fill,
    required this.interactive,
    required this.onHover,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const tint = Color(0xFFFFC107);
    final filled = fill > 0.5;
    final half = fill > 0 && fill <= 0.5;

    Widget star = Stack(
      alignment: Alignment.centerLeft,
      children: [
        Icon(
          filled ? Icons.star_rounded : Icons.star_outline_rounded,
          size: size,
          color: tint,
        ),
        if (half)
          ClipRect(
            clipper: _HalfClipper(),
            child: Icon(Icons.star_rounded, size: size, color: tint),
          ),
      ],
    );

    if (!interactive) return SizedBox(width: size, height: size, child: star);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover(),
      onHover: (_) => onHover(),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(width: size, height: size, child: star),
      ),
    );
  }
}

class _HalfClipper extends CustomClipper<Rect> {
  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width / 2, size.height);

  @override
  bool shouldReclip(covariant CustomClipper<Rect> oldClipper) => false;
}

String _formatCount(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}
