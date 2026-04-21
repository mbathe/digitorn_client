/// Admin → Apps → Secrets dialog. Lists the KEYS of every secret
/// the app knows about (never the values — the daemon never sends
/// them back), plus the `required-secrets` shape so the admin
/// knows which are expected. Admins can:
///
///   * Set / overwrite a secret value
///   * Delete a secret
///
/// Scout-verified against `/api/admin/{app_id}/secrets*`. Closes
/// out two Tier-3 methods (`listSecrets`, `setSecret`,
/// `deleteSecret`) plus the `requiredSecrets` probe.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/app_admin_service.dart';
import '../../../theme/app_theme.dart';
import '../../chat/chat_bubbles.dart' show showToast;

class AdminSecretsDialog extends StatefulWidget {
  final String appId;
  final String appName;
  const AdminSecretsDialog(
      {super.key, required this.appId, required this.appName});

  @override
  State<AdminSecretsDialog> createState() => _AdminSecretsDialogState();
}

class _AdminSecretsDialogState extends State<AdminSecretsDialog> {
  List<Map<String, dynamic>> _secrets = const [];
  Map<String, dynamic> _required = const {};
  bool _loading = true;
  bool _busy = false;

  final _keyCtrl = TextEditingController();
  final _valCtrl = TextEditingController();
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _valCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final svc = AppAdminService();
    final results = await Future.wait([
      svc.listSecrets(widget.appId, scope: AdminScope.admin),
      svc.requiredSecrets(widget.appId, scope: AdminScope.admin),
    ]);
    if (!mounted) return;
    setState(() {
      _secrets = (results[0] as List<Map<String, dynamic>>?) ?? const [];
      _required = (results[1] as Map<String, dynamic>?) ?? const {};
      _loading = false;
    });
  }

  Future<void> _setSecret() async {
    final k = _keyCtrl.text.trim();
    final v = _valCtrl.text;
    if (k.isEmpty) {
      showToast(context, 'admin.sd_key_required'.tr());
      return;
    }
    setState(() => _busy = true);
    final ok = await AppAdminService()
        .setSecret(widget.appId, k, v, scope: AdminScope.admin);
    if (!mounted) return;
    setState(() => _busy = false);
    showToast(
        context,
        ok
            ? 'admin.sd_saved'.tr(namedArgs: {'key': k})
            : 'admin.sd_save_failed'.tr());
    if (ok) {
      _keyCtrl.clear();
      _valCtrl.clear();
      await _load();
    }
  }

  Future<void> _deleteSecret(String key) async {
    final c = context.colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c.border),
        ),
        title: Text('Delete $key?',
            style: GoogleFonts.inter(
                fontSize: 14, fontWeight: FontWeight.w700)),
        content: Text(
          'The app will lose access immediately. Callers that rely on '
          'this secret start failing until it\'s re-added.',
          style: GoogleFonts.inter(fontSize: 12.5, color: c.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.red),
            onPressed: () => Navigator.of(dCtx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    final success = await AppAdminService()
        .deleteSecret(widget.appId, key, scope: AdminScope.admin);
    if (!mounted) return;
    setState(() => _busy = false);
    showToast(context, success ? 'Deleted $key.' : 'Delete failed.');
    if (success) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final requiredList = _requiredList();
    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(maxWidth: 540, maxHeight: 620),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 12, 12),
              child: Row(
                children: [
                  Icon(Icons.vpn_key_outlined,
                      size: 18, color: c.orange),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Secrets · ${widget.appName}',
                      style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: c.text),
                    ),
                  ),
                  if (_busy)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close_rounded,
                        size: 16, color: c.textMuted),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: c.border),
            Expanded(
              child: _loading
                  ? const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(
                          child: CircularProgressIndicator(
                              strokeWidth: 1.5)),
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (requiredList.isNotEmpty) ...[
                            _sectionLabel(c, 'REQUIRED SECRETS'),
                            const SizedBox(height: 6),
                            _requiredPanel(c, requiredList),
                            const SizedBox(height: 18),
                          ],
                          _sectionLabel(c, 'STORED KEYS'),
                          const SizedBox(height: 6),
                          _storedPanel(c),
                          const SizedBox(height: 18),
                          _sectionLabel(c, 'SET / OVERWRITE'),
                          const SizedBox(height: 6),
                          _editor(c),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _requiredList() {
    final raw = _required['required'] ??
        _required['secrets'] ??
        _required['items'] ??
        const [];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
  }

  Widget _sectionLabel(AppColors c, String text) => Text(
        text,
        style: GoogleFonts.inter(
            fontSize: 10,
            color: c.textMuted,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8),
      );

  Widget _requiredPanel(AppColors c, List<Map<String, dynamic>> list) {
    final storedKeys = _secrets
        .map((s) => (s['key'] ?? s['name']) as String?)
        .whereType<String>()
        .toSet();
    return Container(
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          for (int i = 0; i < list.length; i++) ...[
            _requiredRow(c, list[i], storedKeys),
            if (i < list.length - 1)
              Divider(height: 1, color: c.border),
          ],
        ],
      ),
    );
  }

  Widget _requiredRow(
      AppColors c, Map<String, dynamic> entry, Set<String> stored) {
    final key = (entry['key'] ?? entry['name'] ?? '') as String;
    final desc = (entry['description'] ?? entry['help'] ?? '') as String;
    final isSet = stored.contains(key);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Icon(
            isSet ? Icons.check_circle_rounded : Icons.circle_outlined,
            size: 14,
            color: isSet ? c.green : c.textDim,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(key,
                    style: GoogleFonts.firaCode(
                        fontSize: 11.5,
                        color: c.text,
                        fontWeight: FontWeight.w600)),
                if (desc.isNotEmpty)
                  Text(desc,
                      style: GoogleFonts.inter(
                          fontSize: 11, color: c.textMuted)),
              ],
            ),
          ),
          if (!isSet)
            TextButton.icon(
              onPressed: () {
                setState(() {
                  _keyCtrl.text = key;
                });
              },
              icon: const Icon(Icons.add_rounded, size: 14),
              label: const Text('Add'),
              style: TextButton.styleFrom(
                foregroundColor: c.blue,
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 4),
              ),
            ),
        ],
      ),
    );
  }

  Widget _storedPanel(AppColors c) {
    if (_secrets.isEmpty) {
      return Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: c.bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.border),
        ),
        child: Text(
          'No secrets set yet.',
          style: GoogleFonts.inter(fontSize: 12, color: c.textDim),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          for (int i = 0; i < _secrets.length; i++) ...[
            _storedRow(c, _secrets[i]),
            if (i < _secrets.length - 1)
              Divider(height: 1, color: c.border),
          ],
        ],
      ),
    );
  }

  Widget _storedRow(AppColors c, Map<String, dynamic> entry) {
    final key =
        (entry['key'] ?? entry['name'] ?? '(unknown)') as String;
    final source = (entry['source'] ?? '') as String;
    final ts = (entry['updated_at'] ?? entry['last_set_at'] ?? '')
        .toString();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.key_rounded, size: 14, color: c.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(key,
                    style: GoogleFonts.firaCode(
                        fontSize: 11.5,
                        color: c.textBright,
                        fontWeight: FontWeight.w600)),
                if (source.isNotEmpty || ts.isNotEmpty)
                  Text(
                    [
                      if (source.isNotEmpty) source,
                      if (ts.isNotEmpty) ts,
                    ].join(' · '),
                    style: GoogleFonts.firaCode(
                        fontSize: 10, color: c.textDim),
                  ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => _deleteSecret(key),
            tooltip: 'Delete',
            iconSize: 14,
            icon: Icon(Icons.delete_outline_rounded, color: c.red),
          ),
        ],
      ),
    );
  }

  Widget _editor(AppColors c) {
    return Column(
      children: [
        TextField(
          controller: _keyCtrl,
          style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
          decoration: InputDecoration(
            hintText: 'Key (e.g. OPENAI_API_KEY)',
            hintStyle: GoogleFonts.inter(fontSize: 11.5, color: c.textDim),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 10, vertical: 10),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: c.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: c.orange),
            ),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _valCtrl,
          obscureText: _obscure,
          style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
          decoration: InputDecoration(
            hintText: 'Value',
            hintStyle:
                GoogleFonts.inter(fontSize: 11.5, color: c.textDim),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 10, vertical: 10),
            suffixIcon: IconButton(
              iconSize: 14,
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(
                  _obscure
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded,
                  color: c.textMuted),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: c.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: c.orange),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerRight,
          child: ElevatedButton.icon(
            onPressed: _busy ? null : _setSecret,
            icon: const Icon(Icons.save_rounded,
                size: 14, color: Colors.white),
            label: Text(
              'Save secret',
              style: GoogleFonts.inter(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 11.5),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: c.orange,
              elevation: 0,
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 10),
            ),
          ),
        ),
      ],
    );
  }
}
