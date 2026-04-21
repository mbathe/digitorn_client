/// Admin-only dialog for managing system credentials —
/// daemon-wide credentials visible to every app (or restricted
/// to one specific app when `app_id` is set). Hidden from regular
/// users; the credentials manager page only surfaces the entry
/// point when `AuthService().currentUser?.isAdmin == true`.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/app_summary.dart';
import '../../models/credential_v2.dart';
import '../../services/apps_service.dart';
import '../../services/credentials_v2_service.dart';
import '../../theme/app_theme.dart';
import 'credential_field_form.dart';

class SystemCredentialsDialog {
  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      builder: (_) => const _SystemCredentialsDialog(),
    );
  }
}

class _SystemCredentialsDialog extends StatefulWidget {
  const _SystemCredentialsDialog();

  @override
  State<_SystemCredentialsDialog> createState() =>
      _SystemCredentialsDialogState();
}

class _SystemCredentialsDialogState extends State<_SystemCredentialsDialog> {
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
        _error = e.statusCode == 403
            ? 'credentials.system_admin_required'.tr()
            : e.message;
      });
    }
  }

  Future<void> _create() async {
    final created = await showDialog<CredentialV2>(
      context: context,
      builder: (_) => const _SystemCreateForm(),
    );
    if (created != null) _load();
  }

  Future<void> _delete(CredentialV2 cred) async {
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
            'credentials.system_delete_title_of'
                .tr(namedArgs: {'name': cred.label}),
            style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: c.textBright)),
        content: Text(
          'credentials.system_delete_body'.tr(),
          style:
              GoogleFonts.inter(fontSize: 12, color: c.text, height: 1.5),
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
      await _svc.deleteSystem(cred.id);
      _load();
    } on CredV2Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    }
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
        constraints: const BoxConstraints(maxWidth: 540, maxHeight: 580),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.shield_outlined, size: 18, color: c.purple),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('credentials.system_dialog_title'.tr(),
                            style: GoogleFonts.inter(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: c.textBright)),
                        const SizedBox(height: 2),
                        Text(
                          'credentials.system_dialog_hint'.tr(),
                          style: GoogleFonts.inter(
                              fontSize: 11, color: c.textMuted),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    iconSize: 16,
                    icon: Icon(Icons.refresh_rounded, color: c.textMuted),
                    onPressed: _loading ? null : _load,
                  ),
                  IconButton(
                    iconSize: 16,
                    icon: Icon(Icons.close_rounded, color: c.textMuted),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (_loading)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.5, color: c.textMuted),
                    ),
                  ),
                )
              else if (_error != null)
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: c.red.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: c.red.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.lock_outline_rounded,
                          size: 14, color: c.red),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_error!,
                            style: GoogleFonts.inter(
                                fontSize: 11.5, color: c.red)),
                      ),
                    ],
                  ),
                )
              else if (_items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 30),
                  child: Center(
                    child: Text(
                      'credentials.system_empty_hint'.tr(),
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                          fontSize: 12, color: c.textMuted),
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _items.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: c.border),
                    itemBuilder: (_, i) => _SystemRow(
                      cred: _items[i],
                      onDelete: () => _delete(_items[i]),
                    ),
                  ),
                ),
              const SizedBox(height: 14),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _create,
                    icon: Icon(Icons.add_rounded, size: 14, color: c.blue),
                    label: Text('credentials.system_new_credential'.tr(),
                        style: GoogleFonts.inter(
                            fontSize: 12, color: c.blue)),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('credentials.close'.tr(),
                        style: GoogleFonts.inter(
                            fontSize: 12, color: c.textMuted)),
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

class _SystemRow extends StatelessWidget {
  final CredentialV2 cred;
  final VoidCallback onDelete;
  const _SystemRow({required this.cred, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final masked = cred.firstMaskedPreview ?? '(no preview)';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 11),
      child: Row(
        children: [
          Icon(Icons.shield_outlined, size: 14, color: c.purple),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${cred.displayProviderLabel} · ${cred.label}',
                  style: GoogleFonts.inter(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: c.textBright),
                ),
                Text(masked,
                    style: GoogleFonts.firaCode(
                        fontSize: 10.5, color: c.textMuted)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'credentials.delete_tooltip'.tr(),
            iconSize: 14,
            icon: Icon(Icons.delete_outline_rounded, color: c.red),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _SystemCreateForm extends StatefulWidget {
  const _SystemCreateForm();
  @override
  State<_SystemCreateForm> createState() => _SystemCreateFormState();
}

class _SystemCreateFormState extends State<_SystemCreateForm> {
  ProviderCatalogueEntry? _provider;
  final _labelCtrl = TextEditingController(text: 'system');
  AppSummary? _scopedApp;
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
    if (_provider == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final cred = await CredentialsV2Service().createSystem(
        providerName: _provider!.name,
        providerType: _provider!.type,
        label: _labelCtrl.text.trim(),
        appId: _scopedApp?.appId,
        fields: _values,
      );
      if (mounted) Navigator.pop(context, cred);
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
    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('credentials.system_new_credential'.tr(),
                  style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: c.textBright)),
              const SizedBox(height: 14),
              Text('credentials.provider'.tr(),
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: c.textBright)),
              const SizedBox(height: 4),
              DropdownButtonFormField<ProviderCatalogueEntry>(
                initialValue: _provider,
                items: [
                  for (final e in CredentialsV2Service.catalogue)
                    if (e.type != 'oauth2')
                      DropdownMenuItem(value: e, child: Text(e.label)),
                ],
                onChanged: (e) => setState(() => _provider = e),
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
                style: GoogleFonts.inter(fontSize: 12, color: c.textBright),
                dropdownColor: c.surface,
              ),
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
              Text('credentials.restrict_to_app'.tr(),
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: c.textBright)),
              const SizedBox(height: 4),
              DropdownButtonFormField<AppSummary?>(
                initialValue: _scopedApp,
                items: [
                  DropdownMenuItem(
                      value: null,
                      child: Text('credentials.all_apps_default'.tr())),
                  for (final a in AppsService().apps)
                    DropdownMenuItem(value: a, child: Text(a.name)),
                ],
                onChanged: (a) => setState(() => _scopedApp = a),
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
                style: GoogleFonts.inter(fontSize: 12, color: c.textBright),
                dropdownColor: c.surface,
              ),
              if (_provider != null && _provider!.fields.isNotEmpty) ...[
                const SizedBox(height: 16),
                CredentialFieldForm(
                  fields: _provider!.fields,
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
                    onPressed: _saving || !_valid || _provider == null
                        ? null
                        : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: c.purple,
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
