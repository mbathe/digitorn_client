import 'package:flutter/material.dart';

/// Minimalist bar-chart sparkline for activation counts over time.
///
/// Takes a flat list of integers — typically 24 hourly buckets — and
/// draws them as rounded vertical bars scaled to the widget's height.
/// Bars use [color] for filled buckets and [trackColor] for empty
/// ones, so a 24h series with a quiet midnight still looks shapely.
class Sparkline extends StatelessWidget {
  final List<int> values;
  final Color color;
  final Color trackColor;
  final double barGap;
  final double barRadius;

  const Sparkline({
    super.key,
    required this.values,
    required this.color,
    required this.trackColor,
    this.barGap = 2,
    this.barRadius = 1.5,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SparklinePainter(
        values: values,
        color: color,
        trackColor: trackColor,
        barGap: barGap,
        barRadius: barRadius,
      ),
      size: Size.infinite,
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<int> values;
  final Color color;
  final Color trackColor;
  final double barGap;
  final double barRadius;

  const _SparklinePainter({
    required this.values,
    required this.color,
    required this.trackColor,
    required this.barGap,
    required this.barRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty || size.width <= 0 || size.height <= 0) return;

    final n = values.length;
    final maxV = values.fold<int>(0, (m, v) => v > m ? v : m);
    // Keep a tiny floor so an all-zero series still shows track bars.
    final effectiveMax = maxV == 0 ? 1 : maxV;

    final totalGap = barGap * (n - 1);
    final barWidth = (size.width - totalGap) / n;
    if (barWidth <= 0) return;

    final fillPaint = Paint()..color = color;
    final trackPaint = Paint()..color = trackColor;

    for (var i = 0; i < n; i++) {
      final v = values[i];
      final x = i * (barWidth + barGap);

      // Track — always drawn so empty buckets have visual presence.
      final trackRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, 0, barWidth, size.height),
        Radius.circular(barRadius),
      );
      canvas.drawRRect(trackRect, trackPaint);

      if (v <= 0) continue;
      final h = (v / effectiveMax) * size.height;
      final y = size.height - h;
      final fillRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, barWidth, h),
        Radius.circular(barRadius),
      );
      canvas.drawRRect(fillRect, fillPaint);
    }
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.values != values ||
      old.color != color ||
      old.trackColor != trackColor ||
      old.barGap != barGap ||
      old.barRadius != barRadius;
}
