import 'package:flutter/material.dart';

import '../../design/ds.dart';
import '../../theme/app_theme.dart';

enum DsButtonVariant { primary, secondary, ghost, tertiary, danger }

enum DsButtonSize { sm, md, lg }

/// Premium button — coral-glow primary, bordered secondary, ghost,
/// tertiary (text-only), danger. Handles hover, press (scale),
/// disabled and loading states.
class DsButton extends StatefulWidget {
  final String label;
  final VoidCallback? onPressed;
  final DsButtonVariant variant;
  final DsButtonSize size;
  final IconData? leadingIcon;
  final IconData? trailingIcon;
  final bool loading;
  final bool expand;
  final FocusNode? focusNode;
  final bool autofocus;

  const DsButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = DsButtonVariant.primary,
    this.size = DsButtonSize.md,
    this.leadingIcon,
    this.trailingIcon,
    this.loading = false,
    this.expand = false,
    this.focusNode,
    this.autofocus = false,
  });

  @override
  State<DsButton> createState() => _DsButtonState();
}

class _DsButtonState extends State<DsButton> {
  bool _hover = false;
  bool _pressed = false;
  bool _focused = false;

  bool get _disabled => widget.onPressed == null || widget.loading;

  double get _height => switch (widget.size) {
        DsButtonSize.sm => 32,
        DsButtonSize.md => 42,
        DsButtonSize.lg => 52,
      };

  double get _hPad => switch (widget.size) {
        DsButtonSize.sm => DsSpacing.x4,
        DsButtonSize.md => DsSpacing.x6,
        DsButtonSize.lg => DsSpacing.x7,
      };

  double get _iconSize => switch (widget.size) {
        DsButtonSize.sm => 14,
        DsButtonSize.md => 16,
        DsButtonSize.lg => 18,
      };

  double get _fontSize => switch (widget.size) {
        DsButtonSize.sm => 12.5,
        DsButtonSize.md => 14,
        DsButtonSize.lg => 15,
      };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return FocusableActionDetector(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      enabled: !_disabled,
      mouseCursor: _disabled
          ? SystemMouseCursors.forbidden
          : SystemMouseCursors.click,
      onShowHoverHighlight: (v) => setState(() => _hover = v),
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onPressed?.call();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _disabled ? null : (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: _disabled ? null : widget.onPressed,
        child: AnimatedScale(
          duration: DsDuration.fast,
          curve: DsCurve.decelSnap,
          scale: _pressed ? 0.985 : 1.0,
          child: _buildBody(c),
        ),
      ),
    );
  }

  Widget _buildBody(AppColors c) {
    final deco = _decoration(c);
    final fg = _foregroundColor(c);
    final child = Padding(
      padding: EdgeInsets.symmetric(horizontal: _hPad),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
        children: [
          if (widget.loading)
            SizedBox(
              width: _iconSize + 2,
              height: _iconSize + 2,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: fg,
              ),
            )
          else if (widget.leadingIcon != null) ...[
            Icon(widget.leadingIcon, size: _iconSize, color: fg),
            SizedBox(width: DsSpacing.x3),
          ],
          Flexible(
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DsType.button(color: fg).copyWith(fontSize: _fontSize),
            ),
          ),
          if (!widget.loading && widget.trailingIcon != null) ...[
            SizedBox(width: DsSpacing.x3),
            Icon(widget.trailingIcon, size: _iconSize, color: fg),
          ],
        ],
      ),
    );

    return AnimatedContainer(
      duration: DsDuration.base,
      curve: DsCurve.decelSnap,
      height: _height,
      width: widget.expand ? double.infinity : null,
      decoration: deco,
      child: Center(child: child),
    );
  }

  BoxDecoration _decoration(AppColors c) {
    final radius = BorderRadius.circular(DsRadius.input);
    final accent = c.accentPrimary;
    switch (widget.variant) {
      case DsButtonVariant.primary:
        final glowStrength = _disabled ? 0.0 : (_hover ? 1.0 : 0.6);
        return BoxDecoration(
          borderRadius: radius,
          gradient: _disabled
              ? null
              : LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    accent,
                    Color.lerp(accent, c.accentSecondary, 0.5) ?? accent,
                  ],
                ),
          color: _disabled ? c.surfaceAlt : null,
          boxShadow: _disabled
              ? null
              : DsElevation.accentGlow(accent, strength: glowStrength),
        );
      case DsButtonVariant.secondary:
        return BoxDecoration(
          borderRadius: radius,
          color: _hover ? c.surfaceAlt : c.surface,
          border: Border.all(
            color: _focused
                ? accent
                : (_hover ? c.borderHover : c.border),
            width: _focused ? DsStroke.normal : DsStroke.hairline,
          ),
          boxShadow: _focused
              ? DsElevation.accentGlow(accent, strength: 0.4)
              : DsElevation.flat,
        );
      case DsButtonVariant.ghost:
        return BoxDecoration(
          borderRadius: radius,
          color: _hover
              ? c.surface.withValues(alpha: 0.6)
              : Colors.transparent,
          border: Border.all(
            color: _focused ? accent : Colors.transparent,
            width: _focused ? DsStroke.normal : DsStroke.hairline,
          ),
        );
      case DsButtonVariant.tertiary:
        return BoxDecoration(
          borderRadius: radius,
          color: Colors.transparent,
        );
      case DsButtonVariant.danger:
        return BoxDecoration(
          borderRadius: radius,
          color: _hover
              ? c.red.withValues(alpha: 0.14)
              : c.red.withValues(alpha: 0.08),
          border: Border.all(
            color: c.red.withValues(alpha: _hover ? 0.55 : 0.35),
          ),
        );
    }
  }

  Color _foregroundColor(AppColors c) {
    if (_disabled && widget.variant != DsButtonVariant.primary) {
      return c.textDim;
    }
    if (_disabled && widget.variant == DsButtonVariant.primary) {
      return c.textMuted;
    }
    switch (widget.variant) {
      case DsButtonVariant.primary:
        return c.onAccent;
      case DsButtonVariant.secondary:
        return c.textBright;
      case DsButtonVariant.ghost:
        return c.text;
      case DsButtonVariant.tertiary:
        return _hover ? c.accentPrimary : c.text;
      case DsButtonVariant.danger:
        return c.red;
    }
  }
}
