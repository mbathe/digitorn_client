/// Global "My Credentials" dashboard — cross-app view of everything
/// the current user has configured. Grouped by scope:
///
///   1. Global (cross-app) credentials (`_global`)
///   2. Per-app credentials, grouped by app_id
///
/// Tapping a card jumps to the per-app [CredentialsFormPage] so the
/// user can edit / remove the entry in its proper context.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/app_summary.dart';
import '../../models/credential_schema.dart';
import '../../services/apps_service.dart';
import '../../services/credential_service.dart';
import '../../theme/app_theme.dart';
import 'credentials_form.dart';

class MyCredentialsPage extends StatefulWidget {
  const MyCredentialsPage({super.key});

  @override
  State<MyCredentialsPage> createState() => _MyCredentialsPageState();
}

class _MyCredentialsPageState extends State<MyCredentialsPage> {
  final _svc = CredentialService();
  final _appsSvc = AppsService();

  bool _loading = true;
  String? _error;
  List<UserCredentialEntry> _entries = const [];

  /// Built after every [_load]: `providerName -> [appLabel, …]` so each
  /// global credential card can show *"Used by digitorn-chat, job-hunter"*.
  /// Empty for providers that no app in the user's workspace references.
  Map<String, List<String>> _providerUsage = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _svc.listMine();
      if (!mounted) return;
      // Fire the cross-ref asynchronously — don't block the first
      // render on the N+1 schema fetches.
      setState(() {
        _entries = list;
        _loading = false;
      });
      unawaited(_buildProviderUsage());
    } on CredentialException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  /// Cross-reference global per-user credentials against every app's
  /// `credentials_schema` so we can show *"Used by X, Y, Z"* under
  /// each global card. Failures (per-app 403/404) are swallowed — a
  /// missing reference just means an empty "Used by" line.
  Future<void> _buildProviderUsage() async {
    // Refresh the apps list when the service hasn't loaded one yet.
    if (_appsSvc.apps.isEmpty) {
      try {
        await _appsSvc.refresh();
      } catch (_) {
        return;
      }
    }
    final apps = _appsSvc.apps;
    if (apps.isEmpty || !mounted) return;

    // Fetch every app's schema in parallel. Cap concurrency implicitly
    // by relying on the shared Dio pool.
    final schemas = await Future.wait(
      apps.map((a) async {
        try {
          final s = await _svc.getSchema(a.appId);
          return MapEntry(a, s);
        } catch (_) {
          return MapEntry(a, CredentialSchema.empty);
        }
      }),
      eagerError: false,
    );

    final usage = <String, List<String>>{};
    for (final entry in schemas) {
      final app = entry.key;
      for (final p in entry.value.providers) {
        usage.putIfAbsent(p.name, () => []).add(app.name.isNotEmpty
            ? app.name
            : app.appId);
      }
    }
    if (!mounted) return;
    setState(() => _providerUsage = usage);
  }

  Map<String, List<UserCredentialEntry>> _groupByApp() {
    final out = <String, List<UserCredentialEntry>>{};
    for (final e in _entries) {
      out.putIfAbsent(e.appId, () => []).add(e);
    }
    return out;
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
        title: Text('My Credentials',
            style: GoogleFonts.inter(
                fontSize: 14,
                color: c.textBright,
                fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: Icon(Icons.refresh_rounded, size: 18, color: c.textMuted),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: c.textMuted),
              ),
            )
          : _error != null
              ? _buildError(c)
              : _buildList(c),
    );
  }

  Widget _buildError(AppColors c) {
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
              Text('Failed to load credentials',
                  style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: c.textBright)),
              const SizedBox(height: 6),
              Text(_error ?? '',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.firaCode(
                      fontSize: 11, color: c.textMuted, height: 1.5)),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _load,
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.surfaceAlt,
                  foregroundColor: c.text,
                  elevation: 0,
                  side: BorderSide(color: c.border),
                ),
                child: Text('Retry',
                    style: GoogleFonts.inter(fontSize: 12)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList(AppColors c) {
    if (_entries.isEmpty) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.key_off_rounded, size: 36, color: c.textMuted),
                const SizedBox(height: 12),
                Text('No credentials yet',
                    style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: c.textBright)),
                const SizedBox(height: 6),
                Text(
                  'When you open an app that needs credentials, you\'ll configure them there. They show up here afterwards.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                      fontSize: 11.5, color: c.textMuted, height: 1.5),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final grouped = _groupByApp();
    final globals = grouped.remove('_global') ?? const [];
    final appIds = grouped.keys.toList()..sort();

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (globals.isNotEmpty) ...[
                _SectionLabel(
                  icon: Icons.public_rounded,
                  label: 'GLOBAL · CROSS-APP',
                  count: globals.length,
                ),
                const SizedBox(height: 8),
                for (final e in globals)
                  _CredentialRow(
                    entry: e,
                    usedBy: _providerUsage[e.providerName] ?? const [],
                    onTap: () => _openUsage(e),
                  ),
                const SizedBox(height: 24),
              ],
              for (final appId in appIds) ...[
                _SectionLabel(
                  icon: Icons.apps_rounded,
                  label: appId.toUpperCase(),
                  count: grouped[appId]!.length,
                ),
                const SizedBox(height: 8),
                for (final e in grouped[appId]!)
                  _CredentialRow(
                    entry: e,
                    usedBy: const [],
                    onTap: () => _openApp(appId),
                  ),
                const SizedBox(height: 20),
              ],
              const SizedBox(height: 40),
            ],
          ),
        ),
      ],
    );
  }

  void _openApp(String appId) {
    // Route to the per-app form. `_global` credentials have no
    // per-app landing so we just ignore the tap for those.
    if (appId.isEmpty || appId == '_global') return;
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => CredentialsFormPage(appId: appId),
        ))
        .then((_) => _load());
  }

  /// Tapping a global credential needs a target app to edit against.
  /// When only one app references it we go straight there; when
  /// several do, we show a picker so the user chooses.
  void _openUsage(UserCredentialEntry e) {
    final usage = _providerUsage[e.providerName] ?? const [];
    if (usage.isEmpty) {
      // No known consumer — nothing to route to. Show a hint.
      final c = context.colors;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '${e.providerLabel} is stored globally but no app references it.'),
        backgroundColor: c.textMuted.withValues(alpha: 0.9),
        duration: const Duration(seconds: 3),
      ));
      return;
    }
    // Resolve label → AppSummary so we can get the real appId.
    final apps = _appsSvc.apps;
    final targets = apps
        .where((a) => usage.contains(a.name.isNotEmpty ? a.name : a.appId))
        .toList();
    if (targets.length == 1) {
      _openApp(targets.first.appId);
      return;
    }
    _showAppPicker(e.providerLabel, targets);
  }

  Future<void> _showAppPicker(
      String credLabel, List<AppSummary> targets) async {
    final c = context.colors;
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c.border),
        ),
        title: Text('Open $credLabel in which app?',
            style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: c.textBright)),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final t in targets)
                ListTile(
                  dense: true,
                  leading: Icon(Icons.apps_rounded, size: 16, color: c.text),
                  title: Text(t.name.isNotEmpty ? t.name : t.appId,
                      style: GoogleFonts.inter(
                          fontSize: 12.5, color: c.textBright)),
                  subtitle: Text(t.appId,
                      style: GoogleFonts.firaCode(
                          fontSize: 10, color: c.textMuted)),
                  onTap: () => Navigator.pop(ctx, t.appId),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null) _openApp(selected);
  }
}

class _SectionLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;
  const _SectionLabel({
    required this.icon,
    required this.label,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        Icon(icon, size: 13, color: c.textMuted),
        const SizedBox(width: 6),
        Text(
          label,
          style: GoogleFonts.firaCode(
            fontSize: 10.5,
            color: c.textMuted,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text('$count',
              style: GoogleFonts.firaCode(
                  fontSize: 9.5,
                  color: c.textMuted,
                  fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

class _CredentialRow extends StatefulWidget {
  final UserCredentialEntry entry;
  final VoidCallback onTap;
  final List<String> usedBy;
  const _CredentialRow({
    required this.entry,
    required this.onTap,
    this.usedBy = const [],
  });

  @override
  State<_CredentialRow> createState() => _CredentialRowState();
}

class _CredentialRowState extends State<_CredentialRow> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final e = widget.entry;
    final statusColor = _statusColor(c, e.status);
    final firstMasked = e.maskedFields.values
        .where((v) => v.isNotEmpty)
        .firstOrNull;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _h ? c.surfaceAlt : c.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _h ? c.borderHover : c.border),
            ),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: c.border),
                  ),
                  child: Icon(_icon(e), size: 14, color: c.text),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              e.providerLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                  fontSize: 12.5,
                                  color: c.textBright,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                                shape: BoxShape.circle, color: statusColor),
                          ),
                          const SizedBox(width: 4),
                          Text(e.status,
                              style: GoogleFonts.firaCode(
                                  fontSize: 9.5, color: statusColor)),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        firstMasked ?? '${e.type} · ${e.scope}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.firaCode(
                            fontSize: 10.5, color: c.textMuted),
                      ),
                      if (widget.usedBy.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Icon(Icons.apps_rounded,
                                size: 10, color: c.textMuted),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                'Used by ${_formatUsedBy(widget.usedBy)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(
                                  fontSize: 10,
                                  color: c.textMuted,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded,
                    size: 16, color: _h ? c.text : c.textDim),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _formatUsedBy(List<String> names) {
    if (names.length == 1) return names.first;
    if (names.length == 2) return '${names[0]} + ${names[1]}';
    return '${names.take(2).join(", ")} +${names.length - 2}';
  }

  static IconData _icon(UserCredentialEntry e) {
    switch (e.providerName.toLowerCase()) {
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
      default:
        if (e.type == 'oauth2') return Icons.link_rounded;
        if (e.type == 'mcp_server') return Icons.electrical_services_rounded;
        if (e.type == 'connection_string') return Icons.storage_rounded;
        return Icons.key_rounded;
    }
  }

  static Color _statusColor(AppColors c, String status) {
    switch (status) {
      case 'valid':
        return c.green;
      case 'filled':
        return c.blue;
      case 'expired':
        return c.orange;
      case 'invalid':
      case 'error':
        return c.red;
      case 'refreshing':
        return c.blue;
      default:
        return c.textMuted;
    }
  }
}
