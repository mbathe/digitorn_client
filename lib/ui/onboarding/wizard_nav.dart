import 'package:flutter/widgets.dart';

/// InheritedWidget used by wizard steps to access the orchestrator's
/// navigation callbacks without prop-drilling through every level.
/// Read via `WizardNav.of(context)`.
class WizardNav extends InheritedWidget {
  final int currentIndex;
  final int totalSteps;
  final VoidCallback onNext;
  final VoidCallback? onBack;
  final VoidCallback? onSkipStep;
  final VoidCallback? onSkipAll;
  final void Function(bool canAdvance) setCanAdvance;

  const WizardNav({
    super.key,
    required this.currentIndex,
    required this.totalSteps,
    required this.onNext,
    required this.onBack,
    required this.onSkipStep,
    required this.onSkipAll,
    required this.setCanAdvance,
    required super.child,
  });

  bool get isFirst => currentIndex == 0;
  bool get isLast => currentIndex == totalSteps - 1;

  static WizardNav of(BuildContext context) {
    final nav = context.dependOnInheritedWidgetOfExactType<WizardNav>();
    assert(nav != null, 'WizardNav not found in tree — wrap step in WizardShell');
    return nav!;
  }

  @override
  bool updateShouldNotify(covariant WizardNav old) =>
      currentIndex != old.currentIndex ||
      totalSteps != old.totalSteps;
}
