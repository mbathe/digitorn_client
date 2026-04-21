import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../services/onboarding_service.dart';
import 'steps/credentials_step.dart';
import 'steps/keyboard_tour_step.dart';
import 'steps/profile_step.dart';
import 'steps/ready_step.dart';
import 'steps/starter_apps_step.dart';
import 'wizard_shell.dart';

/// Wizard B — post-register account setup. Profile → Credentials →
/// Starter apps → Keyboard tour → Ready. Persists `account_done`
/// via OnboardingService and writes the display name back into
/// AuthService on completion.
class AccountWizardPage extends StatefulWidget {
  final VoidCallback onComplete;
  const AccountWizardPage({super.key, required this.onComplete});

  @override
  State<AccountWizardPage> createState() => _AccountWizardPageState();
}

class _AccountWizardPageState extends State<AccountWizardPage> {
  int _index = 0;
  bool _canAdvance = true;

  final _steps = const <Widget>[
    ProfileStep(),
    CredentialsStep(),
    StarterAppsStep(),
    KeyboardTourStep(),
    ReadyStep(),
  ];

  Future<void> _finish() async {
    final ob = OnboardingService();
    final name = ob.displayName;
    if (name != null && name.isNotEmpty) {
      // Fire-and-forget — daemon may be offline, user can retry
      // via Settings → Profile later.
      unawaited(AuthService().updateProfile(displayName: name));
    }
    await ob.markAccountDone();
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

  @override
  Widget build(BuildContext context) {
    return WizardShell(
      currentIndex: _index,
      totalSteps: _steps.length,
      onNext: _next,
      onBack: _index > 0 ? _back : null,
      onSkipStep: _next,
      onSkipAll: _finish,
      canAdvance: _canAdvance,
      setCanAdvance: (v) {
        if (v != _canAdvance) setState(() => _canAdvance = v);
      },
      child: KeyedSubtree(
        key: ValueKey('account-$_index'),
        child: _steps[_index],
      ),
    );
  }
}

