import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';

/// Tracks whether the user has been through the first-launch setup
/// (Wizard A — machine) and the post-register account setup
/// (Wizard B — account). Both are persisted separately so existing
/// installs are not forced through setup after an app update.
///
/// Also stores the scratchpad of values collected during each wizard
/// (role, avatar, selected providers, starter apps). The scratchpad
/// is in-memory only — wizard steps commit their results to the
/// relevant service (AuthService, ThemeService, AppsService…) on
/// transition, so the scratchpad can be safely wiped on completion.
class OnboardingService extends ChangeNotifier {
  static final OnboardingService _i = OnboardingService._();
  factory OnboardingService() => _i;
  OnboardingService._();

  static const _kSetupDone = 'onboarding.setup_done.v1';
  static const _kAccountDone = 'onboarding.account_done.v1';

  bool _setupDone = false;
  bool _accountSetupDone = false;
  bool get setupDone => _setupDone;
  bool get accountSetupDone => _accountSetupDone;

  String role = 'other';
  String? displayName;
  String? avatarInitialsSeed;
  final Set<String> connectedProviders = {};
  final Set<String> installedApps = {};
  final Set<String> triedShortcuts = {};

  /// Where the Ready step wants the user to land on first app open.
  /// One of: `builder`, `hub`, `workspace`. Consumed once by the
  /// main shell when account setup finishes, then cleared.
  String? preferredInitialTarget;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _setupDone = prefs.getBool(_kSetupDone) ?? false;
    _accountSetupDone = prefs.getBool(_kAccountDone) ?? false;
    // Migration: anyone who reached this build with a live auth
    // token was onboarded before the wizard existed. Auto-mark both
    // flags so we don't force them back through the first-run flow.
    // Relies on AuthService().loadFromStorage() running first (see
    // main()).
    if (AuthService().accessToken != null) {
      if (!_setupDone) {
        _setupDone = true;
        await prefs.setBool(_kSetupDone, true);
      }
      if (!_accountSetupDone) {
        _accountSetupDone = true;
        await prefs.setBool(_kAccountDone, true);
      }
    }
  }

  Future<void> markSetupDone() async {
    if (_setupDone) return;
    _setupDone = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSetupDone, true);
    notifyListeners();
  }

  Future<void> markAccountDone() async {
    if (_accountSetupDone) return;
    _accountSetupDone = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAccountDone, true);
    notifyListeners();
  }

  /// Clear only the per-account scratchpad + flag — machine setup
  /// stays done. Called on a successful register so Wizard B fires
  /// for the new user even if a previous user on the same device
  /// had already completed it.
  Future<void> resetAccount() async {
    _accountSetupDone = false;
    role = 'other';
    displayName = null;
    avatarInitialsSeed = null;
    connectedProviders.clear();
    installedApps.clear();
    triedShortcuts.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kAccountDone);
    notifyListeners();
  }

  /// Wipe persistent flags (used by a dev-only "replay onboarding"
  /// action in Settings). Doesn't touch AuthService tokens.
  Future<void> reset() async {
    _setupDone = false;
    _accountSetupDone = false;
    role = 'other';
    displayName = null;
    avatarInitialsSeed = null;
    connectedProviders.clear();
    installedApps.clear();
    triedShortcuts.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSetupDone);
    await prefs.remove(_kAccountDone);
    notifyListeners();
  }
}
