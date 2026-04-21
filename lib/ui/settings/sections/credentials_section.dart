/// "Credentials" section in Settings — a workspace-wide view of every
/// credential the user has configured, grouped by scope, with a
/// cross-reference to the apps that consume each one. Tapping a row
/// opens the relevant per-app credentials form.
///
/// This is a richer take on the standalone `MyCredentialsPage`: same
/// data source (`CredentialService.listMine` + per-app schemas) but
/// with summary tiles at the top (configured, missing, OAuth
/// connected, MCP running) and consumer cross-ref baked into every
/// row instead of only the global ones.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../models/app_summary.dart';
import '../../../models/credential_schema.dart';
import '../../../services/apps_service.dart';
import '../../../services/credential_service.dart';
import '../../../theme/app_theme.dart';
import '../../credentials/credentials_form.dart';
import '_shared.dart';

class CredentialsSection extends StatefulWidget {
  const CredentialsSection({super.key});

  @override
  State<CredentialsSection> createState() => _CredentialsSectionState();
}

class _CredentialsSectionState extends State<CredentialsSection> {
  final _credSvc = CredentialService();
  final _appsSvc = AppsService();

  bool _loading = true;
  String? _error;
  List<UserCredentialEntry> _entries = const [];
  Map<String, List<AppSummary>> _consumers = const {};
  Map<String, CredentialSchema> _schemas = const {};

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
      if (_appsSvc.apps.isEmpty) {
        await _appsSvc.refresh();
      }
      final entries = await _credSvc.listMine();
      // Fetch every app's schema so we can cross-ref consumers AND
      // populate the per-app section even when the user hasn't
      // configured anything yet for an app that needs credentials.
      final schemaResults = await Future.wait(
        _appsSvc.apps.map((a) async {
          try {
            return MapEntry(a.appId, await _credSvc.getSchema(a.appId));
          } catch (_) {
            return MapEntry(a.appId, CredentialSchema.empty);
          }
        }),
        eagerError: false,
      );
      final schemas = <String, CredentialSchema>{
        for (final e in schemaResults) e.key: e.value,
      };

      // providerName → [AppSummary] index from the schemas.
      final consumers = <String, List<AppSummary>>{};
      for (final app in _appsSvc.apps) {
        final s = schemas[app.appId];
        if (s == null) continue;
        for (final p in s.providers) {
          consumers.putIfAbsent(p.name, () => []).add(app);
        }
      }

      if (!mounted) return;
      setState(() {
        _entries = entries;
        _schemas = schemas;
        _consumers = consumers;
        _loading = false;
      });
    } on CredentialException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  // ── Computed summaries for the header tiles ─────────────────────

  int get _configuredCount => _entries.where((e) => e.filled).length;

  int get _missingCount {
    var total = 0;
    for (final s in _schemas.values) {
      total += s.requiredMissingCount;
    }
    return total;
  }

  int get _oauthConnectedCount =>
      _entries.where((e) => e.type == 'oauth2' && e.status == 'valid').length;

  int get _appsNeedingCount =>
      _schemas.values.where((s) => s.hasProviders).length;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SectionScaffold(
      title: 'Credentials',
      subtitle:
          'Every secret, OAuth token, and MCP server you\'ve configured. Tap any row to manage it inside its app.',
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: Icon(Icons.refresh_rounded, size: 18, color: c.textMuted),
          onPressed: _loading ? null : _load,
        ),
      ],
      children: [
        if (_loading) _buildLoading(c),
        if (!_loading && _error != null) _buildError(c),
        if (!_loading && _error == null) ...[
          _buildHeaderTiles(c),
          const SizedBox(height: 28),
          _buildConfiguredList(c),
          const SizedBox(height: 28),
          _buildAppsNeeding(c),
        ],
      ],
    );
  }

  Widget _buildLoading(AppColors c) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 60),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 1.5, color: c.textMuted),
          ),
        ),
      );

  Widget _buildError(AppColors c) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Text(_error ?? 'Unknown error',
              style:
                  GoogleFonts.firaCode(fontSize: 11, color: c.textMuted)),
        ),
      );

  Widget _buildHeaderTiles(AppColors c) {
    return Row(
      children: [
        Expanded(
          child: StatTile(
            label: 'CONFIGURED',
            value: '$_configuredCount',
            subValue: '${_entries.length} total entries',
            icon: Icons.check_circle_outline_rounded,
            tint: c.green,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: StatTile(
            label: 'MISSING',
            value: '$_missingCount',
            subValue:
                _missingCount == 0 ? 'all set' : 'across your apps',
            icon: Icons.error_outline_rounded,
            tint: _missingCount == 0 ? c.textMuted : c.red,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: StatTile(
            label: 'OAUTH ACTIVE',
            value: '$_oauthConnectedCount',
            subValue: 'tokens currently valid',
            icon: Icons.link_rounded,
            tint: c.purple,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: StatTile(
            label: 'APPS NEEDING',
            value: '$_appsNeedingCount',
            subValue: 'declare a credentials_schema',
            icon: Icons.apps_rounded,
            tint: c.accentPrimary,
          ),
        ),
      ],
    );
  }

  Widget _buildConfiguredList(AppColors c) {
    if (_entries.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.border),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.key_off_outlined, size: 32, color: c.textMuted),
              const SizedBox(height: 10),
              Text(
                'No credentials configured yet',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: c.textBright,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Open any app that needs secrets to set them up.',
                style: GoogleFonts.inter(fontSize: 11.5, color: c.textMuted),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
            child: Row(
              children: [
                Text(
                  'CONFIGURED',
                  style: GoogleFonts.firaCode(
                    fontSize: 10,
                    color: c.textMuted,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
                const Spacer(),
                Text(
                  '${_entries.length} entries',
                  style: GoogleFonts.firaCode(
                      fontSize: 10, color: c.textMuted),
                ),
              ],
            ),
          ),
          for (final e in _entries)
            _CredentialRow(
              entry: e,
              consumers: _consumers[e.providerName] ?? const [],
              onTap: () => _openApp(e.appId.isEmpty ? '_global' : e.appId),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildAppsNeeding(AppColors c) {
    final apps = _schemas.entries
        .where((e) => e.value.hasProviders)
        .toList()
      ..sort((a, b) {
        // Apps with missing required first.
        return b.value.requiredMissingCount.compareTo(a.value.requiredMissingCount);
      });
    if (apps.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
            child: Text(
              'APPS REQUIRING CREDENTIALS',
              style: GoogleFonts.firaCode(
                fontSize: 10,
                color: c.textMuted,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
          ),
          for (final entry in apps)
            _AppNeedingRow(
              appId: entry.key,
              schema: entry.value,
              app: _appsSvc.apps.firstWhere(
                (a) => a.appId == entry.key,
                orElse: () => AppSummary(
                  appId: entry.key,
                  name: entry.key,
                  version: '',
                  mode: '',
                  agents: const [],
                  modules: const [],
                  totalTools: 0,
                  totalCategories: 0,
                  workspaceMode: 'auto',
                  greeting: '',
                ),
              ),
              onTap: () => _openApp(entry.key),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  void _openApp(String appId) {
    if (appId == '_global') return;
    final app = _appsSvc.apps.firstWhere(
      (a) => a.appId == appId,
      orElse: () => AppSummary(
        appId: appId,
        name: appId,
        version: '',
        mode: '',
        agents: const [],
        modules: const [],
        totalTools: 0,
        totalCategories: 0,
        workspaceMode: 'auto',
        greeting: '',
      ),
    );
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => CredentialsFormPage(
            appId: appId,
            appName: app.name,
          ),
        ))
        .then((_) => _load());
  }
}

class _CredentialRow extends StatefulWidget {
  final UserCredentialEntry entry;
  final List<AppSummary> consumers;
  final VoidCallback onTap;
  const _CredentialRow({
    required this.entry,
    required this.consumers,
    required this.onTap,
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
    final tint = _statusColor(c, e.status);
    final masked = e.maskedFields.values.where((v) => v.isNotEmpty).firstOrNull;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          color: _h ? c.surfaceAlt : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
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
                child: Icon(_iconFor(e), size: 14, color: c.text),
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
                            e.providerLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              color: c.textBright,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: tint.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(
                                color: tint.withValues(alpha: 0.35)),
                          ),
                          child: Text(
                            e.status.toUpperCase(),
                            style: GoogleFonts.firaCode(
                              fontSize: 8.5,
                              color: tint,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      masked ?? '${e.type} · ${e.scope}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.firaCode(
                          fontSize: 10.5, color: c.textMuted),
                    ),
                    if (widget.consumers.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 4,
                        runSpacing: 3,
                        children: [
                          for (final a in widget.consumers.take(4))
                            _ConsumerChip(name: a.name),
                          if (widget.consumers.length > 4)
                            _ConsumerChip(
                                name:
                                    '+${widget.consumers.length - 4}'),
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
    );
  }

  static IconData _iconFor(UserCredentialEntry e) {
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
        return c.accentPrimary;
      case 'expired':
        return c.orange;
      case 'invalid':
      case 'error':
        return c.red;
      default:
        return c.textMuted;
    }
  }
}

class _ConsumerChip extends StatelessWidget {
  final String name;
  const _ConsumerChip({required this.name});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: c.border),
      ),
      child: Text(
        name,
        style: GoogleFonts.firaCode(
          fontSize: 9.5,
          color: c.textMuted,
        ),
      ),
    );
  }
}

class _AppNeedingRow extends StatefulWidget {
  final String appId;
  final AppSummary app;
  final CredentialSchema schema;
  final VoidCallback onTap;
  const _AppNeedingRow({
    required this.appId,
    required this.app,
    required this.schema,
    required this.onTap,
  });

  @override
  State<_AppNeedingRow> createState() => _AppNeedingRowState();
}

class _AppNeedingRowState extends State<_AppNeedingRow> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final missing = widget.schema.requiredMissingCount;
    final tint = missing > 0 ? c.red : c.green;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          color: _h ? c.surfaceAlt : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: tint.withValues(alpha: 0.35)),
                ),
                child: Text(
                  widget.app.icon.isNotEmpty ? widget.app.icon : '🔌',
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.app.name,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.textBright,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      missing > 0
                          ? '$missing required credential${missing == 1 ? '' : 's'} missing'
                          : 'All credentials configured',
                      style: GoogleFonts.firaCode(
                        fontSize: 10.5,
                        color: tint,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 16, color: _h ? c.text : c.textDim),
            ],
          ),
        ),
      ),
    );
  }
}
