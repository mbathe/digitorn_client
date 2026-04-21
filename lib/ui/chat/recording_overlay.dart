/// In-chat recording overlay. Mounted above the composer while
/// [VoiceInputService] is listening. Shows:
///
///   * Pulsing red dot
///   * Live timer (0:00 → 1:23)
///   * Waveform animated from the recorder's amplitude stream
///   * Cancel  → drops the recording, nothing sent
///   * Stop    → finalises (server transcribes / audio attaches,
///                 depending on mode)
///
/// The service owns all the state — this widget just renders it via
/// a ListenableBuilder so the timer updates automatically.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/voice_input_service.dart';
import '../../theme/app_theme.dart';

class RecordingOverlay extends StatelessWidget {
  /// User tapped Stop — caller pushes the transcript into the
  /// composer (live mode) or attaches the audio (server/record
  /// mode). The overlay itself just decides to show/hide.
  final Future<void> Function() onStop;
  final VoidCallback onCancel;

  const RecordingOverlay({
    super.key,
    required this.onStop,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: VoiceInputService(),
      builder: (context, _) {
        final svc = VoiceInputService();
        final listening = svc.state == VoiceState.listening;
        final processing = svc.state == VoiceState.processing;
        if (!listening && !processing) return const SizedBox.shrink();
        final c = context.colors;
        final isSmall = MediaQuery.of(context).size.width < 600;
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: isSmall ? double.infinity : 720),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                  isSmall ? 12 : 16, 8, isSmall ? 12 : 16, 4),
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                decoration: BoxDecoration(
                  color: processing
                      ? c.blue.withValues(alpha: 0.08)
                      : c.red.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: processing
                        ? c.blue.withValues(alpha: 0.3)
                        : c.red.withValues(alpha: 0.3),
                  ),
                ),
                child: processing
                    ? _ProcessingRow(color: c.blue)
                    : _RecordingRow(
                        elapsed: svc.elapsed,
                        amplitudes: svc.amplitudeHistory,
                        mode: svc.mode,
                        onStop: onStop,
                        onCancel: onCancel,
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─── Recording row ──────────────────────────────────────────────────

class _RecordingRow extends StatelessWidget {
  final Duration elapsed;
  final List<double> amplitudes;
  final VoiceMode mode;
  final Future<void> Function() onStop;
  final VoidCallback onCancel;
  const _RecordingRow({
    required this.elapsed,
    required this.amplitudes,
    required this.mode,
    required this.onStop,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        _PulsingDot(color: c.red),
        const SizedBox(width: 10),
        Text(
          _formatDuration(elapsed),
          style: GoogleFonts.firaCode(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: c.red,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: _Waveform(amplitudes: amplitudes, color: c.red)),
        const SizedBox(width: 10),
        _ModeLabel(mode: mode),
        const SizedBox(width: 8),
        _SquareBtn(
          tooltip: 'Cancel',
          icon: Icons.close_rounded,
          color: c.textMuted,
          onTap: onCancel,
        ),
        const SizedBox(width: 6),
        _SquareBtn(
          tooltip: mode == VoiceMode.liveTranscribe
              ? 'Stop dictation'
              : mode == VoiceMode.serverTranscribe
                  ? 'Stop and transcribe'
                  : 'Stop and attach',
          icon: Icons.check_rounded,
          color: Colors.white,
          background: c.red,
          onTap: () => onStop(),
        ),
      ],
    );
  }

  static String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return '${m.toString().padLeft(1, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

// ─── Processing state (after Stop, while daemon transcribes) ──────

class _ProcessingRow extends StatelessWidget {
  final Color color;
  const _ProcessingRow({required this.color});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 1.6, color: color),
        ),
        const SizedBox(width: 10),
        Text(
          'Transcribing…',
          style: GoogleFonts.inter(
              fontSize: 12.5, color: c.text, fontWeight: FontWeight.w500),
        ),
        const Spacer(),
        Text(
          'The server is processing your audio',
          style: GoogleFonts.inter(fontSize: 11, color: c.textMuted),
        ),
      ],
    );
  }
}

// ─── Pulsing dot (breathing ~1 Hz) ─────────────────────────────────

class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) {
        final a = 0.55 + 0.45 * _ctrl.value;
        return Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: a),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: a * 0.6),
                blurRadius: 8,
                spreadRadius: 2,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Waveform ──────────────────────────────────────────────────────

class _Waveform extends StatelessWidget {
  final List<double> amplitudes;
  final Color color;
  const _Waveform({required this.amplitudes, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 24,
      child: CustomPaint(
        painter: _WaveformPainter(amplitudes: amplitudes, color: color),
        size: Size.infinite,
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final List<double> amplitudes;
  final Color color;
  _WaveformPainter({required this.amplitudes, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0) return;
    const barWidth = 2.0;
    const barGap = 2.0;
    final maxBars = (size.width / (barWidth + barGap)).floor();
    final samples = amplitudes.length >= maxBars
        ? amplitudes.sublist(amplitudes.length - maxBars)
        : List<double>.filled(
                maxBars - amplitudes.length, 0.05,
                growable: false) +
            amplitudes;
    final paint = Paint()..color = color;
    final mid = size.height / 2;
    for (var i = 0; i < samples.length; i++) {
      final a = samples[i].clamp(0.05, 1.0);
      final h = a * size.height;
      final x = i * (barWidth + barGap);
      final top = mid - h / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, top, barWidth, h),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter old) =>
      old.amplitudes != amplitudes || old.color != color;
}

// ─── Helpers ───────────────────────────────────────────────────────

class _ModeLabel extends StatelessWidget {
  final VoiceMode mode;
  const _ModeLabel({required this.mode});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final label = switch (mode) {
      VoiceMode.liveTranscribe => 'Live',
      VoiceMode.serverTranscribe => 'Whisper',
      VoiceMode.recordAudio => 'Audio',
      VoiceMode.unavailable => '',
    };
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.border),
      ),
      child: Text(
        label,
        style: GoogleFonts.firaCode(
            fontSize: 9.5,
            fontWeight: FontWeight.w600,
            color: c.textMuted),
      ),
    );
  }
}

class _SquareBtn extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final Color color;
  final Color? background;
  final VoidCallback onTap;
  const _SquareBtn({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onTap,
    this.background,
  });

  @override
  State<_SquareBtn> createState() => _SquareBtnState();
}

class _SquareBtnState extends State<_SquareBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hasBg = widget.background != null;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) {
          if (!_h && mounted) setState(() => _h = true);
        },
        onExit: (_) {
          if (_h && mounted) setState(() => _h = false);
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: hasBg
                  ? (widget.background!)
                  : (_h ? c.surfaceAlt : Colors.transparent),
              borderRadius: BorderRadius.circular(7),
              border: hasBg
                  ? null
                  : Border.all(
                      color: _h ? c.border : Colors.transparent),
            ),
            child: Icon(widget.icon, size: 16, color: widget.color),
          ),
        ),
      ),
    );
  }
}
