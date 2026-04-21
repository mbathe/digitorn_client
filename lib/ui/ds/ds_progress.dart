import 'package:flutter/material.dart';

import '../../design/ds.dart';
import '../../theme/app_theme.dart';

/// Minimal progress indicator for wizards — a row of short bars,
/// current one tinted accent, completed ones textMuted, upcoming
/// ones border. Dots are replaced by 2-px thin bars because bars
/// carry a clearer sense of "forward motion" in narrow viewports.
class DsProgressBars extends StatelessWidget {
  final int total;
  final int current;
  final double barWidth;
  final double gap;
  final bool clickableBack;
  final void Function(int index)? onJump;

  const DsProgressBars({
    super.key,
    required this.total,
    required this.current,
    this.barWidth = 22,
    this.gap = 6,
    this.clickableBack = false,
    this.onJump,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [
        for (int i = 0; i < total; i++)
          _bar(c, i),
      ],
    );
  }

  Widget _bar(AppColors c, int i) {
    final color = i < current
        ? c.textMuted
        : i == current
            ? c.accentPrimary
            : c.border;
    final bar = AnimatedContainer(
      duration: DsDuration.base,
      curve: DsCurve.decelSoft,
      width: barWidth,
      height: 2,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(2),
        boxShadow: i == current
            ? [
                BoxShadow(
                  color: c.accentPrimary.withValues(alpha: 0.5),
                  blurRadius: 6,
                  spreadRadius: -1,
                ),
              ]
            : null,
      ),
    );
    final clickable = clickableBack && i < current && onJump != null;
    if (!clickable) return bar;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onJump!(i),
        child: bar,
      ),
    );
  }
}

/// Step counter label — "STEP 03 / 08". Used alongside DsProgressBars
/// on compact viewports.
class DsStepCounter extends StatelessWidget {
  final int current;
  final int total;

  const DsStepCounter({
    super.key,
    required this.current,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Text(
      'STEP ${(current + 1).toString().padLeft(2, '0')} / '
      '${total.toString().padLeft(2, '0')}',
      style: DsType.eyebrow(color: c.textMuted),
    );
  }
}
