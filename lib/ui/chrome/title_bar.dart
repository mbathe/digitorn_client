import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../design/tokens.dart';
import '../../theme/app_theme.dart';

/// Premium custom window title bar.
///
/// Rendered flush at the top of the app on desktop (Windows / Linux).
/// macOS keeps its native traffic-light buttons — we only reserve the
/// leading 80px so the traffic lights don't collide with our widgets.
/// Mobile and web return [SizedBox.shrink] — no-op.
class DigitornTitleBar extends StatelessWidget {
  /// Optional content rendered in the centre of the drag region
  /// (e.g. breadcrumb text, status chip). Kept empty by default.
  final Widget? centre;

  const DigitornTitleBar({super.key, this.centre});

  static bool get _show {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  static bool get _isMac =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    final c = context.colors;
    // Wrap in Material so the title bar gets a proper rendering
    // parent (ink, hover, future tooltip portals) — without it
    // sitting outside the Navigator means no Material ancestor,
    // which caused sporadic build failures on hover (the yellow
    // error overlay the user was seeing).
    return Material(
      type: MaterialType.canvas,
      color: c.bg,
      child: SizedBox(
        height: 36,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: c.bg,
            border: Border(bottom: BorderSide(color: c.border)),
          ),
          child: Row(
            children: [
              // Reserve space for macOS traffic lights (native, rendered
              // by the OS at fixed offsets). Windows / Linux start flush.
              if (_isMac) const SizedBox(width: 76),
              Expanded(
                child: _DragRegion(child: centre ?? const SizedBox.shrink()),
              ),
              if (!_isMac) const _WindowButtons(),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Drag region — consumes the whole area, translates to windowManager
// ═══════════════════════════════════════════════════════════════════

class _DragRegion extends StatelessWidget {
  final Widget child;
  const _DragRegion({required this.child});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) {
        // Best-effort — swallow errors so a bad init doesn't break drag.
        try {
          windowManager.startDragging();
        } catch (_) {}
      },
      onDoubleTap: () async {
        try {
          final maximised = await windowManager.isMaximized();
          if (maximised) {
            await windowManager.unmaximize();
          } else {
            await windowManager.maximize();
          }
        } catch (_) {}
      },
      child: Center(child: child),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Window buttons (Windows / Linux) — minimise · maximise · close
// ═══════════════════════════════════════════════════════════════════

class _WindowButtons extends StatefulWidget {
  const _WindowButtons();

  @override
  State<_WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<_WindowButtons> with WindowListener {
  bool _maximised = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _syncState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _syncState() async {
    try {
      final m = await windowManager.isMaximized();
      if (!mounted) return;
      if (m != _maximised) setState(() => _maximised = m);
    } catch (_) {}
  }

  @override
  void onWindowMaximize() => _syncState();
  @override
  void onWindowUnmaximize() => _syncState();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WindowButton(
          icon: Icons.minimize_rounded,
          onTap: () async {
            try {
              await windowManager.minimize();
            } catch (_) {}
          },
        ),
        _WindowButton(
          icon: _maximised
              ? Icons.fullscreen_exit_rounded
              : Icons.crop_square_rounded,
          onTap: () async {
            try {
              if (_maximised) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            } catch (_) {}
          },
        ),
        _WindowButton(
          icon: Icons.close_rounded,
          danger: true,
          onTap: () async {
            try {
              await windowManager.close();
            } catch (_) {}
          },
        ),
      ],
    );
  }
}

class _WindowButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;

  const _WindowButton({
    required this.icon,
    required this.onTap,
    this.danger = false,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Close button lights up in the palette's accent (coral in
    // Obsidian, cyan in Midnight, etc.) — not a stock Windows red so
    // the affordance is intentional, not alarming.
    final hoverBg = widget.danger
        ? c.accentPrimary.withValues(alpha: 0.18)
        : c.surfaceAlt;
    final hoverFg = widget.danger ? c.accentPrimary : c.textBright;
    // Tooltip deliberately omitted — the title bar sits outside the
    // Navigator so it has no Overlay ancestor, which makes Tooltip
    // throw during hover rebuilds. The icons are universal enough
    // that a tooltip isn't needed.
    return MouseRegion(
      onEnter: (_) {
        if (mounted && !_h) setState(() => _h = true);
      },
      onExit: (_) {
        if (mounted && _h) setState(() => _h = false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DsDuration.fast,
          width: 44,
          height: 36,
          alignment: Alignment.center,
          color: _h ? hoverBg : Colors.transparent,
          child: Icon(
            widget.icon,
            size: 13,
            color: _h ? hoverFg : c.textMuted,
          ),
        ),
      ),
    );
  }
}
