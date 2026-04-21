import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../design/ds.dart';
import '../../theme/app_theme.dart';

/// The Digitorn brand mark — a rounded-square tile with the
/// accent gradient, a faint inner highlight at the top-left
/// (for a "soft ceramic" feel), and the logo asset on top.
class DsBrandMark extends StatelessWidget {
  final double size;
  final bool glow;

  const DsBrandMark({super.key, this.size = 48, this.glow = true});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final r = size * 0.24;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(r),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            c.accentPrimary,
            Color.lerp(c.accentPrimary, c.accentSecondary, 0.55) ??
                c.accentSecondary,
          ],
        ),
        boxShadow: glow
            ? DsElevation.accentGlow(c.accentPrimary, strength: 0.8)
            : null,
      ),
      child: Stack(
        children: [
          // Inner top-left highlight — fakes light falling on a
          // soft surface without looking like a cheap gloss.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(r),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.center,
                  colors: [
                    Colors.white.withValues(alpha: 0.22),
                    Colors.white.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
          // Logo asset tinted to onAccent so it reads on top.
          Center(
            child: SizedBox(
              width: size * 0.54,
              height: size * 0.54,
              child: ColorFiltered(
                colorFilter:
                    ColorFilter.mode(c.onAccent, BlendMode.srcIn),
                child: Image.asset(
                  'assets/logo.png',
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => Icon(
                    Icons.auto_awesome,
                    color: c.onAccent,
                    size: size * 0.5,
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

/// Signature Digitorn background — a subtle warm/cool aurora that
/// drifts slowly diagonally, with a noise grain overlay. Replaces
/// the cliché radial-blob background used everywhere. Keep as a
/// full-bleed Stack behind any hero surface.
class DsAuroraBackground extends StatefulWidget {
  final Widget? child;
  final double strength;

  const DsAuroraBackground({
    super.key,
    this.child,
    this.strength = 1.0,
  });

  @override
  State<DsAuroraBackground> createState() => _DsAuroraBackgroundState();
}

class _DsAuroraBackgroundState extends State<DsAuroraBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t;

  @override
  void initState() {
    super.initState();
    _t = AnimationController(vsync: this, duration: DsDuration.ambient)
      ..repeat();
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: c.bg),
        AnimatedBuilder(
          animation: _t,
          builder: (_, _) {
            return CustomPaint(
              painter: _AuroraPainter(
                t: _t.value,
                warm: c.accentPrimary.withValues(
                    alpha: 0.18 * widget.strength),
                cool: c.accentSecondary.withValues(
                    alpha: 0.12 * widget.strength),
              ),
              size: Size.infinite,
            );
          },
        ),
        CustomPaint(
          painter: _GrainPainter(
            tint: c.textBright.withValues(alpha: 0.015),
          ),
          size: Size.infinite,
        ),
        if (widget.child != null) widget.child!,
      ],
    );
  }
}

class _AuroraPainter extends CustomPainter {
  final double t;
  final Color warm;
  final Color cool;

  _AuroraPainter({required this.t, required this.warm, required this.cool});

  @override
  void paint(Canvas canvas, Size size) {
    final phase = t * 2 * math.pi;
    // Warm band — bottom-right, slow drift.
    final warmRect = Rect.fromLTWH(
      size.width * (0.3 + 0.05 * math.sin(phase)),
      size.height * (0.4 + 0.05 * math.cos(phase * 0.7)),
      size.width,
      size.height,
    );
    final warmPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Colors.transparent, warm],
      ).createShader(warmRect)
      ..blendMode = BlendMode.screen;

    // Cool band — top-left, slower drift, opposite phase.
    final coolRect = Rect.fromLTWH(
      -size.width * (0.2 + 0.05 * math.cos(phase * 0.5)),
      -size.height * (0.1 + 0.04 * math.sin(phase * 0.5)),
      size.width,
      size.height,
    );
    final coolPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomRight,
        end: Alignment.topLeft,
        colors: [Colors.transparent, cool],
      ).createShader(coolRect)
      ..blendMode = BlendMode.screen;

    canvas.drawRect(Offset.zero & size, warmPaint);
    canvas.drawRect(Offset.zero & size, coolPaint);
  }

  @override
  bool shouldRepaint(covariant _AuroraPainter old) =>
      old.t != t || old.warm != warm || old.cool != cool;
}

/// Deterministic noise grain — draws a single-pass dot pattern.
/// Cheaper than a real noise shader and reads as "paper grain"
/// when the tint alpha stays under 2%.
class _GrainPainter extends CustomPainter {
  final Color tint;
  _GrainPainter({required this.tint});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = tint;
    final rnd = math.Random(42);
    final count = (size.width * size.height / 320).clamp(200, 4000).toInt();
    for (int i = 0; i < count; i++) {
      final dx = rnd.nextDouble() * size.width;
      final dy = rnd.nextDouble() * size.height;
      canvas.drawCircle(Offset(dx, dy), 0.5, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GrainPainter old) => old.tint != tint;
}
