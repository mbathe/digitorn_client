/// Reusable preflight that blocks destructive actions (fire trigger,
/// create session, activate payload) when the current user is missing
/// required credentials, or when an existing credential is expired /
/// invalid.
///
/// Usage at any call site:
///
/// ```dart
/// if (!await ensureCredentials(
///   context,
///   appId: widget.app.appId,
///   appName: widget.app.name,
/// )) return;
/// ```
///
/// The function returns `true` when the action is allowed to proceed,
/// `false` when the user either dismissed the dialog or is still
/// missing credentials after editing them.
///
/// A 5-second in-memory cache avoids hammering the daemon when the
/// user clicks Fire / Activate repeatedly. The cache is keyed per
/// appId and cleared automatically after the user navigates to the
/// form (because the form re-fetches on pop).
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/credential_schema.dart';
import '../../services/auth_service.dart';
import '../../services/credential_service.dart';
import '../../theme/app_theme.dart';
import 'credentials_form.dart';

class _CacheEntry {
  final CredentialSchema schema;
  final DateTime at;
  const _CacheEntry(this.schema, this.at);
}

final Map<String, _CacheEntry> _schemaCache = {};
const _cacheTtl = Duration(seconds: 5);

/// Returns `true` when the user can proceed. Shows a blocking dialog
/// when credentials are missing, offers to open the form, then
/// re-checks on return.
Future<bool> ensureCredentials(
  BuildContext context, {
  required String appId,
  String appName = '',
}) async {
  CredentialSchema? schema;
  try {
    final cached = _schemaCache[appId];
    if (cached != null && DateTime.now().difference(cached.at) < _cacheTtl) {
      schema = cached.schema;
    } else {
      schema = await CredentialService().getSchema(appId);
      _schemaCache[appId] = _CacheEntry(schema, DateTime.now());
    }
  } on CredentialException catch (e) {
    // On 404 the app has no schema — treat as "no credentials needed".
    // On any other error let the action through; the daemon will
    // reject it with a clearer message if the call fails.
    if (e.statusCode == 404) return true;
    return true;
  }

  final issues = _auditSchema(schema);
  if (issues.isEmpty) return true;

  if (!context.mounted) return false;

  final goFix = await _showBlockingDialog(
    context,
    appName: appName.isNotEmpty ? appName : appId,
    issues: issues,
  );
  if (goFix != true) return false;
  if (!context.mounted) return false;

  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => CredentialsFormPage(appId: appId, appName: appName),
    ),
  );
  // Invalidate the cache so the next check re-fetches.
  _schemaCache.remove(appId);
  if (!context.mounted) return false;
  // Re-audit with fresh data. If the user fixed everything the
  // second call returns `true` silently; otherwise they see the
  // dialog again.
  return ensureCredentials(
    context,
    appId: appId,
    appName: appName,
  );
}

/// Hard-reset the cache — called from the credentials form itself
/// after a successful save / delete so a gate check right after is
/// never stale.
void invalidateCredentialCache([String? appId]) {
  if (appId == null) {
    _schemaCache.clear();
  } else {
    _schemaCache.remove(appId);
  }
}

class CredentialIssue {
  final String label;
  final String kind; // missing | expired | invalid
  const CredentialIssue({required this.label, required this.kind});
}

List<CredentialIssue> _auditSchema(CredentialSchema schema) {
  final isAdmin = AuthService().currentUser?.isAdmin ?? false;
  final out = <CredentialIssue>[];
  for (final p in schema.providers) {
    // Skip locked providers — a regular user can't resolve a
    // per_app_shared block, so gating on it would trap them with no
    // way forward.
    final canEdit = p.scope == 'per_user' ||
        (p.scope == 'per_app_shared' && isAdmin);
    if (!canEdit) continue;
    if (p.required && !p.filled) {
      out.add(CredentialIssue(label: p.label, kind: 'missing'));
    } else if (p.status == 'expired') {
      out.add(CredentialIssue(label: p.label, kind: 'expired'));
    } else if (p.status == 'invalid') {
      out.add(CredentialIssue(label: p.label, kind: 'invalid'));
    }
  }
  return out;
}

Future<bool?> _showBlockingDialog(
  BuildContext context, {
  required String appName,
  required List<CredentialIssue> issues,
}) {
  final c = context.colors;
  final blocking =
      issues.any((i) => i.kind == 'missing' || i.kind == 'invalid');
  final tint = blocking ? c.red : c.orange;
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      icon: Icon(
        blocking ? Icons.lock_outline_rounded : Icons.warning_amber_rounded,
        size: 28,
        color: tint,
      ),
      title: Text(
        blocking ? 'Credentials required' : 'Credentials need attention',
        textAlign: TextAlign.center,
        style: GoogleFonts.inter(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: c.textBright,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            blocking
                ? '$appName can\'t run until you finish the following:'
                : '$appName has credentials that will expire or have been rejected:',
            style: GoogleFonts.inter(
                fontSize: 12, color: c.text, height: 1.5),
          ),
          const SizedBox(height: 12),
          for (final i in issues)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: tint.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(3),
                      border:
                          Border.all(color: tint.withValues(alpha: 0.35)),
                    ),
                    child: Text(i.kind.toUpperCase(),
                        style: GoogleFonts.firaCode(
                            fontSize: 8,
                            color: tint,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3)),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(i.label,
                        style: GoogleFonts.inter(
                            fontSize: 12, color: c.textBright)),
                  ),
                ],
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text('Cancel',
              style: GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
        ),
        ElevatedButton.icon(
          onPressed: () => Navigator.pop(ctx, true),
          icon: const Icon(Icons.key_rounded, size: 14),
          label: Text('Configure',
              style: GoogleFonts.inter(
                  fontSize: 12, fontWeight: FontWeight.w600)),
          style: ElevatedButton.styleFrom(
            backgroundColor: tint,
            foregroundColor: Colors.white,
            elevation: 0,
          ),
        ),
      ],
    ),
  );
}
