/// Pulls the authenticated user's ``attributes`` bag from the daemon
/// (``GET /api/users/me/profile``) and applies it to the local client
/// stores — theme, palette, language, density, onboarding scratchpad.
///
/// Lives here (NOT inside AuthService) to avoid a circular import —
/// ThemeService / PreferencesService / OnboardingService all pull
/// ``baseUrl`` from AuthService, so if AuthService imported them we'd
/// have a cycle.
///
/// Call sites:
///   * After a successful login (``AuthService`` listener fires with
///     a non-null access token).
///   * On app cold-start when the user is already authenticated.
///
/// Failure modes are swallowed — an offline daemon must not leave
/// the UI in an inconsistent state. Local SharedPreferences is the
/// fallback; the daemon push happens again next time a wizard step
/// or a Settings pane writes.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart' show AppPalette;
import 'auth_service.dart';
import 'onboarding_service.dart';
import 'preferences_service.dart';
import 'theme_service.dart';

/// Re-entrant guard — a burst of auth-change notifications (which
/// happens on refresh-token refresh, every 30-45 min) must collapse
/// into a single HTTP call.
bool _inFlight = false;

/// Pull the profile's ``attributes`` and apply. Returns ``true`` when
/// ANYTHING was applied so callers can decide whether to notify
/// listeners if they wrap state of their own.
Future<bool> hydrateUserPrefsFromDaemon() async {
  if (_inFlight) return false;
  _inFlight = true;
  try {
    final attrs = await AuthService().fetchProfileAttributes();
    if (attrs == null || attrs.isEmpty) return false;

    var applied = false;

    // ── UI preferences ────────────────────────────────────────────
    final ui = (attrs['ui'] as Map?)?.cast<String, dynamic>() ?? const {};
    if (ui.isNotEmpty) {
      final themeMode = ui['theme_mode'] as String?;
      if (themeMode != null) {
        final m = _parseThemeMode(themeMode);
        if (m != null) {
          ThemeService().setMode(m);
          applied = true;
        }
      }
      final palette = ui['theme_palette'] as String?;
      if (palette != null) {
        final p = _parsePalette(palette);
        if (p != null) {
          ThemeService().setPalette(p);
          applied = true;
        }
      }
      final lang = ui['language'] as String?;
      if (lang != null && lang.isNotEmpty) {
        unawaited(PreferencesService().setLanguage(lang));
        applied = true;
      }
      final density = ui['density'] as String?;
      if (density != null && density.isNotEmpty) {
        unawaited(PreferencesService().setDensity(density));
        applied = true;
      }
    }

    // ── Onboarding scratchpad ────────────────────────────────────
    // Seed the scratchpad so re-entering the wizard via Settings
    // starts pre-filled with the server's current state instead of
    // an empty form. Not required for initial onboarding (it would
    // overwrite user choices) — so we only seed on app start when
    // the user has already been through the wizard (accountSetupDone).
    final ob = OnboardingService();
    if (ob.accountSetupDone) {
      final role = attrs['role'] as String?;
      if (role != null && role.isNotEmpty) {
        ob.role = role;
        applied = true;
      }
      final seed = attrs['avatar_seed'] as String?;
      if (seed != null && seed.isNotEmpty) {
        ob.avatarInitialsSeed = seed;
        applied = true;
      }
      final providers = attrs['preferred_providers'] as List?;
      if (providers != null) {
        ob.connectedProviders
          ..clear()
          ..addAll(providers.whereType<String>());
        applied = true;
      }
      final apps = attrs['starter_apps'] as List?;
      if (apps != null) {
        ob.installedApps
          ..clear()
          ..addAll(apps.whereType<String>());
        applied = true;
      }
    }

    return applied;
  } catch (e) {
    debugPrint('hydrateUserPrefsFromDaemon: $e');
    return false;
  } finally {
    _inFlight = false;
  }
}

ThemeMode? _parseThemeMode(String raw) {
  switch (raw) {
    case 'system':
      return ThemeMode.system;
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return null;
  }
}

AppPalette? _parsePalette(String raw) {
  for (final v in AppPalette.values) {
    if (v.name == raw) return v;
  }
  return null;
}
