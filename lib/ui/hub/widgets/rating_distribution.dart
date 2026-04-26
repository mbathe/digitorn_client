/// Stacked summary used in the package-detail Reviews tab:
///   - Big avg rating + 5 stars + total count on the left
///   - 5 horizontal bars (5★ → 1★) with count on the right
///
/// Mirror of web `RatingDistribution`
/// (`digitorn_web/src/components/hub/rating-distribution.tsx`).
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../theme/app_theme.dart';
import 'star_rating.dart';

class RatingDistribution extends StatelessWidget {
  final double? avg;
  final int total;

  /// Map "1".."5" → count (matches `HubReviewListResponse.distribution`).
  final Map<String, int> distribution;

  const RatingDistribution({
    super.key,
    required this.avg,
    required this.total,
    required this.distribution,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final values = [
      distribution['5'] ?? 0,
      distribution['4'] ?? 0,
      distribution['3'] ?? 0,
      distribution['2'] ?? 0,
      distribution['1'] ?? 0,
    ];
    final maxV = values.fold<int>(1, (m, v) => v > m ? v : m);
    final safeAvg = avg ?? 0.0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 110,
            child: Column(
              children: [
                Text(
                  safeAvg.toStringAsFixed(1),
                  style: GoogleFonts.inter(
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    color: c.textBright,
                    letterSpacing: -1,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 4),
                StarRating(value: safeAvg, size: 14),
                const SizedBox(height: 4),
                Text(
                  '$total ${total == 1 ? "review" : "reviews"}',
                  style: TextStyle(fontSize: 11, color: c.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Column(
              children: [
                for (var i = 0; i < 5; i++) ...[
                  _Row(star: 5 - i, value: values[i], max: maxV),
                  if (i < 4) const SizedBox(height: 5),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final int star;
  final int value;
  final int max;
  const _Row({required this.star, required this.value, required this.max});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final pct = max > 0 ? value / max : 0.0;
    final mono = GoogleFonts.jetBrainsMono(fontSize: 11, color: c.textMuted);

    return Row(
      children: [
        SizedBox(
          width: 14,
          child: Text('$star', style: mono, textAlign: TextAlign.right),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Stack(
            children: [
              Container(
                height: 6,
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              FractionallySizedBox(
                widthFactor: pct,
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFC107),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 36,
          child: Text('$value', style: mono, textAlign: TextAlign.right),
        ),
      ],
    );
  }
}
