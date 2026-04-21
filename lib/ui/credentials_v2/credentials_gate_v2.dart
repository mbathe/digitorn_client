/// Pre-session credentials gate.
///
/// Before opening an app, we call `GET /api/apps/{id}/required-secrets`
/// and — for each secret the daemon flagged as missing — pop the
/// existing [CredentialPickerDialog] so the user can either reuse an
/// existing credential (via grant) or create a new one. Only once
/// every missing entry has been resolved does the caller proceed
/// with `createAndSetSession`.
///
/// The gate is resilient:
///   * 404 / 501 on `/required-secrets` → skip the gate (older daemons)
///   * Network error → skip, let the chat-layer fall back to SSE
///     `credential_auth_required` (Flow E)
///   * Secrets with no recognised `provider` are skipped — they're
///     custom keys the user must set via the admin console manually.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/credential_v2.dart';
import '../../services/credentials_v2_service.dart';
import '../../theme/app_theme.dart';
import 'credential_picker_dialog.dart';

class CredentialsGateV2 {
  /// Run the full gate for [appId]. Returns `true` when the app is
  /// ready to start (no missing secrets remain), `false` when the
  /// user cancelled or a missing secret could not be resolved.
  static Future<bool> ensureReady(
    BuildContext context, {
    required String appId,
  }) async {
    RequiredSecretsInfo info;
    try {
      info = await CredentialsV2Service().fetchRequiredSecrets(appId);
    } on CredV2Exception catch (e) {
      // 404 on app id → let the caller decide (show "not deployed"
      // in its flow). Everything else: swallow and proceed so we
      // don't block on a transient daemon hiccup.
      if (e.statusCode == 404) return true;
      return true;
    } catch (_) {
      return true;
    }

    if (info.missingCount == 0) return true;

    // Make sure we have the provider catalogue so the inline "create
    // new" form can render the right fields.
    await CredentialsV2Service().loadProviders();

    // Resolve missing secrets one at a time, in declaration order.
    for (final secret in info.missing) {
      if (!context.mounted) return false;
      final resolved = await _resolveOne(
        context,
        appId: appId,
        secret: secret,
      );
      if (!resolved) return false;
    }
    return true;
  }

  static Future<bool> _resolveOne(
    BuildContext context, {
    required String appId,
    required RequiredSecret secret,
  }) async {
    // `env`-typed references aren't user-fillable — they come from the
    // daemon process environment. Skip them silently and hope the
    // operator set them at launch time.
    if (secret.referenceType == 'env') return true;

    // Resolve the provider to use for this secret. Priority:
    //   1. `secret.provider` (the daemon already picked unambiguously)
    //   2. First entry of `secret.providers` (we pick one when there's
    //      only one candidate)
    //   3. Disambiguation dialog when multiple providers share the key
    //   4. Banner when nothing is known
    String? providerName = secret.provider;
    if (providerName == null || providerName.isEmpty) {
      if (secret.providers.length == 1) {
        providerName = secret.providers.first;
      } else if (secret.providers.length > 1) {
        if (!context.mounted) return false;
        providerName = await _pickProviderFromList(
          context,
          secret: secret,
        );
        if (providerName == null) return false;
      }
    }
    if (providerName == null || providerName.isEmpty) {
      if (!context.mounted) return false;
      return _showUnmappedSecretBanner(context, appId: appId, secret: secret);
    }

    // Lookup the provider catalogue entry so the picker can render
    // the create-new form with labels / placeholders.
    final catalogue = CredentialsV2Service().cachedProviders;
    final entry = catalogue.firstWhere(
      (p) => p.name.toLowerCase() == providerName!.toLowerCase(),
      orElse: () => ProviderCatalogueEntry(
        name: providerName!,
        label: providerName,
        type: 'api_key',
        fields: [
          ProviderFieldSpec(
            name: secret.key,
            type: 'secret',
            label: secret.key,
            required: true,
          ),
        ],
      ),
    );

    // Pull the user's existing credentials for this provider so the
    // picker can offer "reuse" radios.
    List<CredentialV2> candidates;
    try {
      candidates = await CredentialsV2Service().list(provider: providerName);
    } on CredV2Exception {
      candidates = const [];
    }
    // Filter by matching provider name only (the /credentials route
    // honours ?provider, but some daemon builds ignore it).
    candidates = candidates
        .where((c) =>
            c.providerName.toLowerCase() == providerName!.toLowerCase())
        .toList();

    if (!context.mounted) return false;
    final event = CredentialAuthRequiredEvent(
      provider: providerName,
      providerType: entry.type,
      appId: appId,
      userId: '',
      candidates: candidates,
      fieldSpec: entry.fields,
      // Thread the agent id through so the picker can show
      // "Builder asks for a DeepSeek key" instead of the generic
      // title when only one agent is involved.
      agentId: secret.agentId,
      detail: 'Missing secret: ${secret.key}',
      field: secret.key,
    );

    final ok = await CredentialPickerDialog.show(context, event: event);
    return ok;
  }

  /// Ask the user which provider a shared secret should be created
  /// under. Rare path — fires only when the daemon reports more
  /// than one `providers[]` entry for the same key.
  static Future<String?> _pickProviderFromList(
    BuildContext context, {
    required RequiredSecret secret,
  }) async {
    final c = context.colors;
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c.border),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.call_split_rounded, size: 18, color: c.blue),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Pick the provider',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: c.textBright,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  '${secret.key} is referenced by multiple providers. '
                  'Choose which one this credential belongs to:',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: c.text,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 14),
                for (final p in secret.providers)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, p),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: c.border),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        alignment: Alignment.centerLeft,
                      ),
                      child: Text(
                        p,
                        style: GoogleFonts.firaCode(
                            fontSize: 12.5, color: c.textBright),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(
                      'Cancel',
                      style: GoogleFonts.inter(
                          fontSize: 12, color: c.textMuted),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Future<bool> _showUnmappedSecretBanner(
    BuildContext context, {
    required String appId,
    required RequiredSecret secret,
  }) async {
    final c = context.colors;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => Dialog(
            backgroundColor: c.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: c.border),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.key_off_rounded,
                            size: 20, color: c.orange),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Custom secret required',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: c.textBright,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '$appId needs a secret this client does not know '
                      'how to prompt for:',
                      style: GoogleFonts.inter(
                          fontSize: 12, color: c.text, height: 1.5),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: c.surfaceAlt,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: c.border),
                      ),
                      child: Text(
                        secret.key,
                        style: GoogleFonts.firaCode(
                          fontSize: 12,
                          color: c.textBright,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Ask a workspace admin to create a system credential '
                      'for this key, or add it manually via Settings › '
                      'Credentials.',
                      style: GoogleFonts.inter(
                          fontSize: 11.5, color: c.textMuted, height: 1.5),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text(
                            'Cancel',
                            style: GoogleFonts.inter(
                                fontSize: 12, color: c.textMuted),
                          ),
                        ),
                        const Spacer(),
                        ElevatedButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: c.blue,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 10),
                          ),
                          child: Text(
                            'Open anyway',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ) ??
        false;
  }
}
