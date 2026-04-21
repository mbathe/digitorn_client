/// Admin → System credentials. Workspace-shared API keys / OAuth
/// tokens that every user can reach without configuring their own.
/// Backed by `/api/admin/credentials`.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../models/credential_v2.dart';
import '../../../services/credentials_v2_service.dart';
import '../../../theme/app_theme.dart';
import '../../common/themed_dialogs.dart';
import '../../credentials_v2/credential_form_dialog.dart';
import '_section_scaffold.dart';

class AdminSystemCredentialsSection extends StatefulWidget {
  const AdminSystemCredentialsSection({super.key});

  @override
  State<AdminSystemCredentialsSection> createState() =>
      _AdminSystemCredentialsSectionState();
}

class _AdminSystemCredentialsSectionState
    extends State<AdminSystemCredentialsSection> {
  final _svc = CredentialsV2Service();
  List<CredentialV2> _items = const [];
  bool _loading = true;
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
      final list = await _svc.listSystem();
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

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AdminSectionScaffold(
      title: 'admin.section_system_credentials'.tr(),
      subtitle: 'admin.sys_creds_subtitle'.tr(),
      loading: _loading,
      onRefresh: _load,
      headerActions: [
        ElevatedButton.icon(
          onPressed: _create,
          icon: const Icon(Icons.add_rounded, size: 14),
          label: Text('admin.sys_creds_new_long'.tr(),
              style: GoogleFonts.inter(
                  fontSize: 12, fontWeight: FontWeight.w700)),
          style: ElevatedButton.styleFrom(
            backgroundColor: c.purple,
            foregroundColor: Colors.white,
            elevation: 0,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          ),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null && _items.isEmpty) _buildError(c),
          if (_error == null) _buildList(c),
        ],
      ),
    );
  }

  Widget _buildError(AppColors c) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, size: 16, color: c.red),
            const SizedBox(width: 10),
            Expanded(
              child: Text(_error!,
                  style: GoogleFonts.firaCode(
                      fontSize: 11.5, color: c.textMuted)),
            ),
            const SizedBox(width: 14),
            ElevatedButton(
              onPressed: _load,
              child: Text('admin.retry'.tr(),
                  style: GoogleFonts.inter(fontSize: 11)),
            ),
          ],
        ),
      );

  Widget _buildList(AppColors c) {
    if (_items.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.border),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.vpn_key_outlined, size: 36, color: c.textMuted),
              const SizedBox(height: 12),
              Text('admin.sys_creds_empty_title'.tr(),
                  style: GoogleFonts.inter(
                      fontSize: 13.5,
                      color: c.textBright,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(
                'admin.sys_creds_empty_body'.tr(),
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                    fontSize: 11.5, color: c.textMuted, height: 1.5),
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
          for (var i = 0; i < _items.length; i++) ...[
            _SystemCredRow(
              cred: _items[i],
              onDelete: () => _confirmDelete(_items[i]),
            ),
            if (i < _items.length - 1)
              Divider(height: 1, color: c.border),
          ],
        ],
      ),
    );
  }

  Future<void> _create() async {
    // Reuse the user-facing credential form — it already handles
    // every provider type. After creation we promote the new
    // credential to system scope by calling createSystem with the
    // same fields. For simplicity we open the regular dialog and
    // refresh the list — the daemon sets `owner_type=system` when
    // the caller is admin.
    await showCredentialFormDialog(context);
    if (mounted) _load();
  }

  Future<void> _confirmDelete(CredentialV2 cred) async {
    final ok = await showThemedConfirmDialog(
      context,
      title: 'admin.sys_creds_delete_title'.tr(),
      body: 'admin.sys_creds_delete_body'.tr(namedArgs: {
        'provider': cred.displayProviderLabel,
        'label': cred.label,
      }),
      confirmLabel: 'admin.common_delete'.tr(),
      destructive: true,
    );
    if (ok != true) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _svc.deleteSystem(cred.id);
      _load();
    } on CredV2Exception catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
          SnackBar(content: Text(e.message)));
    }
  }
}

class _SystemCredRow extends StatefulWidget {
  final CredentialV2 cred;
  final VoidCallback onDelete;
  const _SystemCredRow({required this.cred, required this.onDelete});

  @override
  State<_SystemCredRow> createState() => _SystemCredRowState();
}

class _SystemCredRowState extends State<_SystemCredRow> {
  bool _h = false;

  Color _statusTint(AppColors c) {
    switch (widget.cred.status) {
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

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cred = widget.cred;
    final statusTint = _statusTint(c);
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        color: _h ? c.surfaceAlt : Colors.transparent,
        padding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.purple.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border:
                    Border.all(color: c.purple.withValues(alpha: 0.35)),
              ),
              child: Icon(Icons.vpn_key_outlined,
                  size: 14, color: c.purple),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          cred.displayProviderLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: c.textBright),
                        ),
                      ),
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
                        child: Text('admin.sys_badge_system'.tr(),
                            style: GoogleFonts.firaCode(
                                fontSize: 8.5,
                                color: c.purple,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${cred.label} · ${cred.providerType}${cred.firstMaskedPreview != null ? " · ${cred.firstMaskedPreview}" : ""}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.firaCode(
                        fontSize: 10.5, color: c.textMuted),
                  ),
                ],
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: statusTint.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(3),
                border:
                    Border.all(color: statusTint.withValues(alpha: 0.35)),
              ),
              child: Text(cred.status.toUpperCase(),
                  style: GoogleFonts.firaCode(
                      fontSize: 8.5,
                      color: statusTint,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4)),
            ),
            const SizedBox(width: 12),
            IconButton(
              tooltip: 'admin.common_delete'.tr(),
              iconSize: 14,
              icon: Icon(Icons.delete_outline_rounded, color: c.red),
              onPressed: widget.onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
