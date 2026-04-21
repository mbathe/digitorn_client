import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../design/tokens.dart';
import '../../models/session_metrics.dart';
import '../../theme/app_theme.dart';

/// Context panel — inline widget positioned above the chat input.
/// Not a dialog — it's a widget toggled by the parent.
class ContextPanel extends StatelessWidget {
  final VoidCallback onClose;
  const ContextPanel({super.key, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cs = context.watch<ContextState>();
    final m = context.watch<SessionMetrics>();

    final total = cs.effectiveMax > 0 ? cs.effectiveMax : cs.maxTokens;
    final used = cs.totalEstimatedTokens;
    final available = cs.availableTokens;
    // Two values coexist in this panel:
    //   * `rawPressure` = used / total — drives the SEGMENT bar
    //     widths (it's a "how the capacity is sliced" view).
    //   * `displayPressure` = rawPressure / threshold — drives the
    //     arc gauge and colors, because "distance to compaction" is
    //     the actionable metric the user reads first.
    final rawPressure = cs.pressure;
    final displayPressure = cs.displayPressure;
    final threshold = cs.threshold;

    final pressureColor = displayPressure < 0.67
        ? c.green
        : displayPressure < 0.85
            ? c.orange
            : c.red;

    final segments = <_Seg>[
      if (cs.systemPromptTokens > 0)
        _Seg('System', cs.systemPromptTokens, c.blue),
      if (cs.toolsSchemaTokens > 0)
        _Seg('Tools', cs.toolsSchemaTokens, c.purple),
      if (cs.messageHistoryTokens > 0)
        _Seg('Messages', cs.messageHistoryTokens, c.green),
    ];

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 12,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header + close
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 0),
            child: Row(
              children: [
                Text('Context',
                  style: GoogleFonts.inter(
                    fontSize: 13, fontWeight: FontWeight.w600, color: c.textBright)),
                const SizedBox(width: 8),
                if (m.model.isNotEmpty)
                  Text(m.model,
                    style: GoogleFonts.firaCode(fontSize: 10, color: c.textDim)),
                const Spacer(),
                if (cs.compactions > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text('${cs.compactions} compactions',
                      style: GoogleFonts.firaCode(fontSize: 10, color: c.textDim)),
                  ),
                Tooltip(
                  message: 'Close',
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: onClose,
                      child: Icon(Icons.close_rounded, size: 16, color: c.textMuted),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Main row: gauge + breakdown
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                // Arc gauge — animate the displayPressure / color
                // transitions so the arc glides instead of snapping
                // when a new turn pushes the counter up. The headline
                // number is "% toward compaction" since that's what
                // the user can actually act on.
                SizedBox(
                  width: 72,
                  height: 72,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(
                        begin: 0, end: displayPressure.clamp(0.0, 1.2)),
                    duration: const Duration(milliseconds: 360),
                    curve: Curves.easeOutCubic,
                    builder: (_, animDisplay, _) {
                      return TweenAnimationBuilder<Color?>(
                        tween: ColorTween(begin: pressureColor, end: pressureColor),
                        duration: const Duration(milliseconds: 360),
                        curve: Curves.easeOut,
                        builder: (_, animColor, _) {
                          return CustomPaint(
                            painter: _ArcGaugePainter(
                              pressure: animDisplay,
                              color: animColor ?? pressureColor,
                              trackColor: c.border,
                              segments: segments
                                  .map((s) => _ArcSeg(
                                      s.value /
                                          (total > 0 ? total : 1),
                                      s.color))
                                  .toList(),
                            ),
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '${(animDisplay * 100).round()}%',
                                    style: GoogleFonts.inter(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700,
                                      color:
                                          animColor ?? pressureColor,
                                    ),
                                  ),
                                  Text(
                                    'to compact',
                                    style: GoogleFonts.inter(
                                      fontSize: 9,
                                      color: c.textDim,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(width: 16),

                // Breakdown
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Segmented bar
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: SizedBox(
                          height: 6,
                          child: total > 0
                              ? Row(
                                  children: [
                                    ...segments.map((s) => Expanded(
                                      flex: s.value,
                                      child: Container(color: s.color),
                                    )),
                                    if (available > 0)
                                      Expanded(
                                        flex: available,
                                        child: Container(color: c.border),
                                      ),
                                  ],
                                )
                              : Container(color: c.border),
                        ),
                      ),
                      const SizedBox(height: 10),
                      // Legend rows
                      for (final s in segments)
                        _legendRow(s.label, s.value, s.color, total, c),
                      _legendRow('Available', available, c.border, total, c),
                      const SizedBox(height: 6),
                      // Totals — show both figures so the user can
                      // reconcile "15 % of capacity" (raw) vs
                      // "20 % to compaction" (threshold-relative).
                      Row(
                        children: [
                          Text('${_fmt(used)} / ${_fmt(total)}',
                            style: GoogleFonts.firaCode(
                                fontSize: 10, color: c.textMuted)),
                          const SizedBox(width: 8),
                          Text('(${(rawPressure * 100).toStringAsFixed(1)}% '
                              'of limit · trigger ${(threshold * 100).round()}%)',
                            style: GoogleFonts.firaCode(
                                fontSize: 10, color: c.textDim)),
                          const Spacer(),
                          if (cs.outputReserved > 0)
                            Text('${_fmt(cs.outputReserved)} reserved',
                              style: GoogleFonts.firaCode(
                                  fontSize: 10, color: c.textDim)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Trigger suggestions at 80 % toward the compaction
          // threshold, not 70 % of absolute capacity — the raw value
          // is slippery ("70 % of a 200 k window" still has 60 k left),
          // while the threshold-relative one is actionable.
          if (displayPressure >= 0.80)
            _ContextSuggestions(
              pressure: displayPressure,
              available: available,
              colors: c,
              compactions: cs.compactions,
            ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  Widget _legendRow(String label, int tokens, Color color, int total, AppColors c) {
    final pct = total > 0 ? (tokens / total * 100).toStringAsFixed(1) : '0';
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          Container(width: 8, height: 8,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 6),
          Text(label, style: GoogleFonts.inter(fontSize: 11, color: c.text)),
          const Spacer(),
          Text(_fmt(tokens), style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted)),
          const SizedBox(width: 6),
          SizedBox(width: 32,
            child: Text('$pct%', textAlign: TextAlign.right,
              style: GoogleFonts.firaCode(fontSize: 10, color: c.textDim))),
        ],
      ),
    );
  }

  static String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return n.toString();
  }
}

class _Seg {
  final String label;
  final int value;
  final Color color;
  const _Seg(this.label, this.value, this.color);
}

/// "Heads-up" band shown when `pressure >= 0.7` — surfaces the most
/// helpful thing the user can do instead of leaving them to infer it
/// from raw token counts. Copy adapts to severity (0.7–0.9 warn,
/// >=0.9 critical) and, when the daemon has already kicked in auto-
/// compactions, gently mentions it so the user knows what's going on.
class _ContextSuggestions extends StatelessWidget {
  final double pressure;
  final int available;
  final AppColors colors;
  final int compactions;

  const _ContextSuggestions({
    required this.pressure,
    required this.available,
    required this.colors,
    required this.compactions,
  });

  @override
  Widget build(BuildContext context) {
    // `pressure` here is threshold-relative (displayPressure).
    // `>= 1.0` means we're past the compaction trigger (daemon will
    // compact on the next turn). `>= 0.95` means basically there.
    final critical = pressure >= 0.95;
    final accent = critical ? colors.red : colors.orange;
    final title = critical
        ? 'Compaction imminent'
        : 'Context is getting tight';
    final lines = <String>[
      if (critical)
        'Auto-compaction will fire on the next turn — older messages will be summarised.'
      else
        'About ${(pressure * 100).round()}% of the way to auto-compaction '
            '(~${_fmt(available)} tokens of headroom left).',
      'Start a fresh session for unrelated tasks; it keeps the first reply on a clean slate.',
      if (compactions > 0)
        'The runtime has already compacted history $compactions time${compactions == 1 ? '' : 's'} for this session.',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Container(
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(DsRadius.xs),
          border: Border.all(color: accent.withValues(alpha: 0.3)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              critical
                  ? Icons.warning_rounded
                  : Icons.lightbulb_outline_rounded,
              size: 14,
              color: accent,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: accent,
                      letterSpacing: -0.1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final line in lines)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '· $line',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: colors.text,
                          height: 1.45,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return n.toString();
  }
}

class _ArcSeg {
  final double fraction;
  final Color color;
  const _ArcSeg(this.fraction, this.color);
}

class _ArcGaugePainter extends CustomPainter {
  final double pressure;
  final Color color;
  final Color trackColor;
  final List<_ArcSeg> segments;

  _ArcGaugePainter({
    required this.pressure,
    required this.color,
    required this.trackColor,
    required this.segments,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 4;
    const startAngle = math.pi * 0.75; // 135 degrees
    const sweepTotal = math.pi * 1.5; // 270 degrees arc
    const strokeWidth = 6.0;

    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    // Draw track
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle, sweepTotal, false, trackPaint,
    );

    // Draw segments
    double currentAngle = startAngle;
    for (final seg in segments) {
      final sweep = sweepTotal * seg.fraction;
      if (sweep <= 0) continue;
      final segPaint = Paint()
        ..color = seg.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.butt;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        currentAngle, sweep, false, segPaint,
      );
      currentAngle += sweep;
    }
  }

  @override
  bool shouldRepaint(_ArcGaugePainter old) =>
      pressure != old.pressure || segments.length != old.segments.length;
}
