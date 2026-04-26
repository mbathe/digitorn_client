/// Drives the `/api/hub/install` flow with the 409 consent dance:
///
///   1. POST with `acceptPermissions: false`.
///   2. If the daemon returns `HubInstallNeedsConsent`, show
///      `<HubConsentDialog>` with the permissions breakdown.
///   3. On confirm, re-POST with `acceptPermissions: true`.
///   4. Toast the result.
///
/// Returns true on success, false on any cancel / error / 4xx.
///
/// Mirror of the web `useHubInstall` hook
/// (`digitorn_web/src/components/hub/hub-install-flow.tsx`).
library;

import 'package:flutter/material.dart';

import '../models/hub/hub_models.dart';
import '../ui/hub/widgets/hub_consent_dialog.dart';
import 'hub_service.dart';
import 'hub_session_service.dart';

class HubInstallController {
  HubInstallController._();
  static final HubInstallController instance = HubInstallController._();

  /// Public entry point.
  ///
  /// [packageName] is what we surface in toasts / dialogs (the human
  /// name, not the slug). The consent dialog is built on top of
  /// [context] so callers don't need their own dialog plumbing.
  Future<bool> install({
    required BuildContext context,
    required String publisher,
    required String packageId,
    required String packageName,
    String? version,
    HubInstallScope scope = HubInstallScope.user,
    VoidCallback? onSuccess,
  }) async {
    return _attempt(
      context: context,
      publisher: publisher,
      packageId: packageId,
      packageName: packageName,
      version: version,
      scope: scope,
      onSuccess: onSuccess,
      acceptPermissions: false,
    );
  }

  Future<bool> _attempt({
    required BuildContext context,
    required String publisher,
    required String packageId,
    required String packageName,
    required String? version,
    required HubInstallScope scope,
    required bool acceptPermissions,
    VoidCallback? onSuccess,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final r = await HubService().install(
        publisher: publisher,
        packageId: packageId,
        version: version,
        scope: scope,
        acceptPermissions: acceptPermissions,
      );
      if (r is HubInstallOk) {
        _toast(messenger, '$packageName installed.');
        onSuccess?.call();
        return true;
      }
      if (r is HubInstallNeedsConsent) {
        if (!context.mounted) return false;
        final ok = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => HubConsentDialog(
            packageName: packageName,
            permissions: r.permissions,
          ),
        );
        if (ok != true) return false;
        if (!context.mounted) return false;
        return _attempt(
          context: context,
          publisher: publisher,
          packageId: packageId,
          packageName: packageName,
          version: version,
          scope: scope,
          acceptPermissions: true,
          onSuccess: onSuccess,
        );
      }
      // Network / 5xx — `null` from the service.
      _toast(messenger, 'Install failed — try again later.');
      return false;
    } on HubServiceError catch (e) {
      _toast(messenger, _formatError(e));
      if (e.status == 401) {
        // Token may have expired since the session cache was last
        // refreshed — re-pull `/api/hub/me` so the UI prompts the
        // user to sign back in.
        HubSessionService().refresh();
      }
      return false;
    } catch (e) {
      _toast(messenger, e.toString());
      return false;
    }
  }

  void _toast(ScaffoldMessengerState? messenger, String message) {
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  String _formatError(HubServiceError e) {
    final signedIn = HubSessionService().isLoggedIn;
    switch (e.status) {
      case 401:
        return signedIn
            ? 'Your Hub session expired — please sign in again.'
            : 'Sign in to the Hub before installing.';
      case 402:
        return 'Insufficient Hub credit to install this package.';
      case 403:
        return "You don't have permission to install this package.";
      case 404:
        return 'Package not found in the Hub.';
      case 409:
        return 'Already installed at this version.';
      case 429:
        return 'Too many install requests — try again shortly.';
      default:
        return e.message;
    }
  }
}
