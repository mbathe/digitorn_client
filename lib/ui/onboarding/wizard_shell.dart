import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/ds.dart';
import '../../theme/app_theme.dart';
import '../ds/ds.dart';
import 'wizard_nav.dart';

/// Shared chrome for both onboarding wizards. Renders the signature
/// aurora background, a compact top bar (brand + progress + skip),
/// the current step body with a spring slide transition, and a
/// keyboard-hint footer. Arrow keys / Esc are wired.
class WizardShell extends StatelessWidget {
  final int currentIndex;
  final int totalSteps;
  final VoidCallback onNext;
  final VoidCallback? onBack;
  final VoidCallback? onSkipStep;
  final VoidCallback? onSkipAll;
  final Widget child;
  final bool canAdvance;
  final void Function(bool) setCanAdvance;

  const WizardShell({
    super.key,
    required this.currentIndex,
    required this.totalSteps,
    required this.onNext,
    required this.onBack,
    required this.onSkipStep,
    required this.onSkipAll,
    required this.child,
    required this.canAdvance,
    required this.setCanAdvance,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final compact = DsBreakpoint.isCompact(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: Focus(
        autofocus: true,
        onKeyEvent: (_, e) {
          if (e is! KeyDownEvent) return KeyEventResult.ignored;
          if (e.logicalKey == LogicalKeyboardKey.escape &&
              onSkipAll != null) {
            onSkipAll!();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: DsAuroraBackground(
          child: SafeArea(
            child: Column(
              children: [
                _TopBar(
                  currentIndex: currentIndex,
                  totalSteps: totalSteps,
                  onBack: onBack,
                  onSkipAll: onSkipAll,
                  compact: compact,
                ),
                Expanded(
                  child: WizardNav(
                    currentIndex: currentIndex,
                    totalSteps: totalSteps,
                    onNext: onNext,
                    onBack: onBack,
                    onSkipStep: onSkipStep,
                    onSkipAll: onSkipAll,
                    setCanAdvance: setCanAdvance,
                    child: _AnimatedStepArea(
                      key: ValueKey(currentIndex),
                      child: child,
                    ),
                  ),
                ),
                _FooterHint(compact: compact),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final int currentIndex;
  final int totalSteps;
  final VoidCallback? onBack;
  final VoidCallback? onSkipAll;
  final bool compact;

  const _TopBar({
    required this.currentIndex,
    required this.totalSteps,
    required this.onBack,
    required this.onSkipAll,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? DsSpacing.x5 : DsSpacing.x8,
        DsSpacing.x5,
        compact ? DsSpacing.x5 : DsSpacing.x8,
        DsSpacing.x3,
      ),
      child: Row(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const DsBrandMark(size: 28, glow: false),
              SizedBox(width: DsSpacing.x3),
              if (!compact)
                Text(
                  'Digitorn',
                  style: DsType.h3(color: c.textBright),
                ),
            ],
          ),
          Expanded(
            child: Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: DsSpacing.x4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DsProgressBars(
                      total: totalSteps,
                      current: currentIndex,
                      barWidth: compact ? 14 : 22,
                    ),
                    if (!compact) ...[
                      SizedBox(height: DsSpacing.x3),
                      DsStepCounter(
                        current: currentIndex,
                        total: totalSteps,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onBack != null)
                DsButton(
                  label: compact ? '' : 'onboarding.back'.tr(),
                  leadingIcon: Icons.arrow_back,
                  variant: DsButtonVariant.ghost,
                  size: DsButtonSize.sm,
                  onPressed: onBack,
                ),
              if (onBack != null && onSkipAll != null)
                SizedBox(width: DsSpacing.x2),
              if (onSkipAll != null)
                DsButton(
                  label: compact
                      ? 'onboarding.skip'.tr()
                      : 'onboarding.skip_setup'.tr(),
                  variant: DsButtonVariant.tertiary,
                  size: DsButtonSize.sm,
                  onPressed: onSkipAll,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AnimatedStepArea extends StatefulWidget {
  final Widget child;
  const _AnimatedStepArea({super.key, required this.child});

  @override
  State<_AnimatedStepArea> createState() => _AnimatedStepAreaState();
}

class _AnimatedStepAreaState extends State<_AnimatedStepArea>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: DsDuration.slow)
      ..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) {
        final t = DsCurve.decelSoft.transform(_c.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 16),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

class _FooterHint extends StatelessWidget {
  final bool compact;
  const _FooterHint({required this.compact});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (compact) {
      return Padding(
        padding: EdgeInsets.only(bottom: DsSpacing.x5),
        child: Text(
          'onboarding.tap_continue'.tr(),
          style: DsType.micro(color: c.textDim),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(
        DsSpacing.x8,
        DsSpacing.x4,
        DsSpacing.x8,
        DsSpacing.x5,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _HintChip(label: 'onboarding.hint_continue'.tr(), keys: const ['Enter']),
          SizedBox(width: DsSpacing.x5),
          _HintChip(label: 'onboarding.hint_back'.tr(), keys: const ['Shift', 'Enter']),
          SizedBox(width: DsSpacing.x5),
          _HintChip(label: 'onboarding.hint_skip'.tr(), keys: const ['Esc']),
        ],
      ),
    );
  }
}

class _HintChip extends StatelessWidget {
  final String label;
  final List<String> keys;
  const _HintChip({required this.label, required this.keys});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DsKbdCombo(keys: keys),
        SizedBox(width: DsSpacing.x3),
        Text(label, style: DsType.micro(color: c.textMuted)),
      ],
    );
  }
}
