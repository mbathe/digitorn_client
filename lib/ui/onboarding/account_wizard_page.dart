import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/app_catalog_service.dart';
import '../../services/auth_service.dart';
import '../../services/onboarding_service.dart';
import 'steps/profile_step.dart';
import 'steps/starter_apps_step.dart';
import 'wizard_shell.dart';

/// Post-register onboarding — 2 screens, ~30 seconds:
///   1. Profile      — displayName + avatar
///   2. Starter apps — Builder + Chat pre-checked, 4 optional
///
/// Everything else that used to live in wizards (daemon URL, theme,
/// accessibility, credentials providers, keyboard tour, ready target)
/// is now available from Settings, or configured implicitly at the
/// right moment (e.g. credentials asked by ``ensureCredentials``
/// when an app actually needs them). The goal: get the user into the
/// Hub with a usable state as fast as possible.
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
    StarterAppsStep(),
  ];

  Future<void> _finish() async {
    final ob = OnboardingService();

    // Assemble the profile payload. The wizard is now 2 screens, so
    // we only push what they produce:
    //   - display_name   (top-level on the profile route)
    //   - avatar_seed    (attributes, used by DsAvatar)
    //   - starter_apps   (attributes, kept as an audit log of what
    //                     was installed at onboarding — useful for
    //                     "re-install my starter set" later)
    //
    // Everything else (theme / language / density / preferred
    // providers) is written lazily from Settings or from the
    // individual step where it belongs — keeping the onboarding
    // surface tiny.
    final attrs = <String, dynamic>{
      if (ob.avatarInitialsSeed != null &&
          ob.avatarInitialsSeed!.isNotEmpty)
        'avatar_seed': ob.avatarInitialsSeed,
      if (ob.installedApps.isNotEmpty)
        'starter_apps': ob.installedApps.toList(),
    };

    final name = ob.displayName;
    if (name != null && name.isNotEmpty || attrs.isNotEmpty) {
      // Fire-and-forget — daemon may be offline, user can retry
      // via Settings → Profile later. We DELIBERATELY do not await
      // this: the user sees the main shell instantly after "Finish";
      // the network write catches up a beat later.
      unawaited(AuthService().updateProfile(
        displayName: (name != null && name.isNotEmpty) ? name : null,
        attributes: attrs.isEmpty ? null : attrs,
      ));
    }

    // Install the apps the user ticked in Starter Apps. Fire in
    // parallel — a slow one can't block the wizard from closing.
    // On failure we log and keep going; the user can install from
    // the store later. ``digitorn-builder`` is always in the set
    // (mandatory) but the daemon will treat a re-install as a no-op
    // if it's already deployed, so we don't special-case it.
    //
    // ``sourceType: 'builtin'`` + ``sourceUri: <app_id>`` tells the
    // daemon to resolve from its local bundle registry — the same
    // path the Hub "Install" button uses for 1st-party apps.
    if (ob.installedApps.isNotEmpty) {
      for (final appId in ob.installedApps) {
        unawaited(() async {
          try {
            await AppCatalogService().installApp(
              sourceType: 'builtin',
              sourceUri: appId,
              acceptPermissions: true,
            );
          } catch (e) {
            debugPrint('starter app install failed: $appId — $e');
          }
        }());
      }
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

