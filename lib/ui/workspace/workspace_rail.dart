import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../design/tokens.dart';
import '../../services/workspace_module.dart';
import '../../theme/app_theme.dart';

/// Thin always-visible rail glued to the right edge of the chat
/// zone whenever the current app declares a workspace. Click →
/// expand the full [WorkspacePanel].
///
/// Invisible entirely for apps with `workspace_mode: none` — the
/// parent layout skips mounting this widget in that case.
///
/// Design spirit: signals "your project lives here" without stealing
/// any chat real-estate. 26 px wide at rest, 32 px on hover with a
/// soft coral accent. File count + live activity dot when the agent
/// is mutating files.
class WorkspaceRail extends StatefulWidget {
  final VoidCallback onExpand;
  const WorkspaceRail({super.key, required this.onExpand});

  @override
  State<WorkspaceRail> createState() => _WorkspaceRailState();
}

class _WorkspaceRailState extends State<WorkspaceRail>
    with SingleTickerProviderStateMixin {
  bool _h = false;
  late final AnimationController _pulse;
  int _lastFileCount = 0;
  DateTime _lastChangeAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    WorkspaceModule().addListener(_onModuleChanged);
    _lastFileCount = WorkspaceModule().files.length;
  }

  @override
  void dispose() {
    _pulse.dispose();
    WorkspaceModule().removeListener(_onModuleChanged);
    super.dispose();
  }

  void _onModuleChanged() {
    final mod = WorkspaceModule();
    if (!mounted) return;
    // "Writing now" heuristic — the file map just grew or a file
    // flipped its status. Both flag a live edit. We record the
    // timestamp and let the dot stay active for ~4s of inactivity.
    final newCount = mod.files.length;
    if (newCount != _lastFileCount) {
      _lastFileCount = newCount;
      _lastChangeAt = DateTime.now();
    }
    setState(() {});
  }

  bool get _isWriting =>
      DateTime.now().difference(_lastChangeAt).inMilliseconds < 4000;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final files = WorkspaceModule().files;
    final count = files.length;
    final width = _h ? 34.0 : 26.0;
    return Tooltip(
      message: count > 0
          ? 'Workspace · $count file${count == 1 ? '' : 's'} — click to open'
          : 'Workspace — click to open',
      preferBelow: false,
      waitDuration: const Duration(milliseconds: 350),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onExpand,
          child: AnimatedContainer(
            duration: DsDuration.fast,
            curve: Curves.easeOutCubic,
            width: width,
            decoration: BoxDecoration(
              color: _h
                  ? c.accentPrimary.withValues(alpha: 0.05)
                  : c.bg,
              border: Border(
                left: BorderSide(
                  color: _h
                      ? c.accentPrimary.withValues(alpha: 0.35)
                      : c.border,
                  width: _h ? 1.2 : 1,
                ),
              ),
            ),
            child: Stack(
              children: [
                // Subtle hover shimmer on the left border.
                if (_h)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: 2,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            c.accentPrimary.withValues(alpha: 0),
                            c.accentPrimary.withValues(alpha: 0.35),
                            c.accentPrimary.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Column(
                      children: [
                        _ActivityDot(
                          writing: _isWriting,
                          hasFiles: count > 0,
                          colors: c,
                          pulse: _pulse,
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: Center(
                            child: RotatedBox(
                              quarterTurns: 3,
                              child: Text(
                                'WORKSPACE',
                                style: GoogleFonts.inter(
                                  fontSize: 9.5,
                                  letterSpacing: 2.2,
                                  fontWeight: FontWeight.w700,
                                  color: _h
                                      ? c.accentPrimary
                                      : c.textMuted,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        _FilesSilhouette(
                          count: count,
                          colors: c,
                          accent: _h,
                        ),
                        const SizedBox(height: 10),
                        _CountBadge(count: count, colors: c, accent: _h),
                        const SizedBox(height: 4),
                        AnimatedOpacity(
                          duration: DsDuration.fast,
                          opacity: _h ? 1 : 0,
                          child: Icon(
                            Icons.chevron_left_rounded,
                            size: 14,
                            color: c.accentPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Activity dot: pulses coral while the workspace mutates ────────────────

class _ActivityDot extends StatelessWidget {
  final bool writing;
  final bool hasFiles;
  final AppColors colors;
  final AnimationController pulse;
  const _ActivityDot({
    required this.writing,
    required this.hasFiles,
    required this.colors,
    required this.pulse,
  });

  @override
  Widget build(BuildContext context) {
    final baseColor = writing
        ? colors.accentPrimary
        : hasFiles
            ? colors.textMuted
            : colors.textDim;
    if (!writing) {
      return Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: baseColor.withValues(alpha: 0.65),
          shape: BoxShape.circle,
        ),
      );
    }
    return AnimatedBuilder(
      animation: pulse,
      builder: (_, _) {
        final alpha = 0.55 + (0.4 * pulse.value);
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: baseColor.withValues(alpha: alpha),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: baseColor.withValues(alpha: alpha * 0.55),
                blurRadius: 6,
                spreadRadius: 1,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── File silhouettes — stacked mini rectangles hinting at content ─────────

class _FilesSilhouette extends StatelessWidget {
  final int count;
  final AppColors colors;
  final bool accent;
  const _FilesSilhouette({
    required this.count,
    required this.colors,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    if (count == 0) return const SizedBox.shrink();
    final shown = count.clamp(1, 3);
    final color = accent ? colors.accentPrimary : colors.textDim;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < shown; i++) ...[
          Container(
            width: 14 - (i * 1.5),
            height: 2,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.35 + (i * 0.15)),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
          if (i != shown - 1) const SizedBox(height: 3),
        ],
      ],
    );
  }
}

// ─── Count badge at the bottom ─────────────────────────────────────────────

class _CountBadge extends StatelessWidget {
  final int count;
  final AppColors colors;
  final bool accent;
  const _CountBadge({
    required this.count,
    required this.colors,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    if (count == 0) {
      return Container(
        width: 18,
        height: 18,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: colors.border),
        ),
        child: Text(
          '·',
          style: GoogleFonts.firaCode(
            fontSize: 10,
            color: colors.textDim,
            height: 1,
          ),
        ),
      );
    }
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: accent
            ? colors.accentPrimary.withValues(alpha: 0.15)
            : colors.surfaceAlt,
        borderRadius: BorderRadius.circular(DsRadius.pill),
        border: Border.all(
          color: accent
              ? colors.accentPrimary.withValues(alpha: 0.4)
              : colors.border,
        ),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: GoogleFonts.firaCode(
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          color: accent ? colors.accentPrimary : colors.textMuted,
          height: 1.2,
        ),
      ),
    );
  }
}
