/// Per-app credentials form. Rendered as the "Credentials" tab on the
/// app detail page. Dispatches each [CredentialProvider] to the right
/// widget based on its [type] field:
///
///   api_key          → [_ApiKeyCard]        (single secret + extras)
///   multi_field      → [_ApiKeyCard]        (same widget, many rows)
///   connection_string→ [_ConnectionCard]    (single URL + test button)
///   oauth2           → [_OauthCard]         (Connect button + status polling)
///   mcp_server       → [_McpCard]           (credentials + lifecycle)
///   custom           → [_ApiKeyCard]        (fallback)
///
/// The form is self-loading: pass in an [appId] and it fetches the
/// schema, manages its own loading / error states, and re-fetches
/// after every mutation so the status chips stay accurate.
library;

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/credential_schema.dart';
import '../../services/auth_service.dart';
import '../../services/credential_probe.dart';
import '../../services/credential_service.dart';
import '../../theme/app_theme.dart';
import 'credential_gate.dart';
import 'credential_onboarding.dart';

class CredentialsFormPage extends StatefulWidget {
  final String appId;
  final String appName;

  const CredentialsFormPage({
    super.key,
    required this.appId,
    this.appName = '',
  });

  @override
  State<CredentialsFormPage> createState() => _CredentialsFormPageState();
}

class _CredentialsFormPageState extends State<CredentialsFormPage> {
  final _svc = CredentialService();

  bool _loading = true;
  String? _error;
  CredentialSchema _schema = CredentialSchema.empty;

  /// Banner shown at the top of the form for structural errors that
  /// don't prevent rendering the existing providers (403 on a single
  /// admin-only field, 503 when an OAuth provider isn't configured
  /// daemon-side, etc.). Set from error-handler branches.
  Widget? _topErrorBanner;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _topErrorBanner = null;
    });
    try {
      final s = await _svc.getSchema(widget.appId);
      if (!mounted) return;
      // Any successful refresh invalidates any cached gate check
      // elsewhere in the app — the schema we're showing is now the
      // freshest source of truth.
      invalidateCredentialCache(widget.appId);
      setState(() {
        _schema = s;
        _loading = false;
      });
      // First-run onboarding: if the user has never seen this app's
      // credentials form AND it has required providers that are
      // currently missing, open the welcome modal once.
      if (s.hasProviders &&
          s.requiredMissingCount > 0 &&
          !await hasOnboarded(widget.appId)) {
        if (!mounted) return;
        await showCredentialOnboarding(
          context,
          appId: widget.appId,
          appName: widget.appName,
          schema: s,
        );
      }
    } on CredentialException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // 4xx surfaces as a dedicated banner instead of a full-page
        // error so the user can still see whichever providers the
        // daemon did return (partial schema is better than nothing).
        final banner = _bannerForError(e);
        if (banner != null) {
          _topErrorBanner = banner;
          _error = null;
        } else {
          _error = e.message;
        }
      });
    }
  }

  /// Returns a widget for the error banner when the HTTP status code
  /// has a specific UX (403/404/503), or null if it's a generic error
  /// that should just take the full-page error path.
  Widget? _bannerForError(CredentialException e) {
    switch (e.statusCode) {
      case 403:
        return _ErrorBanner(
          icon: Icons.lock_outline_rounded,
          tint: 'red',
          title: 'credentials.banner_admin_required_title'.tr(),
          body: 'credentials.banner_admin_required_body'.tr(),
        );
      case 404:
        return _ErrorBanner(
          icon: Icons.help_outline_rounded,
          tint: 'orange',
          title: 'credentials.banner_schema_not_found_title'.tr(),
          body: 'credentials.banner_schema_not_found_body'.tr(),
        );
      case 503:
        return _ErrorBanner(
          icon: Icons.cloud_off_outlined,
          tint: 'orange',
          title: 'credentials.banner_oauth_not_configured_title'.tr(),
          body: 'credentials.banner_oauth_not_configured_body'.tr(),
        );
      default:
        return null;
    }
  }

  /// Cross-provider health audit — returns a flat list of problems
  /// the user needs to fix before the app can run. Used by the header
  /// banner AND by the [ensureCredentials] gate check from outside.
  List<_HealthIssue> _computeHealthIssues() {
    final isAdmin = AuthService().currentUser?.isAdmin ?? false;
    final out = <_HealthIssue>[];
    for (final p in _schema.providers) {
      // Skip providers the current user can't fix themselves — they
      // appear in the form as locked cards but shouldn't count as
      // health issues the user is expected to resolve.
      final canEdit = p.scope == 'per_user' ||
          (p.scope == 'per_app_shared' && isAdmin);
      if (!canEdit) continue;
      if (p.required && !p.filled) {
        out.add(_HealthIssue.missing(p.label));
      } else if (p.status == 'expired') {
        out.add(_HealthIssue.expired(p.label));
      } else if (p.status == 'invalid') {
        out.add(_HealthIssue.invalid(p.label));
      }
    }
    return out;
  }

  void _toast(String msg, {bool err = false}) {
    if (!mounted) return;
    final c = context.colors;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: (err ? c.red : c.green).withValues(alpha: 0.9),
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.surface,
        elevation: 0,
        foregroundColor: c.text,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('credentials.title'.tr(),
                style: GoogleFonts.inter(
                    fontSize: 14,
                    color: c.textBright,
                    fontWeight: FontWeight.w600)),
            if (widget.appName.isNotEmpty)
              Text(widget.appName,
                  style: GoogleFonts.firaCode(
                      fontSize: 10.5, color: c.textMuted)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'credentials.refresh'.tr(),
            icon: Icon(Icons.refresh_rounded, size: 18, color: c.textMuted),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const _FormSpinner()
          : _error != null
              ? _ErrorBlock(message: _error!, onRetry: _load)
              : _buildBody(c),
    );
  }

  Widget _buildBody(AppColors c) {
    if (!_schema.hasProviders) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle_outline_rounded,
                    size: 36, color: c.green),
                const SizedBox(height: 12),
                Text('credentials.no_credentials_needed'.tr(),
                    style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: c.textBright)),
              ],
            ),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_topErrorBanner != null) ...[
                _topErrorBanner!,
                const SizedBox(height: 20),
              ],
              if (_computeHealthIssues().isNotEmpty) ...[
                _HealthBanner(issues: _computeHealthIssues()),
                const SizedBox(height: 20),
              ],
              ..._schema.providers.map(
                (p) => Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: _ProviderCard(
                    appId: widget.appId,
                    provider: p,
                    onDirty: _load,
                    onToast: _toast,
                  ),
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Shared pieces ────────────────────────────────────────────────────────

class _FormSpinner extends StatelessWidget {
  const _FormSpinner();
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: c.textMuted),
      ),
    );
  }
}

class _ErrorBlock extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorBlock({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 36, color: c.red),
              const SizedBox(height: 12),
              Text('credentials.load_failed'.tr(),
                  style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: c.textBright)),
              const SizedBox(height: 6),
              Text(message,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.firaCode(
                      fontSize: 11, color: c.textMuted, height: 1.5)),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: onRetry,
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.surfaceAlt,
                  foregroundColor: c.text,
                  elevation: 0,
                  side: BorderSide(color: c.border),
                ),
                child: Text('credentials.retry'.tr(),
                    style: GoogleFonts.inter(fontSize: 12)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Flat description of one credentials-health issue. Used both by the
/// in-form banner AND by the external [ensureCredentials] gate so the
/// wording stays consistent across the client.
class _HealthIssue {
  final String label;
  final _HealthIssueKind kind;
  const _HealthIssue(this.label, this.kind);
  factory _HealthIssue.missing(String label) =>
      _HealthIssue(label, _HealthIssueKind.missing);
  factory _HealthIssue.expired(String label) =>
      _HealthIssue(label, _HealthIssueKind.expired);
  factory _HealthIssue.invalid(String label) =>
      _HealthIssue(label, _HealthIssueKind.invalid);

  String get verb => switch (kind) {
        _HealthIssueKind.missing => 'credentials.health_verb_missing'.tr(),
        _HealthIssueKind.expired => 'credentials.health_verb_expired'.tr(),
        _HealthIssueKind.invalid => 'credentials.health_verb_invalid'.tr(),
      };
}

enum _HealthIssueKind { missing, expired, invalid }

class _HealthBanner extends StatelessWidget {
  final List<_HealthIssue> issues;
  const _HealthBanner({required this.issues});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hasBlocking = issues.any((i) =>
        i.kind == _HealthIssueKind.missing ||
        i.kind == _HealthIssueKind.invalid);
    final tint = hasBlocking ? c.red : c.orange;
    final title = hasBlocking
        ? (issues.length == 1
            ? 'credentials.health_blocking_one'
                .tr(namedArgs: {'n': '${issues.length}'})
            : 'credentials.health_blocking'
                .tr(namedArgs: {'n': '${issues.length}'}))
        : (issues.length == 1
            ? 'credentials.health_attention_one'
                .tr(namedArgs: {'n': '${issues.length}'})
            : 'credentials.health_attention'
                .tr(namedArgs: {'n': '${issues.length}'}));
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            hasBlocking
                ? Icons.error_outline_rounded
                : Icons.warning_amber_rounded,
            size: 18,
            color: tint,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: tint)),
                const SizedBox(height: 4),
                for (final i in issues)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '• ${i.label} — ${i.verb}',
                      style: GoogleFonts.inter(
                          fontSize: 11, color: c.text, height: 1.45),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Generic top-of-form error banner. Different from [_HealthBanner]:
/// this one describes a structural problem (403/404/503) — the user
/// can't fix it themselves from this page.
class _ErrorBanner extends StatelessWidget {
  final IconData icon;
  final String tint;
  final String title;
  final String body;
  const _ErrorBanner({
    required this.icon,
    required this.tint,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final colour = tint == 'red' ? c.red : c.orange;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colour.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: colour),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colour)),
                const SizedBox(height: 4),
                Text(body,
                    style: GoogleFonts.inter(
                        fontSize: 11, color: c.text, height: 1.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Provider card dispatcher ─────────────────────────────────────────────

class _ProviderCard extends StatelessWidget {
  final String appId;
  final CredentialProvider provider;
  final Future<void> Function() onDirty;
  final void Function(String msg, {bool err}) onToast;

  const _ProviderCard({
    required this.appId,
    required this.provider,
    required this.onDirty,
    required this.onToast,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isAdmin = AuthService().currentUser?.isAdmin ?? false;

    // system_wide is never editable from the client — that's daemon
    // config managed via oauth_providers.toml. per_app_shared is
    // editable by admins only; regular users see a read-only lock.
    final locked = provider.scope == 'system_wide' ||
        (provider.scope == 'per_app_shared' && !isAdmin);
    if (locked) {
      return _LockedCard(provider: provider);
    }

    final Widget body;
    if (provider.isOAuth) {
      body = _OauthCard(
          appId: appId, provider: provider, onDirty: onDirty, onToast: onToast);
    } else if (provider.isMcp) {
      body = _McpCard(
          appId: appId, provider: provider, onDirty: onDirty, onToast: onToast);
    } else if (provider.isConnectionString) {
      body = _ConnectionCard(
          appId: appId, provider: provider, onDirty: onDirty, onToast: onToast);
    } else {
      // api_key + multi_field + custom all use the same form
      body = _ApiKeyCard(
          appId: appId, provider: provider, onDirty: onDirty, onToast: onToast);
    }

    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: body,
    );
  }
}

// ─── Header shared by all card types ──────────────────────────────────────

class _CardHeader extends StatelessWidget {
  final CredentialProvider provider;
  final Widget? trailing;
  const _CardHeader({required this.provider, this.trailing});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final icon = _iconFor(provider);
    final style = _statusStyle(c, provider.status);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 8),
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
            child: Icon(icon, size: 16, color: c.text),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        provider.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: c.textBright,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (provider.required)
                      _Pill(
                        label: 'credentials.pill_required'.tr(),
                        fg: c.red,
                        bg: c.red.withValues(alpha: 0.1),
                      ),
                    const SizedBox(width: 6),
                    _Pill(
                      label: style.label,
                      fg: style.fg,
                      bg: style.bg,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${provider.scope} · ${provider.type}',
                  style: GoogleFonts.firaCode(
                      fontSize: 10, color: c.textMuted),
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

IconData _iconFor(CredentialProvider p) {
  switch (p.name.toLowerCase()) {
    case 'openai':
      return Icons.bolt_rounded;
    case 'anthropic':
      return Icons.auto_awesome_rounded;
    case 'notion':
      return Icons.description_outlined;
    case 'gmail':
    case 'google':
      return Icons.mail_outline_rounded;
    case 'slack':
      return Icons.tag_rounded;
    case 'telegram':
      return Icons.send_rounded;
    case 'discord':
      return Icons.chat_bubble_outline_rounded;
    case 'github':
      return Icons.hub_outlined;
    case 'aws':
      return Icons.cloud_outlined;
    case 'twilio':
      return Icons.phone_outlined;
    case 'serpapi':
      return Icons.search_rounded;
    default:
      if (p.isMcp) return Icons.electrical_services_rounded;
      if (p.isOAuth) return Icons.link_rounded;
      if (p.isConnectionString) return Icons.storage_rounded;
      return Icons.key_rounded;
  }
}

CredentialStatusStyle _statusStyle(AppColors c, String status) {
  switch (status) {
    case 'valid':
      return CredentialStatusStyle(
          c.green, c.green.withValues(alpha: 0.1), 'credentials.status_ok'.tr());
    case 'filled':
      return CredentialStatusStyle(c.blue, c.blue.withValues(alpha: 0.1),
          'credentials.status_saved'.tr());
    case 'expired':
      return CredentialStatusStyle(c.orange, c.orange.withValues(alpha: 0.1),
          'credentials.status_expired'.tr());
    case 'invalid':
      return CredentialStatusStyle(c.red, c.red.withValues(alpha: 0.1),
          'credentials.status_invalid'.tr());
    case 'refreshing':
      return CredentialStatusStyle(c.blue, c.blue.withValues(alpha: 0.1),
          'credentials.status_refresh'.tr());
    case 'error':
      return CredentialStatusStyle(c.red, c.red.withValues(alpha: 0.1),
          'credentials.status_error'.tr());
    default:
      return CredentialStatusStyle(
          c.textMuted, c.surfaceAlt, 'credentials.status_not_set'.tr());
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color fg;
  final Color bg;
  const _Pill({required this.label, required this.fg, required this.bg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: fg.withValues(alpha: 0.35), width: 0.8),
      ),
      child: Text(
        label,
        style: GoogleFonts.firaCode(
          fontSize: 8.5,
          color: fg,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

// ─── Locked card (per_app_shared / system_wide for non-admins) ────────────

class _LockedCard extends StatelessWidget {
  final CredentialProvider provider;
  const _LockedCard({required this.provider});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final msg = provider.scope == 'system_wide'
        ? 'credentials.locked_system_wide'.tr()
        : 'credentials.locked_per_app_shared'.tr();
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          _CardHeader(
            provider: provider,
            trailing: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(Icons.lock_outline_rounded,
                  size: 15, color: c.textMuted),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Text(
              msg,
              style: GoogleFonts.inter(
                  fontSize: 11.5, color: c.textMuted, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── api_key / multi_field / custom ───────────────────────────────────────

class _ApiKeyCard extends StatefulWidget {
  final String appId;
  final CredentialProvider provider;
  final Future<void> Function() onDirty;
  final void Function(String msg, {bool err}) onToast;

  const _ApiKeyCard({
    required this.appId,
    required this.provider,
    required this.onDirty,
    required this.onToast,
  });

  @override
  State<_ApiKeyCard> createState() => _ApiKeyCardState();
}

class _ApiKeyCardState extends State<_ApiKeyCard> {
  final _svc = CredentialService();
  final Map<String, TextEditingController> _ctrls = {};
  final Map<String, bool> _editing = {};
  final Map<String, bool> _showPlain = {};
  final Map<String, String?> _errors = {};
  bool _saving = false;
  bool _deleting = false;
  bool _testing = false;
  CredentialProbeResult? _probeResult;

  @override
  void initState() {
    super.initState();
    for (final f in widget.provider.fields) {
      _ctrls[f.name] = TextEditingController();
      _editing[f.name] = !(widget.provider.filled &&
          widget.provider.maskedFields.containsKey(f.name) &&
          f.isSecret);
      _showPlain[f.name] = false;
    }
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool _canSave() {
    for (final f in widget.provider.fields) {
      if (!(_editing[f.name] ?? true)) continue;
      final value = _ctrls[f.name]?.text ?? '';
      final err = f.validate(value);
      if (err != null) return false;
    }
    return true;
  }

  Future<void> _save() async {
    // Validate everything we're about to send.
    final payload = <String, dynamic>{};
    var anyInvalid = false;
    final newErrors = <String, String?>{};
    for (final f in widget.provider.fields) {
      if (!(_editing[f.name] ?? true)) continue;
      final value = _ctrls[f.name]?.text ?? '';
      final err = f.validate(value);
      newErrors[f.name] = err;
      if (err != null) {
        anyInvalid = true;
        continue;
      }
      if (value.isNotEmpty) payload[f.name] = value;
    }
    setState(() {
      _errors
        ..clear()
        ..addAll(newErrors);
    });
    if (anyInvalid) return;
    if (payload.isEmpty) {
      widget.onToast('credentials.toast_nothing_to_save'.tr(), err: true);
      return;
    }

    setState(() => _saving = true);
    try {
      await _svc.upsert(
        appId: widget.appId,
        providerName: widget.provider.name,
        fields: payload,
      );
      widget.onToast('credentials.toast_saved_of'
          .tr(namedArgs: {'name': widget.provider.label}));
      await widget.onDirty();
    } on CredentialException catch (e) {
      widget.onToast(e.message, err: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Hits the provider's real API with the currently-typed values to
  /// validate them before save. Only available for providers we have
  /// a recipe for in [CredentialProbe].
  Future<void> _test() async {
    final fields = <String, String>{};
    for (final f in widget.provider.fields) {
      final v = _ctrls[f.name]?.text ?? '';
      if (v.isNotEmpty) fields[f.name] = v;
    }
    if (fields.isEmpty) {
      widget.onToast('credentials.toast_type_field_first'.tr(), err: true);
      return;
    }
    setState(() {
      _testing = true;
      _probeResult = null;
    });
    final result =
        await CredentialProbe.probe(widget.provider.name, fields);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _probeResult = result;
    });
  }

  Future<void> _delete() async {
    final ok = await _confirmDelete();
    if (ok != true || !mounted) return;
    setState(() => _deleting = true);
    try {
      await _svc.delete(
        appId: widget.appId,
        providerName: widget.provider.name,
      );
      widget.onToast('credentials.toast_removed_of'
          .tr(namedArgs: {'name': widget.provider.label}));
      await widget.onDirty();
    } on CredentialException catch (e) {
      widget.onToast(e.message, err: true);
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<bool?> _confirmDelete() {
    final c = context.colors;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: c.border),
        ),
        title: Text(
            'credentials.remove_confirm_title'
                .tr(namedArgs: {'name': widget.provider.label}),
            style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: c.textBright)),
        content: Text(
            'credentials.remove_confirm_body'.tr(),
            style: GoogleFonts.inter(
                fontSize: 12, color: c.text, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('credentials.cancel'.tr(),
                style: GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: c.red,
                foregroundColor: Colors.white,
                elevation: 0),
            child: Text('credentials.remove'.tr(),
                style: GoogleFonts.inter(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final p = widget.provider;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CardHeader(provider: p),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (p.description.isNotEmpty) ...[
                Text(p.description,
                    style: GoogleFonts.inter(
                        fontSize: 11.5, color: c.text, height: 1.5)),
                const SizedBox(height: 12),
              ],
              for (final f in p.fields) _buildField(c, f),
              if (_probeResult != null) ...[
                const SizedBox(height: 4),
                _buildProbeResult(c),
              ],
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (p.filled)
                    TextButton.icon(
                      onPressed: _deleting ? null : _delete,
                      icon: _deleting
                          ? SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                  strokeWidth: 1.2, color: c.red),
                            )
                          : Icon(Icons.delete_outline_rounded,
                              size: 14, color: c.red),
                      label: Text('credentials.remove'.tr(),
                          style: GoogleFonts.inter(
                              fontSize: 12, color: c.red)),
                    ),
                  const Spacer(),
                  if (CredentialProbe.canProbe(p.name)) ...[
                    OutlinedButton.icon(
                      onPressed: _testing ? null : _test,
                      icon: _testing
                          ? SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                  strokeWidth: 1.2, color: c.text),
                            )
                          : Icon(Icons.network_check_rounded,
                              size: 13, color: c.text),
                      label: Text('credentials.test'.tr(),
                          style: GoogleFonts.inter(
                              fontSize: 12, color: c.text)),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: c.border),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  ElevatedButton(
                    onPressed:
                        _saving || !_canSave() ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: c.blue,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6)),
                    ),
                    child: _saving
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                                strokeWidth: 1.5, color: Colors.white),
                          )
                        : Text('credentials.save'.tr(),
                            style: GoogleFonts.inter(
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildProbeResult(AppColors c) {
    final r = _probeResult!;
    final tint = r.ok ? c.green : c.red;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(
            r.ok
                ? Icons.check_circle_outline_rounded
                : Icons.error_outline_rounded,
            size: 14,
            color: tint,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              r.message,
              style: GoogleFonts.firaCode(
                  fontSize: 11, color: tint, height: 1.4),
            ),
          ),
          if (r.statusCode != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text('${r.statusCode}',
                  style: GoogleFonts.firaCode(
                      fontSize: 10, color: tint, fontWeight: FontWeight.w700)),
            ),
          ],
          const SizedBox(width: 6),
          Text('${r.latencyMs}ms',
              style:
                  GoogleFonts.firaCode(fontSize: 9.5, color: c.textMuted)),
        ],
      ),
    );
  }

  Widget _buildField(AppColors c, CredentialField f) {
    final isEditing = _editing[f.name] ?? true;
    final masked = widget.provider.maskedFields[f.name];
    final err = _errors[f.name];

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                f.label,
                style: GoogleFonts.inter(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: c.textBright),
              ),
              if (f.required) ...[
                const SizedBox(width: 4),
                Text('*', style: GoogleFonts.inter(fontSize: 12, color: c.red)),
              ],
              const Spacer(),
              if (f.docsUrl.isNotEmpty)
                _DocsLink(url: f.docsUrl),
            ],
          ),
          const SizedBox(height: 4),
          if (!isEditing && masked != null)
            _buildMaskedRow(c, f, masked)
          else
            _buildInput(c, f),
          if (f.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(f.description,
                style: GoogleFonts.inter(
                    fontSize: 10.5, color: c.textMuted, height: 1.4)),
          ],
          if (err != null) ...[
            const SizedBox(height: 4),
            Text('⚠ $err',
                style: GoogleFonts.inter(fontSize: 10.5, color: c.red)),
          ],
        ],
      ),
    );
  }

  Widget _buildMaskedRow(AppColors c, CredentialField f, String masked) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              masked,
              style: GoogleFonts.firaCode(
                  fontSize: 12, color: c.textMuted),
            ),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _editing[f.name] = true;
                _ctrls[f.name]?.clear();
              });
            },
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
            ),
            child: Text('credentials.change'.tr(),
                style: GoogleFonts.inter(fontSize: 11, color: c.blue)),
          ),
        ],
      ),
    );
  }

  Widget _buildInput(AppColors c, CredentialField f) {
    if (f.isSelect) {
      return DropdownButtonFormField<String>(
        initialValue: _ctrls[f.name]?.text.isNotEmpty == true
            ? _ctrls[f.name]!.text
            : null,
        items: f.options
            .map((o) => DropdownMenuItem(value: o, child: Text(o)))
            .toList(),
        onChanged: (v) {
          _ctrls[f.name]?.text = v ?? '';
          setState(() {});
        },
        decoration: _inputDecoration(c, placeholder: f.placeholder),
        style: GoogleFonts.inter(fontSize: 12, color: c.textBright),
        dropdownColor: c.surface,
      );
    }
    return TextField(
      controller: _ctrls[f.name],
      obscureText: f.isSecret && !(_showPlain[f.name] ?? false),
      autocorrect: !f.isSecret,
      enableSuggestions: !f.isSecret,
      onChanged: (_) => setState(() {}),
      style: GoogleFonts.firaCode(
          fontSize: 12, color: c.textBright),
      decoration: _inputDecoration(
        c,
        placeholder: f.placeholder,
        suffix: f.isSecret
            ? IconButton(
                padding: EdgeInsets.zero,
                iconSize: 14,
                icon: Icon(
                  (_showPlain[f.name] ?? false)
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                  color: c.textMuted,
                ),
                onPressed: () => setState(
                    () => _showPlain[f.name] = !(_showPlain[f.name] ?? false)),
              )
            : null,
      ),
    );
  }

  InputDecoration _inputDecoration(AppColors c,
      {String placeholder = '', Widget? suffix}) {
    return InputDecoration(
      isDense: true,
      hintText: placeholder,
      hintStyle: GoogleFonts.firaCode(fontSize: 12, color: c.textDim),
      filled: true,
      fillColor: c.surfaceAlt,
      suffixIcon: suffix,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: c.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: c.blue, width: 1.2),
      ),
    );
  }
}

class _DocsLink extends StatelessWidget {
  final String url;
  const _DocsLink({required this.url});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return TextButton.icon(
      onPressed: () => launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication),
      icon: Icon(Icons.open_in_new_rounded, size: 11, color: c.blue),
      label: Text('credentials.docs_where'.tr(),
          style: GoogleFonts.inter(fontSize: 10.5, color: c.blue)),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        minimumSize: const Size(0, 24),
      ),
    );
  }
}

// ─── connection_string ────────────────────────────────────────────────────

class _ConnectionCard extends StatefulWidget {
  final String appId;
  final CredentialProvider provider;
  final Future<void> Function() onDirty;
  final void Function(String msg, {bool err}) onToast;

  const _ConnectionCard({
    required this.appId,
    required this.provider,
    required this.onDirty,
    required this.onToast,
  });

  @override
  State<_ConnectionCard> createState() => _ConnectionCardState();
}

class _ConnectionCardState extends State<_ConnectionCard> {
  final _svc = CredentialService();
  final _ctrl = TextEditingController();
  bool _editing = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _editing = !widget.provider.filled;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  CredentialField get _field => widget.provider.fields.firstWhere(
        (f) => true,
        orElse: () => const CredentialField(
            name: 'url', type: 'connection_string', required: true),
      );

  Future<void> _save() async {
    final value = _ctrl.text.trim();
    final err = _field.validate(value);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _svc.upsert(
        appId: widget.appId,
        providerName: widget.provider.name,
        fields: {_field.name: value},
      );
      widget.onToast('credentials.toast_saved_of'
          .tr(namedArgs: {'name': widget.provider.label}));
      await widget.onDirty();
    } on CredentialException catch (e) {
      widget.onToast(e.message, err: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final p = widget.provider;
    final masked = p.maskedFields[_field.name];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CardHeader(provider: p),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_field.label,
                  style: GoogleFonts.inter(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: c.textBright)),
              const SizedBox(height: 4),
              if (!_editing && masked != null)
                Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: c.border),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          masked,
                          style: GoogleFonts.firaCode(
                              fontSize: 12, color: c.textMuted),
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(() {
                          _editing = true;
                          _ctrl.clear();
                        }),
                        child: Text('credentials.change'.tr(),
                            style: GoogleFonts.inter(
                                fontSize: 11, color: c.blue)),
                      ),
                    ],
                  ),
                )
              else
                TextField(
                  controller: _ctrl,
                  style: GoogleFonts.firaCode(
                      fontSize: 12, color: c.textBright),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: _field.placeholder.isNotEmpty
                        ? _field.placeholder
                        : 'credentials.connection_string_placeholder'.tr(),
                    hintStyle: GoogleFonts.firaCode(
                        fontSize: 12, color: c.textDim),
                    filled: true,
                    fillColor: c.surfaceAlt,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(color: c.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(color: c.blue, width: 1.2),
                    ),
                  ),
                ),
              if (_error != null) ...[
                const SizedBox(height: 4),
                Text('⚠ $_error',
                    style: GoogleFonts.inter(fontSize: 10.5, color: c.red)),
              ],
              if (_field.description.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(_field.description,
                    style: GoogleFonts.inter(
                        fontSize: 10.5, color: c.textMuted, height: 1.4)),
              ],
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: c.blue,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6)),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                              strokeWidth: 1.5, color: Colors.white),
                        )
                      : Text('credentials.save'.tr(),
                          style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── oauth2 ───────────────────────────────────────────────────────────────

class _OauthCard extends StatefulWidget {
  final String appId;
  final CredentialProvider provider;
  final Future<void> Function() onDirty;
  final void Function(String msg, {bool err}) onToast;

  const _OauthCard({
    required this.appId,
    required this.provider,
    required this.onDirty,
    required this.onToast,
  });

  @override
  State<_OauthCard> createState() => _OauthCardState();
}

class _OauthCardState extends State<_OauthCard> {
  final _svc = CredentialService();
  bool _busy = false;
  String? _progressMsg;

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _progressMsg = 'credentials.oauth_opening_browser'.tr();
    });
    try {
      final start = await _svc.startOauth(
        appId: widget.appId,
        providerName: widget.provider.name,
      );
      await launchUrl(Uri.parse(start.authUrl),
          mode: LaunchMode.externalApplication);
      if (!mounted) return;
      setState(() => _progressMsg = 'credentials.oauth_waiting_consent'.tr());
      final result = await _svc.pollOauthUntilDone(
        appId: widget.appId,
        providerName: widget.provider.name,
        state: start.state,
      );
      if (!mounted) return;
      if (result.status == 'connected') {
        widget.onToast('credentials.toast_connected_to'
            .tr(namedArgs: {'name': widget.provider.label}));
        await widget.onDirty();
      } else {
        widget.onToast(
          result.error ??
              'credentials.toast_connection_status'
                  .tr(namedArgs: {'status': result.status}),
          err: true,
        );
      }
    } on CredentialException catch (e) {
      widget.onToast(e.message, err: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      await _svc.refreshOauth(
        appId: widget.appId,
        providerName: widget.provider.name,
      );
      widget.onToast('credentials.toast_token_refreshed'.tr());
      await widget.onDirty();
    } on CredentialException catch (e) {
      widget.onToast(e.message, err: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    try {
      await _svc.delete(
        appId: widget.appId,
        providerName: widget.provider.name,
      );
      widget.onToast('credentials.toast_disconnected'.tr());
      await widget.onDirty();
    } on CredentialException catch (e) {
      widget.onToast(e.message, err: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final p = widget.provider;
    final connected =
        p.oauthStatus == 'connected' || (p.filled && p.status == 'valid');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CardHeader(provider: p),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (p.description.isNotEmpty) ...[
                Text(p.description,
                    style: GoogleFonts.inter(
                        fontSize: 11.5, color: c.text, height: 1.5)),
                const SizedBox(height: 10),
              ],
              if (p.oauthScopes.isNotEmpty) ...[
                Text('credentials.oauth_scopes'.tr(),
                    style: GoogleFonts.inter(
                        fontSize: 10,
                        color: c.textMuted,
                        letterSpacing: 0.3)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 5,
                  runSpacing: 4,
                  children: [
                    for (final s in p.oauthScopes)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: c.surfaceAlt,
                          borderRadius: BorderRadius.circular(3),
                          border: Border.all(color: c.border),
                        ),
                        child: Text(s,
                            style: GoogleFonts.firaCode(
                                fontSize: 9.5, color: c.text)),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              if (connected) ...[
                if (p.oauthAccount != null && p.oauthAccount!.isNotEmpty)
                  Row(
                    children: [
                      Icon(Icons.account_circle_outlined,
                          size: 13, color: c.green),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'credentials.oauth_connected_as'
                              .tr(namedArgs: {'account': p.oauthAccount!}),
                          style: GoogleFonts.inter(
                              fontSize: 11.5, color: c.text),
                        ),
                      ),
                    ],
                  ),
                if (p.oauthExpiresAt != null) ...[
                  const SizedBox(height: 2),
                  Text(
                      'credentials.oauth_expires'
                          .tr(namedArgs: {'at': p.oauthExpiresAt!}),
                      style: GoogleFonts.firaCode(
                          fontSize: 10, color: c.textMuted)),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _refresh,
                      icon:
                          Icon(Icons.refresh_rounded, size: 14, color: c.text),
                      label: Text('credentials.refresh'.tr(),
                          style: GoogleFonts.inter(
                              fontSize: 11.5, color: c.text)),
                      style: OutlinedButton.styleFrom(
                          side: BorderSide(color: c.border)),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _connect,
                      icon: Icon(Icons.link_rounded, size: 14, color: c.text),
                      label: Text('credentials.oauth_reconnect'.tr(),
                          style: GoogleFonts.inter(
                              fontSize: 11.5, color: c.text)),
                      style: OutlinedButton.styleFrom(
                          side: BorderSide(color: c.border)),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _busy ? null : _disconnect,
                      icon: Icon(Icons.link_off_rounded,
                          size: 14, color: c.red),
                      label: Text('credentials.oauth_disconnect'.tr(),
                          style: GoogleFonts.inter(
                              fontSize: 11.5, color: c.red)),
                    ),
                  ],
                ),
              ] else ...[
                ElevatedButton.icon(
                  onPressed: _busy ? null : _connect,
                  icon: _busy
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                              strokeWidth: 1.5, color: Colors.white),
                        )
                      : const Icon(Icons.link_rounded,
                          size: 14, color: Colors.white),
                  label: Text(
                    _busy && _progressMsg != null
                        ? _progressMsg!
                        : 'credentials.oauth_connect_of'
                            .tr(namedArgs: {'name': p.label}),
                    style: GoogleFonts.inter(
                        fontSize: 12,
                        color: Colors.white,
                        fontWeight: FontWeight.w600),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: c.blue,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ─── mcp_server ───────────────────────────────────────────────────────────

class _McpCard extends StatefulWidget {
  final String appId;
  final CredentialProvider provider;
  final Future<void> Function() onDirty;
  final void Function(String msg, {bool err}) onToast;

  const _McpCard({
    required this.appId,
    required this.provider,
    required this.onDirty,
    required this.onToast,
  });

  @override
  State<_McpCard> createState() => _McpCardState();
}

class _McpCardState extends State<_McpCard> with WidgetsBindingObserver {
  final _svc = CredentialService();
  McpStatus _status = McpStatus.stopped;
  bool _polling = false;
  bool _busy = false;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fetchStatus();
    _startPolling();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) _fetchStatus();
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startPolling();
      _fetchStatus();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive) {
      _stopPolling();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchStatus() async {
    if (_polling) return;
    _polling = true;
    try {
      final s = await _svc.getMcpStatus(
        appId: widget.appId,
        providerName: widget.provider.name,
      );
      if (!mounted) return;
      setState(() => _status = s);
    } on CredentialException {
      // Silent — the polling card shouldn't spam errors.
    } finally {
      _polling = false;
    }
  }

  Future<void> _start() async {
    setState(() => _busy = true);
    try {
      await _svc.startMcp(
        appId: widget.appId,
        providerName: widget.provider.name,
      );
      widget.onToast('credentials.toast_mcp_starting'
          .tr(namedArgs: {'name': widget.provider.label}));
      await Future.delayed(const Duration(milliseconds: 500));
      await _fetchStatus();
      await widget.onDirty();
    } on CredentialException catch (e) {
      widget.onToast(e.message, err: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    setState(() => _busy = true);
    try {
      await _svc.stopMcp(
        appId: widget.appId,
        providerName: widget.provider.name,
      );
      widget.onToast('credentials.toast_mcp_stopped'
          .tr(namedArgs: {'name': widget.provider.label}));
      await _fetchStatus();
      await widget.onDirty();
    } on CredentialException catch (e) {
      widget.onToast(e.message, err: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restart() async {
    await _stop();
    await _start();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final p = widget.provider;
    final running = _status.running;
    final runLabel = running
        ? 'credentials.mcp_running'.tr()
        : 'credentials.mcp_stopped'.tr();
    final runColor = running
        ? c.green
        : _status.status == 'error'
            ? c.red
            : c.textMuted;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CardHeader(
          provider: p,
          trailing: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle, color: runColor),
                ),
                const SizedBox(width: 5),
                Text(runLabel,
                    style: GoogleFonts.inter(
                        fontSize: 10.5, color: runColor)),
                if (running && _status.toolsCount > 0) ...[
                  const SizedBox(width: 8),
                  Text(
                      'credentials.mcp_tools_count'
                          .tr(namedArgs: {'n': '${_status.toolsCount}'}),
                      style: GoogleFonts.firaCode(
                          fontSize: 10, color: c.textMuted)),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (p.description.isNotEmpty) ...[
                Text(p.description,
                    style: GoogleFonts.inter(
                        fontSize: 11.5, color: c.text, height: 1.5)),
                const SizedBox(height: 10),
              ],
              Row(
                children: [
                  Text(
                      'credentials.mcp_transport'.tr(namedArgs: {
                        'type': _status.transportType.isNotEmpty
                            ? _status.transportType
                            : 'stdio'
                      }),
                      style: GoogleFonts.firaCode(
                          fontSize: 10, color: c.textMuted)),
                ],
              ),
              const SizedBox(height: 12),
              // Reuse the api_key form body for the MCP credentials
              _ApiKeyCard(
                appId: widget.appId,
                provider: widget.provider,
                onDirty: () async {
                  await widget.onDirty();
                  await _restart();
                },
                onToast: widget.onToast,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _LifecycleBtn(
                    icon: Icons.play_arrow_rounded,
                    label: 'credentials.mcp_start'.tr(),
                    color: c.green,
                    enabled: !running && !_busy,
                    onTap: _start,
                  ),
                  const SizedBox(width: 8),
                  _LifecycleBtn(
                    icon: Icons.stop_rounded,
                    label: 'credentials.mcp_stop'.tr(),
                    color: c.orange,
                    enabled: running && !_busy,
                    onTap: _stop,
                  ),
                  const SizedBox(width: 8),
                  _LifecycleBtn(
                    icon: Icons.refresh_rounded,
                    label: 'credentials.mcp_restart'.tr(),
                    color: c.blue,
                    enabled: !_busy,
                    onTap: _restart,
                  ),
                ],
              ),
              if (_status.lastError != null &&
                  _status.lastError!.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: c.red.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                    border:
                        Border.all(color: c.red.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.error_outline_rounded,
                          size: 13, color: c.red),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _status.lastError!,
                          style: GoogleFonts.firaCode(
                              fontSize: 10.5, color: c.red, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _LifecycleBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool enabled;
  final VoidCallback onTap;

  const _LifecycleBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return OutlinedButton.icon(
      onPressed: enabled ? onTap : null,
      icon: Icon(icon, size: 13, color: enabled ? color : c.textDim),
      label: Text(label,
          style: GoogleFonts.inter(
              fontSize: 11, color: enabled ? color : c.textDim)),
      style: OutlinedButton.styleFrom(
        side: BorderSide(
            color: enabled
                ? color.withValues(alpha: 0.35)
                : c.border),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
    );
  }
}
