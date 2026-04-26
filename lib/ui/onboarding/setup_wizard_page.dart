import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../services/onboarding_service.dart';
import '../../services/preferences_service.dart';
import '../../services/theme_service.dart';
import 'steps/accessibility_step.dart';
import 'steps/daemon_step.dart';
import 'steps/theme_step.dart';
import 'steps/welcome_step.dart';
import 'wizard_shell.dart';

/// Wizard A — first-launch machine setup. Welcome → Daemon → Theme
/// → Accessibility. Persists the `setup_done` flag on completion via
/// OnboardingService.
class SetupWizardPage extends StatefulWidget {
  final VoidCallback onComplete;
  const SetupWizardPage({super.key, required this.onComplete});

  @override
  State<SetupWizardPage> createState() => _SetupWizardPageState();
}

class _SetupWizardPageState extends State<SetupWizardPage> {
  int _index = 0;
  bool _canAdvance = true;

  final _steps = const <Widget>[
    WelcomeStep(),
    DaemonStep(),
    ThemeStep(),
    AccessibilityStep(),
  ];

  Future<void> _finish() async {
    // Sync the UI prefs the user set during Setup (theme mode,
    // palette, language, density) to the daemon so they follow
    // the user across devices. They're already saved locally in
    // SharedPreferences at the moment the user ticked them — the
    // daemon push is additive. Fire-and-forget: offline daemon
    // must not block the wizard from closing.
    final theme = ThemeService();
    final prefs = PreferencesService();
    final uiAttrs = <String, dynamic>{
      'theme_mode': theme.mode.name,       // system | light | dark
      'theme_palette': theme.palette.name, // obsidian | default | …
      'language': prefs.language,          // en | fr | es | de
      'density': prefs.density,            // compact | comfortable | spacious
    };
    // Only push when the user is actually authenticated — first-run
    // setup can complete before login (daemon URL step happens
    // BEFORE account creation).
    if (AuthService().accessToken != null) {
      unawaited(AuthService().updateProfile(
        attributes: {'ui': uiAttrs},
      ));
    }

    await OnboardingService().markSetupDone();
    if (!mounted) return;
    widget.onComplete();
  }

  void _next() {
    if (_index + 1 >= _steps.length) {
      _finish();
      return;
    }
    setState(() {
      _index++;
      _canAdvance = false;
    });
  }

  void _back() {
    if (_index == 0) return;
    setState(() => _index--);
  }

  void _skipAll() => _finish();

  @override
  Widget build(BuildContext context) {
    return WizardShell(
      currentIndex: _index,
      totalSteps: _steps.length,
      onNext: _next,
      onBack: _index > 0 ? _back : null,
      onSkipStep: _next,
      onSkipAll: _skipAll,
      canAdvance: _canAdvance,
      setCanAdvance: (v) {
        if (v != _canAdvance) setState(() => _canAdvance = v);
      },
      child: KeyedSubtree(
        key: ValueKey('setup-$_index'),
        child: _steps[_index],
      ),
    );
  }
}
