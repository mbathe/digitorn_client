/// Admin → Apps → Quota dialog. Edit the per-app quota and any
/// per-user overrides against [AppAdminService]. Shows the current
/// values (read on open), lets the admin update / clear, and
/// lists per-user overrides with the same CRUD knobs.
///
/// Quota shape is daemon-defined — common fields are
/// `daily_tokens`, `daily_messages`, `daily_cost_usd`. We render
/// the raw map as a key/value editor so the UI keeps working even
/// when the daemon adds a new quota key.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/app_admin_service.dart';
import '../../../theme/app_theme.dart';
import '../../chat/chat_bubbles.dart' show showToast;

class AdminQuotaDialog extends StatefulWidget {
  final String appId;
  final String appName;
  const AdminQuotaDialog(
      {super.key, required this.appId, required this.appName});

  @override
  State<AdminQuotaDialog> createState() => _AdminQuotaDialogState();
}

class _AdminQuotaDialogState extends State<AdminQuotaDialog> {
  Map<String, dynamic> _appQuota = const {};
  bool _loading = true;
  bool _busy = false;

  final _keyCtrl = TextEditingController();
  final _valCtrl = TextEditingController();

  final _userIdCtrl = TextEditingController();
  final _userKeyCtrl = TextEditingController();
  final _userValCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _valCtrl.dispose();
    _userIdCtrl.dispose();
    _userKeyCtrl.dispose();
    _userValCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final q = await AppAdminService().getQuota(widget.appId,
        scope: AdminScope.admin);
    if (!mounted) return;
    setState(() {
      _appQuota = q ?? const {};
      _loading = false;
    });
  }

  Future<void> _setAppKey() async {
    final k = _keyCtrl.text.trim();
    final v = _valCtrl.text.trim();
    if (k.isEmpty || v.isEmpty) return;
    setState(() => _busy = true);
    final merged = Map<String, dynamic>.from(_appQuota);
    merged[k] = num.tryParse(v) ?? v;
    final ok = await AppAdminService().setQuota(
        widget.appId, merged, scope: AdminScope.admin);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      _keyCtrl.clear();
      _valCtrl.clear();
      await _load();
    }
    if (!mounted) return;
    showToast(context,
        ok ? 'admin.qd_saved'.tr() : 'admin.qd_save_failed'.tr());
  }

  Future<void> _clearApp() async {
    setState(() => _busy = true);
    final ok = await AppAdminService().clearQuota(widget.appId,
        scope: AdminScope.admin);
    if (!mounted) return;
    setState(() => _busy = false);
    showToast(context,
        ok ? 'admin.qd_cleared'.tr() : 'admin.qd_clear_failed'.tr());
    if (ok) await _load();
  }

  Future<void> _setUserKey() async {
    final uid = _userIdCtrl.text.trim();
    final k = _userKeyCtrl.text.trim();
    final v = _userValCtrl.text.trim();
    if (uid.isEmpty || k.isEmpty || v.isEmpty) return;
    setState(() => _busy = true);
    // We need the current user quota first so we don't wipe siblings.
    final existing = await AppAdminService().getUserQuota(
        widget.appId, uid, scope: AdminScope.admin);
    final merged = Map<String, dynamic>.from(existing ?? const {});
    merged[k] = num.tryParse(v) ?? v;
    final ok = await AppAdminService().setUserQuota(
        widget.appId, uid, merged, scope: AdminScope.admin);
    if (!mounted) return;
    setState(() => _busy = false);
    showToast(
        context,
        ok
            ? 'admin.qd_user_saved'.tr(namedArgs: {'uid': uid})
            : 'admin.qd_save_failed'.tr());
    if (ok) {
      _userKeyCtrl.clear();
      _userValCtrl.clear();
    }
  }

  Future<void> _clearUser() async {
    final uid = _userIdCtrl.text.trim();
    if (uid.isEmpty) return;
    setState(() => _busy = true);
    final ok = await AppAdminService().clearUserQuota(
        widget.appId, uid, scope: AdminScope.admin);
    if (!mounted) return;
    setState(() => _busy = false);
    showToast(
        context,
        ok
            ? 'admin.qd_user_cleared'.tr(namedArgs: {'uid': uid})
            : 'admin.qd_clear_failed'.tr());
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
        constraints:
            const BoxConstraints(maxWidth: 520, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 12, 12),
              child: Row(
                children: [
                  Icon(Icons.speed_rounded, size: 18, color: c.blue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'admin.qd_title'
                          .tr(namedArgs: {'name': widget.appName}),
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
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(18),
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(
                          child:
                              CircularProgressIndicator(strokeWidth: 1.5),
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _sectionLabel(c, 'admin.qd_section_app'.tr()),
                          const SizedBox(height: 8),
                          _quotaMap(c, _appQuota,
                              emptyLabel: 'admin.qd_no_app_quota'.tr()),
                          const SizedBox(height: 12),
                          _kvEditor(
                            c,
                            keyCtrl: _keyCtrl,
                            valCtrl: _valCtrl,
                            onSet: _setAppKey,
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: _appQuota.isEmpty ? null : _clearApp,
                              icon: const Icon(Icons.delete_sweep_outlined,
                                  size: 14),
                              label: Text('admin.qd_clear_app'.tr()),
                              style: TextButton.styleFrom(
                                  foregroundColor: c.red),
                            ),
                          ),
                          const SizedBox(height: 24),
                          _sectionLabel(c, 'admin.qd_section_user'.tr()),
                          const SizedBox(height: 8),
                          _textField(
                              c, _userIdCtrl, 'admin.qd_user_id_hint'.tr()),
                          const SizedBox(height: 10),
                          _kvEditor(
                            c,
                            keyCtrl: _userKeyCtrl,
                            valCtrl: _userValCtrl,
                            onSet: _setUserKey,
                            hint: 'admin.qd_set_user_override'.tr(),
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: _clearUser,
                              icon: const Icon(Icons.delete_sweep_outlined,
                                  size: 14),
                              label: Text('admin.qd_clear_user'.tr()),
                              style: TextButton.styleFrom(
                                  foregroundColor: c.red),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(AppColors c, String text) => Text(
        text,
        style: GoogleFonts.inter(
            fontSize: 10,
            color: c.textMuted,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8),
      );

  Widget _quotaMap(AppColors c, Map<String, dynamic> map,
      {required String emptyLabel}) {
    if (map.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: c.bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.border),
        ),
        child: Text(emptyLabel,
            style: GoogleFonts.inter(fontSize: 12, color: c.textDim)),
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
          for (final entry in map.entries)
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  Text(entry.key,
                      style: GoogleFonts.firaCode(
                          fontSize: 11.5, color: c.text)),
                  const Spacer(),
                  Text('${entry.value}',
                      style: GoogleFonts.firaCode(
                          fontSize: 11.5,
                          color: c.textBright,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _kvEditor(
    AppColors c, {
    required TextEditingController keyCtrl,
    required TextEditingController valCtrl,
    required VoidCallback onSet,
    String? hint,
  }) {
    return Row(
      children: [
        Expanded(child: _textField(c, keyCtrl, 'admin.qd_key_hint'.tr())),
        const SizedBox(width: 8),
        Expanded(
            child: _textField(c, valCtrl, 'admin.qd_value_hint'.tr(),
                inputs: [FilteringTextInputFormatter.singleLineFormatter])),
        const SizedBox(width: 8),
        ElevatedButton.icon(
          onPressed: onSet,
          icon: const Icon(Icons.save_rounded,
              size: 14, color: Colors.white),
          label: Text(hint ?? 'admin.qd_set_button'.tr(),
              style: GoogleFonts.inter(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 11.5)),
          style: ElevatedButton.styleFrom(
            backgroundColor: c.blue,
            elevation: 0,
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 10),
          ),
        ),
      ],
    );
  }

  Widget _textField(
    AppColors c,
    TextEditingController ctrl,
    String hint, {
    List<TextInputFormatter>? inputs,
  }) {
    return TextField(
      controller: ctrl,
      inputFormatters: inputs,
      style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.inter(fontSize: 11.5, color: c.textDim),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: c.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: c.blue),
        ),
      ),
    );
  }
}
