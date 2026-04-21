import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/ds.dart';
import '../../theme/app_theme.dart';

/// Premium single-line input — static label above the field (not
/// floating over the border, which ages badly), inner surface with
/// 1px ring, accent glow on focus, error + helper affordances.
class DsInput extends StatefulWidget {
  final TextEditingController controller;
  final String? label;
  final String? placeholder;
  final String? helper;
  final String? errorText;
  final IconData? leadingIcon;
  final Widget? trailing;
  final bool obscureText;
  final bool autofocus;
  final FocusNode? focusNode;
  final TextInputAction? textInputAction;
  final TextInputType? keyboardType;
  final Iterable<String>? autofillHints;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final List<TextInputFormatter>? inputFormatters;
  final int? maxLength;
  final bool enabled;

  const DsInput({
    super.key,
    required this.controller,
    this.label,
    this.placeholder,
    this.helper,
    this.errorText,
    this.leadingIcon,
    this.trailing,
    this.obscureText = false,
    this.autofocus = false,
    this.focusNode,
    this.textInputAction,
    this.keyboardType,
    this.autofillHints,
    this.validator,
    this.onChanged,
    this.onSubmitted,
    this.inputFormatters,
    this.maxLength,
    this.enabled = true,
  });

  @override
  State<DsInput> createState() => _DsInputState();
}

class _DsInputState extends State<DsInput> {
  late final FocusNode _focus;
  bool _ownsFocus = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode != null) {
      _focus = widget.focusNode!;
    } else {
      _focus = FocusNode();
      _ownsFocus = true;
    }
    _focus.addListener(_onFocus);
  }

  void _onFocus() {
    if (!mounted) return;
    setState(() => _focused = _focus.hasFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    if (_ownsFocus) _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hasError = widget.errorText != null && widget.errorText!.isNotEmpty;
    final borderColor = hasError
        ? c.red
        : _focused
            ? c.accentPrimary
            : c.inputBorder;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.label != null) ...[
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 6),
            child: Text(
              widget.label!,
              style: DsType.caption(color: c.textMuted),
            ),
          ),
        ],
        AnimatedContainer(
          duration: DsDuration.fast,
          curve: DsCurve.decelSnap,
          decoration: BoxDecoration(
            color: widget.enabled ? c.inputBg : c.surfaceAlt,
            borderRadius: BorderRadius.circular(DsRadius.input),
            border: Border.all(
              color: borderColor,
              width: _focused || hasError
                  ? DsStroke.normal
                  : DsStroke.hairline,
            ),
            boxShadow: _focused && !hasError
                ? DsElevation.accentGlow(c.accentPrimary, strength: 0.4)
                : hasError
                    ? [
                        BoxShadow(
                          color: c.red.withValues(alpha: 0.18),
                          blurRadius: 12,
                          spreadRadius: -4,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : DsElevation.flat,
          ),
          child: Row(
            children: [
              if (widget.leadingIcon != null)
                Padding(
                  padding: const EdgeInsets.only(left: 12, right: 4),
                  child: Icon(
                    widget.leadingIcon,
                    size: 16,
                    color: _focused ? c.textBright : c.textMuted,
                  ),
                ),
              Expanded(
                child: TextFormField(
                  controller: widget.controller,
                  focusNode: _focus,
                  autofocus: widget.autofocus,
                  obscureText: widget.obscureText,
                  enabled: widget.enabled,
                  validator: widget.validator,
                  onChanged: widget.onChanged,
                  onFieldSubmitted: widget.onSubmitted,
                  keyboardType: widget.keyboardType,
                  textInputAction: widget.textInputAction,
                  autofillHints: widget.autofillHints,
                  inputFormatters: widget.inputFormatters,
                  maxLength: widget.maxLength,
                  cursorColor: c.accentPrimary,
                  cursorWidth: 1.4,
                  cursorRadius: const Radius.circular(1.4),
                  style: DsType.body(color: c.textBright),
                  decoration: InputDecoration(
                    hintText: widget.placeholder,
                    hintStyle: DsType.body(color: c.textDim),
                    isDense: true,
                    filled: false,
                    counterText: '',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    errorStyle: const TextStyle(height: 0, fontSize: 0),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: widget.leadingIcon == null ? 14 : 6,
                      vertical: 14,
                    ),
                  ),
                ),
              ),
              if (widget.trailing != null)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: widget.trailing!,
                ),
            ],
          ),
        ),
        AnimatedSize(
          duration: DsDuration.fast,
          curve: DsCurve.decelSnap,
          alignment: Alignment.topLeft,
          child: hasError
              ? Padding(
                  padding: const EdgeInsets.only(left: 2, top: 6),
                  child: Text(
                    widget.errorText!,
                    style: DsType.micro(color: c.red),
                  ),
                )
              : widget.helper != null
                  ? Padding(
                      padding: const EdgeInsets.only(left: 2, top: 6),
                      child: Text(
                        widget.helper!,
                        style: DsType.micro(color: c.textMuted),
                      ),
                    )
                  : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// Small icon-button used inside DsInput's trailing slot (eye
/// toggle, clear button). Keeps the input rowed and aligned.
class DsInputAction extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  const DsInputAction({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  @override
  State<DsInputAction> createState() => _DsInputActionState();
}

class _DsInputActionState extends State<DsInputAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final button = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hover ? c.surfaceAlt : Colors.transparent,
            borderRadius: BorderRadius.circular(DsRadius.xs),
          ),
          child: Icon(
            widget.icon,
            size: 15,
            color: _hover ? c.textBright : c.textMuted,
          ),
        ),
      ),
    );
    if (widget.tooltip != null) {
      return Tooltip(message: widget.tooltip!, child: button);
    }
    return button;
  }
}
