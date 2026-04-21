/// First-run guided walkthrough shown the very first time a user
/// opens a per-app credentials form. Instead of dropping them on a
/// bare form with a missing-required banner, we open a modal that:
///
///   1. Welcomes them with the app name + reason they need secrets
///   2. Lists every required provider with its logo + docs link
///   3. Offers a single "Let's set it up" CTA that dismisses the
///      modal and scrolls the form to the first empty provider
///
/// The "seen" flag is persisted in SharedPreferences under
/// `onboarding.credentials.<appId>` so the modal only fires once per
/// user per app. The check is cheap (one async read).
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/credential_schema.dart';
import '../../theme/app_theme.dart';

const _prefsPrefix = 'onboarding.credentials.';

/// Returns true if the user has already been onboarded for [appId].
/// A fresh install → false, after the first successful dismissal of
/// the modal → true.
Future<bool> hasOnboarded(String appId) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('$_prefsPrefix$appId') ?? false;
}

Future<void> markOnboarded(String appId) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('$_prefsPrefix$appId', true);
}

/// Show the onboarding modal. Only call this when
/// `hasOnboarded(appId) == false` AND the schema has at least one
/// required provider. Awaits until the user dismisses.
Future<void> showCredentialOnboarding(
  BuildContext context, {
  required String appId,
  required String appName,
  required CredentialSchema schema,
}) async {
  final required = schema.providers
      .where((p) => p.required && p.isEditableByEndUser)
      .toList();
  if (required.isEmpty) {
    await markOnboarded(appId);
    return;
  }
  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _OnboardingDialog(
      appName: appName.isNotEmpty ? appName : appId,
      providers: required,
    ),
  );
  await markOnboarded(appId);
}

class _OnboardingDialog extends StatelessWidget {
  final String appName;
  final List<CredentialProvider> providers;
  const _OnboardingDialog({
    required this.appName,
    required this.providers,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AlertDialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: c.border),
      ),
      contentPadding: EdgeInsets.zero,
      insetPadding:
          const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Hero banner
              Container(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 18),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      c.blue.withValues(alpha: 0.1),
                      c.blue.withValues(alpha: 0.02),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: c.blue.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: c.blue.withValues(alpha: 0.35)),
                      ),
                      child: Icon(Icons.key_rounded,
                          size: 22, color: c.blue),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Welcome to $appName',
                      style: GoogleFonts.inter(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: c.textBright,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Before this app can run, it needs a few secrets from you. '
                      'These stay on your daemon, encrypted, and only your sessions can use them.',
                      style: GoogleFonts.inter(
                          fontSize: 12.5,
                          color: c.text,
                          height: 1.5),
                    ),
                  ],
                ),
              ),
              // Providers list
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 6),
                child: Text(
                  'YOU\'LL NEED',
                  style: GoogleFonts.firaCode(
                    fontSize: 10,
                    color: c.textMuted,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                child: Column(
                  children: [
                    for (final p in providers)
                      _ProviderRow(provider: p),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              // Footer
              Container(
                padding: const EdgeInsets.fromLTRB(24, 10, 24, 18),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: c.border)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${providers.length} ${providers.length == 1 ? "secret" : "secrets"} to configure',
                        style: GoogleFonts.inter(
                            fontSize: 11, color: c.textMuted),
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text('Skip for now',
                          style: GoogleFonts.inter(
                              fontSize: 12, color: c.textMuted)),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_forward_rounded,
                          size: 14, color: Colors.white),
                      label: Text('Let\'s set it up',
                          style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.white)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: c.blue,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProviderRow extends StatelessWidget {
  final CredentialProvider provider;
  const _ProviderRow({required this.provider});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (icon, typeLabel) = _iconAndType(provider);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.surfaceAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.border),
            ),
            child: Icon(icon, size: 15, color: c.text),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(provider.label,
                    style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.textBright)),
                Text(
                  provider.description.isNotEmpty
                      ? provider.description
                      : typeLabel,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                      fontSize: 11,
                      color: c.textMuted,
                      height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  (IconData, String) _iconAndType(CredentialProvider p) {
    if (p.isOAuth) return (Icons.link_rounded, 'OAuth consent flow');
    if (p.isMcp) {
      return (Icons.electrical_services_rounded, 'MCP server');
    }
    if (p.isConnectionString) {
      return (Icons.storage_rounded, 'Connection URL');
    }
    if (p.isMultiField) return (Icons.key_rounded, 'Multi-field secret');
    return (Icons.key_rounded, 'API key');
  }
}
