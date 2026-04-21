/// Settings → Credentials — full manager screen for the unified
/// credential model. Lists every credential the user has, grouped
/// by provider, with row actions (edit, grants, delete) and a big
/// "Add credential" CTA.
///
/// Used by:
///  - Settings shell (replaces the old per-app credentials section)
///  - Command palette ("My credentials")
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/credential_v2.dart';
import '../../services/apps_service.dart';
import '../../services/auth_service.dart';
import '../../services/credentials_v2_service.dart';
import '../../theme/app_theme.dart';
import '../chat/chat_bubbles.dart' show showToast;
import 'credential_field_form.dart';
import 'credential_form_dialog.dart';
import 'system_credentials_dialog.dart';

class CredentialsManagerPage extends StatefulWidget {
  /// When true the page is rendered without its own Scaffold so it
  /// can be embedded inside the Settings shell (which already has
  /// the sidebar). Routes that push it stand-alone leave this false.
  final bool embedded;
  const CredentialsManagerPage({super.key, this.embedded = false});

  @override
  State<CredentialsManagerPage> createState() => _CredentialsManagerPageState();
}

class _CredentialsManagerPageState extends State<CredentialsManagerPage> {
  final _svc = CredentialsV2Service();
  bool _loading = true;
  String? _error;
  List<CredentialV2> _items = const [];

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
      final list = await _svc.list();
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
    } on CredV2Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  Map<String, List<CredentialV2>> _groupByProvider() {
    final out = <String, List<CredentialV2>>{};
    for (final c in _items) {
      out.putIfAbsent(c.providerName, () => []).add(c);
    }
    return out;
  }

  Future<void> _addCredential() async {
    final created = await showCredentialFormDialog(context);
    // Always refresh — even if `created` is null the OAuth flow may
    // have dropped a new credential into the vault via its callback.
    if (mounted) _load();
    if (created != null && mounted) {
      _toast('${created.displayProviderLabel} credential added');
    }
  }

  Future<void> _editCredential(CredentialV2 cred) async {
    final saved = await showDialog<CredentialV2>(
      context: context,
      builder: (_) => _EditCredentialDialog(credential: cred),
    );
    if (saved != null) _load();
  }

  Future<void> _deleteCredential(CredentialV2 cred) async {
    final c = context.colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c.border),
        ),
        title: Text(
            'credentials.delete_title_of'
                .tr(namedArgs: {'name': cred.label}),
            style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: c.textBright)),
        content: Text(
          'credentials.delete_body_long'.tr(),
          style: GoogleFonts.inter(
              fontSize: 12, color: c.text, height: 1.5),
        ),
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
            child: Text('credentials.delete'.tr(),
                style: GoogleFonts.inter(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _svc.delete(cred.id);
      _load();
    } on CredV2Exception catch (e) {
      if (mounted) _toast(e.message, err: true);
    }
  }

  Future<void> _showGrants(CredentialV2 cred) async {
    await showDialog(
      context: context,
      builder: (_) => _GrantsDialog(credential: cred),
    );
    _load();
  }

  void _toast(String msg, {bool err = false}) {
    if (!mounted) return;
    final c = context.colors;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor:
          (err ? c.red : c.green).withValues(alpha: 0.9),
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final body = _loading
        ? Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: c.textMuted),
            ),
          )
        : _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline_rounded,
                          size: 36, color: c.red),
                      const SizedBox(height: 12),
                      Text('credentials.load_failed'.tr(),
                          style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: c.textBright)),
                      const SizedBox(height: 6),
                      Text(_error!,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.firaCode(
                              fontSize: 11,
                              color: c.textMuted,
                              height: 1.5)),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _load,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: c.surfaceAlt,
                          foregroundColor: c.text,
                          elevation: 0,
                          side: BorderSide(color: c.border),
                        ),
                        child: Text('credentials.refresh'.tr(),
                            style: GoogleFonts.inter(fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              )
            : _buildList(c);

    if (widget.embedded) return body;
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.surface,
        elevation: 0,
        foregroundColor: c.text,
        title: Text('credentials.title'.tr(),
            style: GoogleFonts.inter(
                fontSize: 14,
                color: c.textBright,
                fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh_rounded, size: 18, color: c.textMuted),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _buildList(AppColors c) {
    final groups = _groupByProvider();
    final providers = groups.keys.toList()..sort();
    return LayoutBuilder(builder: (ctx, constraints) {
      final narrow = constraints.maxWidth < 600;
      final hPad = narrow ? 16.0 : 40.0;
      final vPad = narrow ? 18.0 : 32.0;
      final titleSize = narrow ? 20.0 : 24.0;
      final subtitleSize = narrow ? 12.0 : 13.5;

      final titleBlock = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('credentials.title'.tr(),
              style: GoogleFonts.inter(
                fontSize: titleSize,
                fontWeight: FontWeight.w700,
                color: c.textBright,
              )),
          const SizedBox(height: 5),
          Text(
            'credentials.subtitle_long'.tr(),
            style: GoogleFonts.inter(
              fontSize: subtitleSize,
              color: c.textMuted,
              height: 1.5,
            ),
          ),
        ],
      );

      final actionsRow = Row(
        mainAxisAlignment:
            narrow ? MainAxisAlignment.start : MainAxisAlignment.end,
        children: [
          if (AuthService().currentUser?.isAdmin == true) ...[
            OutlinedButton.icon(
              onPressed: () => SystemCredentialsDialog.show(context),
              icon: Icon(Icons.shield_outlined, size: 14, color: c.purple),
              label: Text('credentials.system'.tr(),
                  style:
                      GoogleFonts.inter(fontSize: 12, color: c.purple)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: c.purple.withValues(alpha: 0.4)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
            const SizedBox(width: 8),
          ],
          ElevatedButton.icon(
            onPressed: _addCredential,
            icon: const Icon(Icons.add_rounded,
                size: 16, color: Colors.white),
            label: Text(
              narrow ? 'credentials.add_short'.tr() : 'credentials.add'.tr(),
              style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.white),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: c.blue,
              elevation: 0,
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(7)),
            ),
          ),
        ],
      );

      return ListView(
        padding: EdgeInsets.fromLTRB(hPad, vPad, hPad, 48),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (narrow) ...[
                  titleBlock,
                  const SizedBox(height: 14),
                  actionsRow,
                ] else
                  Row(
                    children: [
                      Expanded(child: titleBlock),
                      const SizedBox(width: 12),
                      actionsRow,
                    ],
                  ),
                const SizedBox(height: 28),
              if (_items.isEmpty) _buildEmptyState(c),
              for (final provider in providers) ...[
                _buildGroupHeader(c, provider, groups[provider]!.length),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: c.border),
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < groups[provider]!.length; i++) ...[
                        _CredentialRow(
                          credential: groups[provider]![i],
                          onEdit: () => _editCredential(groups[provider]![i]),
                          onGrants: () => _showGrants(groups[provider]![i]),
                          onDelete: () =>
                              _deleteCredential(groups[provider]![i]),
                        ),
                        if (i < groups[provider]!.length - 1)
                          Divider(height: 1, color: c.border),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 18),
              ],
              ],
              ),
            ),
          ],
        );
    });
  }

  Widget _buildEmptyState(AppColors c) {
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
            Icon(Icons.key_off_outlined, size: 36, color: c.textMuted),
            const SizedBox(height: 12),
            Text('credentials.no_credentials'.tr(),
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: c.textBright,
                )),
            const SizedBox(height: 6),
            Text(
              'credentials.no_credentials_hint_long'.tr(),
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                  fontSize: 11.5, color: c.textMuted, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupHeader(AppColors c, String provider, int count) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 2),
      child: Row(
        children: [
          Icon(_iconFor(provider), size: 14, color: c.text),
          const SizedBox(width: 8),
          Text(
            _humanise(provider).toUpperCase(),
            style: GoogleFonts.firaCode(
              fontSize: 10.5,
              color: c.textMuted,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(width: 6),
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
      ),
    );
  }

  static IconData _iconFor(String provider) {
    for (final entry in CredentialsV2Service.catalogue) {
      if (entry.name == provider) return entry.icon;
    }
    return Icons.key_rounded;
  }
}

String _humanise(String snake) {
  if (snake.isEmpty) return '';
  return snake
      .split(RegExp(r'[_\-]'))
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

// ─── Row ──────────────────────────────────────────────────────────

class _CredentialRow extends StatefulWidget {
  final CredentialV2 credential;
  final VoidCallback onEdit;
  final VoidCallback onGrants;
  final VoidCallback onDelete;
  const _CredentialRow({
    required this.credential,
    required this.onEdit,
    required this.onGrants,
    required this.onDelete,
  });

  @override
  State<_CredentialRow> createState() => _CredentialRowState();
}

class _CredentialRowState extends State<_CredentialRow> {
  bool _h = false;

  /// Live MCP status for this credential, refreshed on demand.
  /// Null until the first probe comes back; then a map with keys
  /// `running`, `status`, `tools_count`, `last_error`, `provider`.
  Map<String, dynamic>? _mcp;
  bool _mcpBusy = false;
  String? _resolvedAppId;

  @override
  void initState() {
    super.initState();
    if (widget.credential.providerType == 'mcp_server') {
      _primeMcp();
    }
  }

  /// Resolve which app id to use for MCP ops and fetch the current
  /// status once. If the credential has no grant, we leave
  /// [_resolvedAppId] null and the user sees a hint instead of
  /// broken buttons.
  Future<void> _primeMcp() async {
    final grants = await CredentialsV2Service()
        .listGrants(widget.credential.id)
        .catchError((_) => <CredentialGrant>[]);
    if (!mounted) return;
    final appId = grants.isEmpty ? null : grants.first.appId;
    setState(() => _resolvedAppId = appId);
    if (appId == null) return;
    final snap = await CredentialsV2Service()
        .statusMcp(appId, widget.credential.providerName);
    if (!mounted) return;
    setState(() => _mcp = snap);
  }

  Future<void> _mcpStart() async {
    final appId = _resolvedAppId;
    if (appId == null) return;
    setState(() => _mcpBusy = true);
    await CredentialsV2Service()
        .startMcp(appId, widget.credential.providerName);
    final snap = await CredentialsV2Service()
        .statusMcp(appId, widget.credential.providerName);
    if (!mounted) return;
    setState(() {
      _mcp = snap;
      _mcpBusy = false;
    });
    showToast(context, 'MCP start requested');
  }

  Future<void> _mcpStop() async {
    final appId = _resolvedAppId;
    if (appId == null) return;
    setState(() => _mcpBusy = true);
    await CredentialsV2Service()
        .stopMcp(appId, widget.credential.providerName);
    final snap = await CredentialsV2Service()
        .statusMcp(appId, widget.credential.providerName);
    if (!mounted) return;
    setState(() {
      _mcp = snap;
      _mcpBusy = false;
    });
    showToast(context, 'MCP stopped');
  }

  Future<void> _mcpRefresh() async {
    final appId = _resolvedAppId;
    if (appId == null) return;
    setState(() => _mcpBusy = true);
    final snap = await CredentialsV2Service()
        .statusMcp(appId, widget.credential.providerName);
    if (!mounted) return;
    setState(() {
      _mcp = snap;
      _mcpBusy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cred = widget.credential;
    final tint = _statusColor(c, cred.status);
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        color: _h ? c.surfaceAlt : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildMainRow(context, c, tint),
            if (cred.providerType == 'mcp_server')
              _buildMcpPanel(context, c),
          ],
        ),
      ),
    );
  }

  Widget _buildMainRow(BuildContext context, AppColors c, Color tint) {
    final cred = widget.credential;
    final masked = cred.firstMaskedPreview ?? cred.label;
    return Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
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
                          cred.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: c.textBright),
                        ),
                      ),
                      if (cred.isSystem) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: c.purple.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(
                                color: c.purple.withValues(alpha: 0.35)),
                          ),
                          child: Text('credentials.system_label'.tr(),
                              style: GoogleFonts.firaCode(
                                  fontSize: 8,
                                  color: c.purple,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    masked,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.firaCode(
                        fontSize: 11, color: c.textMuted),
                  ),
                  if (cred.isOauth && cred.oauthAccount != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      cred.oauthAccount!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.firaCode(
                          fontSize: 10.5, color: c.textMuted),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            PopupMenuButton<String>(
              tooltip: 'credentials.actions'.tr(),
              icon: Icon(Icons.more_horiz_rounded,
                  size: 18, color: c.textMuted),
              onSelected: (v) {
                if (v == 'edit') widget.onEdit();
                if (v == 'grants') widget.onGrants();
                if (v == 'delete') widget.onDelete();
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'grants',
                  height: 32,
                  child: Row(children: [
                    Icon(Icons.apps_rounded, size: 13, color: c.text),
                    const SizedBox(width: 8),
                    Text('credentials.grants'.tr(),
                        style:
                            GoogleFonts.inter(fontSize: 12, color: c.text)),
                  ]),
                ),
                if (!cred.isSystem)
                  PopupMenuItem(
                    value: 'edit',
                    height: 32,
                    child: Row(children: [
                      Icon(Icons.edit_outlined, size: 13, color: c.text),
                      const SizedBox(width: 8),
                      Text('credentials.edit'.tr(),
                          style:
                              GoogleFonts.inter(fontSize: 12, color: c.text)),
                    ]),
                  ),
                if (!cred.isSystem)
                  PopupMenuItem(
                    value: 'delete',
                    height: 32,
                    child: Row(children: [
                      Icon(Icons.delete_outline_rounded,
                          size: 13, color: c.red),
                      const SizedBox(width: 8),
                      Text('credentials.delete'.tr(),
                          style:
                              GoogleFonts.inter(fontSize: 12, color: c.red)),
                    ]),
                  ),
              ],
            ),
          ],
        );
  }

  /// Inline MCP controls shown below the main row for credentials
  /// whose providerType is `mcp_server`. Binds to the user's own
  /// credential (via `/api/users/me/credentials/...`), never to an
  /// admin-scope token — the OAuth value never leaves the user's
  /// vault.
  Widget _buildMcpPanel(BuildContext context, AppColors c) {
    final appId = _resolvedAppId;
    if (appId == null) {
      return Container(
        margin: const EdgeInsets.only(left: 20, top: 10, right: 8),
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: c.surfaceAlt.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline_rounded, size: 13, color: c.textDim),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Grant this credential to an app to enable MCP '
                'start / stop / status controls.',
                style:
                    GoogleFonts.inter(fontSize: 11, color: c.textMuted),
              ),
            ),
          ],
        ),
      );
    }
    final mcp = _mcp;
    final running = mcp?['running'] == true;
    final status = (mcp?['status'] ?? (running ? 'running' : 'stopped'))
        .toString();
    final toolsCount = mcp?['tools_count'] as int?;
    final lastError = (mcp?['last_error'] ?? '').toString();
    final tint = running ? c.green : c.textDim;
    return Container(
      margin: const EdgeInsets.only(left: 20, top: 10, right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.electrical_services_rounded,
                  size: 14, color: tint),
              const SizedBox(width: 8),
              Text('MCP',
                  style: GoogleFonts.firaCode(
                      fontSize: 10,
                      color: c.textMuted,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8)),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(3),
                  border:
                      Border.all(color: tint.withValues(alpha: 0.35)),
                ),
                child: Text(
                  status.toUpperCase(),
                  style: GoogleFonts.firaCode(
                      fontSize: 9,
                      color: tint,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4),
                ),
              ),
              if (toolsCount != null) ...[
                const SizedBox(width: 8),
                Text('$toolsCount tool${toolsCount == 1 ? '' : 's'}',
                    style: GoogleFonts.firaCode(
                        fontSize: 10, color: c.textDim)),
              ],
              const Spacer(),
              if (_mcpBusy)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                )
              else ...[
                IconButton(
                  tooltip: 'Refresh',
                  iconSize: 13,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                      minWidth: 26, minHeight: 26),
                  onPressed: _mcpRefresh,
                  icon: Icon(Icons.refresh_rounded, color: c.textMuted),
                ),
                if (running)
                  TextButton.icon(
                    onPressed: _mcpStop,
                    icon: const Icon(Icons.stop_rounded, size: 12),
                    label: const Text('Stop'),
                    style: TextButton.styleFrom(
                      foregroundColor: c.red,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                    ),
                  )
                else
                  TextButton.icon(
                    onPressed: _mcpStart,
                    icon:
                        const Icon(Icons.play_arrow_rounded, size: 12),
                    label: const Text('Start'),
                    style: TextButton.styleFrom(
                      foregroundColor: c.green,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                    ),
                  ),
              ],
            ],
          ),
          if (lastError.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              lastError,
              style:
                  GoogleFonts.firaCode(fontSize: 10, color: c.red),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  static Color _statusColor(AppColors c, String status) {
    switch (status) {
      case 'valid':
      case 'filled':
        return c.green;
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

// ─── Provider picker sheet (called from "Add credential") ─────────

class _ProviderPickerSheet extends StatefulWidget {
  const _ProviderPickerSheet();

  @override
  State<_ProviderPickerSheet> createState() => _ProviderPickerSheetState();
}

class _ProviderPickerSheetState extends State<_ProviderPickerSheet> {
  ProviderCatalogueEntry? _picked;
  String _query = '';
  List<ProviderCatalogueEntry> _providers =
      CredentialsV2Service().cachedProviders;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadProviders();
  }

  Future<void> _loadProviders() async {
    setState(() => _loading = true);
    final list = await CredentialsV2Service().loadProviders();
    if (!mounted) return;
    setState(() {
      _providers = list;
      _loading = false;
    });
  }

  List<ProviderCatalogueEntry> get _filtered {
    if (_query.isEmpty) return _providers;
    final q = _query.toLowerCase();
    return _providers
        .where((p) =>
            p.label.toLowerCase().contains(q) ||
            p.name.toLowerCase().contains(q) ||
            p.type.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Container(
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(16)),
            border: Border.all(color: c.border),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(
                      _picked == null
                          ? 'credentials.pick_provider'.tr()
                          : 'credentials.new_credential_of'.tr(
                              namedArgs: {'provider': _picked!.label}),
                      style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: c.textBright),
                    ),
                    const Spacer(),
                    IconButton(
                      iconSize: 18,
                      icon: Icon(Icons.close_rounded, color: c.textMuted),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_picked == null) ...[
                  // Search bar
                  Container(
                    height: 38,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: c.surfaceAlt,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: c.border),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.search_rounded,
                            size: 14, color: c.textMuted),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            onChanged: (v) =>
                                setState(() => _query = v.trim()),
                            style: GoogleFonts.inter(
                                fontSize: 12, color: c.textBright),
                            decoration: InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              hintText: 'credentials.search_providers'.tr(),
                              hintStyle: GoogleFonts.inter(
                                  fontSize: 12, color: c.textMuted),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 380),
                    child: _loading && _providers.isEmpty
                        ? Center(
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                  color: c.textMuted),
                            ),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            itemCount: _filtered.length,
                            separatorBuilder: (_, _) =>
                                Divider(height: 1, color: c.border),
                            itemBuilder: (_, i) {
                              final entry = _filtered[i];
                              return ListTile(
                                leading: Container(
                                  width: 32,
                                  height: 32,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: c.surfaceAlt,
                                    borderRadius:
                                        BorderRadius.circular(7),
                                    border:
                                        Border.all(color: c.border),
                                  ),
                                  child: Icon(entry.icon,
                                      size: 16, color: c.text),
                                ),
                                title: Text(entry.label,
                                    style: GoogleFonts.inter(
                                        fontSize: 13,
                                        color: c.textBright,
                                        fontWeight: FontWeight.w600)),
                                subtitle: Text(
                                  entry.type,
                                  style: GoogleFonts.firaCode(
                                      fontSize: 10,
                                      color: c.textMuted),
                                ),
                                trailing: entry.docsUrl != null
                                    ? Icon(Icons.open_in_new_rounded,
                                        size: 13, color: c.textDim)
                                    : null,
                                onTap: () =>
                                    setState(() => _picked = entry),
                              );
                            },
                          ),
                  ),
                ] else
                  _CreateForm(
                    entry: _picked!,
                    onCancel: () => setState(() => _picked = null),
                    onCreated: (cred) => Navigator.pop(context, cred),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CreateForm extends StatefulWidget {
  final ProviderCatalogueEntry entry;
  final VoidCallback onCancel;
  final void Function(CredentialV2) onCreated;
  const _CreateForm({
    required this.entry,
    required this.onCancel,
    required this.onCreated,
  });

  @override
  State<_CreateForm> createState() => _CreateFormState();
}

class _CreateFormState extends State<_CreateForm> {
  final _labelCtrl = TextEditingController(text: 'default');
  Map<String, String> _values = const {};
  bool _valid = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _labelCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final cred = await CredentialsV2Service().create(
        providerName: widget.entry.name,
        providerType: widget.entry.type,
        label: _labelCtrl.text.trim().isEmpty
            ? 'default'
            : _labelCtrl.text.trim(),
        fields: _values,
      );
      widget.onCreated(cred);
    } on CredV2Exception catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isOauth = widget.entry.type == 'oauth2';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isOauth)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(
              'credentials.oauth_hint'
                  .tr(namedArgs: {'name': widget.entry.label}),
              style: GoogleFonts.inter(
                  fontSize: 12, color: c.text, height: 1.5),
            ),
          )
        else ...[
          const SizedBox(height: 10),
          Text('credentials.label'.tr(),
              style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: c.textBright)),
          const SizedBox(height: 4),
          TextField(
            controller: _labelCtrl,
            style: GoogleFonts.inter(fontSize: 12, color: c.text),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: c.bg,
              hintText: 'personal, work, …',
              hintStyle:
                  GoogleFonts.inter(fontSize: 12, color: c.textDim),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: c.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: c.border),
              ),
            ),
          ),
          const SizedBox(height: 14),
          CredentialFieldForm(
            fields: widget.entry.fields,
            onChanged: (v, valid) {
              _values = v;
              _valid = valid;
              if (mounted) setState(() {});
            },
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text('⚠ $_error',
              style: GoogleFonts.firaCode(fontSize: 11, color: c.red)),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            TextButton(
              onPressed: _saving ? null : widget.onCancel,
              child: Text('admin.back'.tr(),
                  style:
                      GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
            ),
            const Spacer(),
            if (!isOauth)
              ElevatedButton(
                onPressed: _saving || !_valid ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.blue,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                            strokeWidth: 1.5, color: Colors.white),
                      )
                    : Text('credentials.create'.tr(),
                        style: GoogleFonts.inter(
                            fontSize: 12, fontWeight: FontWeight.w600)),
              ),
          ],
        ),
      ],
    );
  }
}

// ─── Edit credential dialog ───────────────────────────────────────

class _EditCredentialDialog extends StatefulWidget {
  final CredentialV2 credential;
  const _EditCredentialDialog({required this.credential});

  @override
  State<_EditCredentialDialog> createState() => _EditCredentialDialogState();
}

class _EditCredentialDialogState extends State<_EditCredentialDialog> {
  late final _labelCtrl =
      TextEditingController(text: widget.credential.label);
  Map<String, String> _values = const {};
  bool _saving = false;
  String? _error;

  ProviderCatalogueEntry? get _entry {
    for (final e in CredentialsV2Service.catalogue) {
      if (e.name == widget.credential.providerName) return e;
    }
    return null;
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await CredentialsV2Service().update(
        widget.credential.id,
        label: _labelCtrl.text.trim(),
        fields: _values.isEmpty ? null : _values,
      );
      if (mounted) Navigator.pop(context, widget.credential);
    } on CredV2Exception catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final entry = _entry;
    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                  'credentials.edit_credential_of'.tr(namedArgs: {
                    'provider': widget.credential.displayProviderLabel
                  }),
                  style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: c.textBright)),
              const SizedBox(height: 14),
              Text('credentials.label'.tr(),
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: c.textBright)),
              const SizedBox(height: 4),
              TextField(
                controller: _labelCtrl,
                style: GoogleFonts.inter(fontSize: 12, color: c.text),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: c.bg,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(color: c.border)),
                ),
              ),
              const SizedBox(height: 14),
              if (entry != null && entry.fields.isNotEmpty) ...[
                Text('credentials.update_fields_hint'.tr(),
                    style: GoogleFonts.firaCode(
                      fontSize: 9.5,
                      color: c.textMuted,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    )),
                const SizedBox(height: 8),
                CredentialFieldForm(
                  fields: entry.fields,
                  onChanged: (v, _) => _values = v,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 4),
                Text('⚠ $_error',
                    style:
                        GoogleFonts.firaCode(fontSize: 11, color: c.red)),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: Text('credentials.cancel'.tr(),
                        style: GoogleFonts.inter(
                            fontSize: 12, color: c.textMuted)),
                  ),
                  const Spacer(),
                  ElevatedButton(
                    onPressed: _saving ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: c.blue,
                      foregroundColor: Colors.white,
                      elevation: 0,
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
      ),
    );
  }
}

// ─── Grants dialog ─────────────────────────────────────────────────

class _GrantsDialog extends StatefulWidget {
  final CredentialV2 credential;
  const _GrantsDialog({required this.credential});

  @override
  State<_GrantsDialog> createState() => _GrantsDialogState();
}

class _GrantsDialogState extends State<_GrantsDialog> {
  bool _loading = true;
  List<CredentialGrant> _grants = const [];
  String? _error;

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
      final list = await CredentialsV2Service()
          .listGrants(widget.credential.id);
      if (!mounted) return;
      setState(() {
        _grants = list;
        _loading = false;
      });
    } on CredV2Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  Future<void> _revoke(CredentialGrant grant) async {
    try {
      await CredentialsV2Service().revoke(
        credentialId: widget.credential.id,
        appId: grant.appId,
      );
      _load();
    } on CredV2Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    }
  }

  String _appName(String appId) {
    for (final a in AppsService().apps) {
      if (a.appId == appId) return a.name;
    }
    return appId;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 480),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'credentials.grants_of'.tr(
                          namedArgs: {'name': widget.credential.label}),
                      style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: c.textBright),
                    ),
                  ),
                  IconButton(
                    iconSize: 16,
                    icon: Icon(Icons.close_rounded, color: c.textMuted),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'credentials.grants_subtitle'.tr(),
                style: GoogleFonts.inter(
                    fontSize: 11.5, color: c.textMuted, height: 1.5),
              ),
              const SizedBox(height: 14),
              if (_loading)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 30),
                  child: Center(
                      child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 1.5, color: c.textMuted))),
                )
              else if (_error != null)
                Text(_error!,
                    style:
                        GoogleFonts.firaCode(fontSize: 11, color: c.red))
              else if (_grants.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text('credentials.grants_empty'.tr(),
                        style: GoogleFonts.inter(
                            fontSize: 12, color: c.textMuted)),
                  ),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _grants.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: c.border),
                    itemBuilder: (_, i) {
                      final g = _grants[i];
                      return ListTile(
                        dense: true,
                        leading: Icon(Icons.apps_rounded,
                            size: 16, color: c.text),
                        title: Text(_appName(g.appId),
                            style: GoogleFonts.inter(
                                fontSize: 13, color: c.textBright)),
                        subtitle: Text(g.appId,
                            style: GoogleFonts.firaCode(
                                fontSize: 10, color: c.textMuted)),
                        trailing: TextButton.icon(
                          onPressed: () => _revoke(g),
                          icon: Icon(Icons.block_rounded,
                              size: 13, color: c.red),
                          label: Text('credentials.revoke'.tr(),
                              style: GoogleFonts.inter(
                                  fontSize: 11, color: c.red)),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
