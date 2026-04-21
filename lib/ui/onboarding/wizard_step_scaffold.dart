import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/ds.dart';
import '../../theme/app_theme.dart';
import '../ds/ds.dart';
import 'wizard_nav.dart';

/// Per-step scaffolding — centered narrow column with the same
/// rhythm everywhere: eyebrow, title (display serif), subtitle,
/// content slot, footer (primary CTA + optional skip).
///
/// Wraps the content in a Form and auto-submits on Enter. Pass
/// `canAdvance = false` to visually disable the primary CTA while
/// still allowing navigation via the shell's Back affordance.
class WizardStepScaffold extends StatefulWidget {
  final String? eyebrow;
  final String title;
  final String? subtitle;
  final Widget content;
  final String nextLabel;
  final IconData? nextIcon;
  final bool canAdvance;
  final bool showSkip;
  final String skipLabel;
  final double maxWidth;
  final Widget? illustration;
  final bool hideFooter;

  const WizardStepScaffold({
    super.key,
    this.eyebrow,
    required this.title,
    this.subtitle,
    required this.content,
    this.nextLabel = 'Continue',
    this.nextIcon = Icons.arrow_forward,
    this.canAdvance = true,
    this.showSkip = false,
    this.skipLabel = 'Skip',
    this.maxWidth = 560,
    this.illustration,
    this.hideFooter = false,
  });

  @override
  State<WizardStepScaffold> createState() => _WizardStepScaffoldState();
}

class _WizardStepScaffoldState extends State<WizardStepScaffold> {
  final _advanceIntent = _AdvanceIntent();
  final _backIntent = _BackIntent();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final compact = DsBreakpoint.isCompact(context);
    final nav = WizardNav.of(context);

    final body = Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.enter): _advanceIntent,
        LogicalKeySet(LogicalKeyboardKey.shift, LogicalKeyboardKey.enter):
            _backIntent,
      },
      child: Actions(
        actions: {
          _AdvanceIntent: CallbackAction<_AdvanceIntent>(onInvoke: (_) {
            if (widget.canAdvance) nav.onNext();
            return null;
          }),
          _BackIntent: CallbackAction<_BackIntent>(onInvoke: (_) {
            nav.onBack?.call();
            return null;
          }),
        },
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? DsSpacing.x5 : DsSpacing.x8,
              vertical: DsSpacing.x6,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: widget.maxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.illustration != null) ...[
                    widget.illustration!,
                    SizedBox(height: DsSpacing.x7),
                  ],
                  if (widget.eyebrow != null) ...[
                    Text(
                      widget.eyebrow!,
                      style: DsType.eyebrow(color: c.accentPrimary),
                    ),
                    SizedBox(height: DsSpacing.x4),
                  ],
                  Text(
                    widget.title,
                    style: DsType.display(
                      size: compact ? 36 : 48,
                      color: c.textBright,
                    ),
                  ),
                  if (widget.subtitle != null) ...[
                    SizedBox(height: DsSpacing.x4),
                    Text(
                      widget.subtitle!,
                      style: DsType.body(color: c.textMuted)
                          .copyWith(fontSize: 15, height: 1.55),
                    ),
                  ],
                  SizedBox(height: DsSpacing.x8),
                  widget.content,
                  if (!widget.hideFooter) ...[
                    SizedBox(height: DsSpacing.x8),
                    _Footer(
                      nextLabel: widget.nextLabel,
                      nextIcon: widget.nextIcon,
                      canAdvance: widget.canAdvance,
                      showSkip: widget.showSkip,
                      skipLabel: widget.skipLabel,
                      onNext: nav.onNext,
                      onSkip: nav.onSkipStep,
                      compact: compact,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return body;
  }
}

class _Footer extends StatelessWidget {
  final String nextLabel;
  final IconData? nextIcon;
  final bool canAdvance;
  final bool showSkip;
  final String skipLabel;
  final VoidCallback onNext;
  final VoidCallback? onSkip;
  final bool compact;

  const _Footer({
    required this.nextLabel,
    required this.nextIcon,
    required this.canAdvance,
    required this.showSkip,
    required this.skipLabel,
    required this.onNext,
    required this.onSkip,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final primary = DsButton(
      label: nextLabel,
      trailingIcon: nextIcon,
      onPressed: canAdvance ? onNext : null,
      size: DsButtonSize.lg,
      expand: compact,
    );
    if (!showSkip) {
      return Align(
        alignment: compact ? Alignment.center : Alignment.centerLeft,
        child: primary,
      );
    }
    return Row(
      mainAxisAlignment: compact
          ? MainAxisAlignment.spaceBetween
          : MainAxisAlignment.start,
      children: [
        primary,
        SizedBox(width: DsSpacing.x5),
        DsButton(
          label: skipLabel,
          variant: DsButtonVariant.tertiary,
          size: DsButtonSize.lg,
          onPressed: onSkip,
        ),
      ],
    );
  }
}

class _AdvanceIntent extends Intent {}
class _BackIntent extends Intent {}
