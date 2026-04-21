/// Admin → Quotas. Embeds the existing standalone [QuotasAdminPage]
/// inside the admin console shell. The standalone page is still
/// reachable via the command palette for power users; this section
/// is the one most admins will use day-to-day from the console.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/auth_service.dart';
import '../../../services/quotas_service.dart';
import '../../../theme/app_theme.dart';
import '../../common/themed_dialogs.dart';
import '../quotas_admin_page.dart' as admin_page;
import '_section_scaffold.dart';

class AdminQuotasSection extends StatefulWidget {
  const AdminQuotasSection({super.key});

  @override
  State<AdminQuotasSection> createState() => _AdminQuotasSectionState();
}

class _AdminQuotasSectionState extends State<AdminQuotasSection> {
  final _svc = QuotasService();
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChange);
    _svc.listAll();
  }

  @override
  void dispose() {
    _svc.removeListener(_onChange);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  List<UserQuota> get _filtered {
    if (_query.isEmpty) return _svc.all;
    final q = _query.toLowerCase();
    return _svc.all.where((r) {
      return r.scopeId.toLowerCase().contains(q) ||
          r.subjectLabel.toLowerCase().contains(q) ||
          (r.appId?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AdminSectionScaffold(
      title: 'admin.section_quotas'.tr(),
      subtitle: 'admin.quotas_subtitle'.tr(),
      loading: _svc.loading,
      onRefresh: () => _svc.listAll(),
      headerActions: [
        ElevatedButton.icon(
          onPressed: _create,
          icon: const Icon(Icons.add_rounded, size: 14),
          label: Text('admin.quotas_new'.tr(),
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
          _buildSearchBar(c),
          const SizedBox(height: 14),
          if (_svc.error != null && _svc.all.isEmpty)
            _buildError(c)
          else
            _buildTable(c),
        ],
      ),
    );
  }

  Widget _buildSearchBar(AppColors c) {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 15, color: c.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _query = v.trim()),
              style: GoogleFonts.inter(
                  fontSize: 12.5, color: c.textBright),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'admin.quotas_filter_hint'.tr(),
                hintStyle: GoogleFonts.inter(
                    fontSize: 12, color: c.textMuted),
              ),
            ),
          ),
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
              child: Text(
                _svc.error!,
                style: GoogleFonts.firaCode(
                    fontSize: 11.5, color: c.textMuted),
              ),
            ),
            const SizedBox(width: 14),
            ElevatedButton(
              onPressed: () => _svc.listAll(),
              child: Text('admin.retry'.tr(),
                  style: GoogleFonts.inter(fontSize: 11)),
            ),
          ],
        ),
      );

  Widget _buildTable(AppColors c) {
    final list = _filtered;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: LayoutBuilder(builder: (ctx, constraints) {
        const tableMinWidth = 760.0;
        final needsScroll = constraints.maxWidth < tableMinWidth;
        final table = Column(
          children: [
            const _QuotasTableHeader(),
            for (var i = 0; i < list.length; i++) ...[
              _QuotaRowCard(
                quota: list[i],
                onDelete: () => _confirmDelete(list[i]),
              ),
              if (i < list.length - 1) Divider(height: 1, color: c.border),
            ],
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.all(34),
                child: Text(
                  _query.isNotEmpty
                      ? 'admin.quotas_no_match'
                          .tr(namedArgs: {'q': _query})
                      : 'admin.quotas_empty_hint'.tr(),
                  style:
                      GoogleFonts.inter(fontSize: 12, color: c.textMuted),
                ),
              ),
          ],
        );
        if (!needsScroll) return table;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: SizedBox(width: tableMinWidth, child: table),
        );
      }),
    );
  }

  Future<void> _create() async {
    // Reuse the dialog from the standalone admin page — same form
    // with all 3 scopes / 3 periods.
    final isAdmin = AuthService().currentUser?.isAdmin ?? false;
    if (!isAdmin) return;
    // Open the standalone page's dialog by going through the page
    // briefly. Alternatively, we could lift the dialog into a
    // shared file — for now we re-use through navigation.
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const admin_page.QuotasAdminPage()),
    );
    if (mounted) _svc.listAll();
  }

  Future<void> _confirmDelete(UserQuota q) async {
    final ok = await showThemedConfirmDialog(
      context,
      title: 'admin.quotas_delete_confirm'.tr(),
      body: 'admin.quotas_delete_body'.tr(namedArgs: {
        'scope': q.scopeType,
        'subject': q.subjectLabel,
      }),
      confirmLabel: 'admin.common_delete'.tr(),
      destructive: true,
    );
    if (ok != true) return;
    await _svc.delete(q.id);
  }
}

class _QuotasTableHeader extends StatelessWidget {
  const _QuotasTableHeader();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    TextStyle h() => GoogleFonts.firaCode(
          fontSize: 9.5,
          color: c.textMuted,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: Row(
        children: [
          SizedBox(
              width: 88,
              child: Text('admin.quotas_col_scope'.tr(), style: h())),
          Expanded(
              flex: 3,
              child: Text('admin.quotas_col_subject'.tr(), style: h())),
          Expanded(
              flex: 2,
              child: Text('admin.quotas_col_app'.tr(), style: h())),
          SizedBox(
              width: 70,
              child: Text('admin.quotas_col_period'.tr(), style: h())),
          SizedBox(
              width: 100,
              child: Text('admin.quotas_col_limit'.tr(), style: h())),
          Expanded(
              flex: 3,
              child: Text('admin.quotas_col_usage'.tr(), style: h())),
          const SizedBox(width: 38),
        ],
      ),
    );
  }
}

class _QuotaRowCard extends StatelessWidget {
  final UserQuota quota;
  final VoidCallback onDelete;
  const _QuotaRowCard({required this.quota, required this.onDelete});

  Color _scopeTint(AppColors c) {
    switch (quota.scopeType) {
      case 'user':
        return c.blue;
      case 'user_app':
        return c.purple;
      case 'app':
        return c.green;
      default:
        return c.textMuted;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final frac = quota.fraction;
    final tint = frac > 0.9
        ? c.red
        : frac > 0.7
            ? c.orange
            : c.green;
    final scopeTint = _scopeTint(c);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 88,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: scopeTint.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
                border:
                    Border.all(color: scopeTint.withValues(alpha: 0.35)),
              ),
              child: Text(
                quota.scopeType.toUpperCase(),
                style: GoogleFonts.firaCode(
                  fontSize: 9,
                  color: scopeTint,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Text(quota.subjectLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                    fontSize: 12.5,
                    color: c.textBright,
                    fontWeight: FontWeight.w600)),
          ),
          Expanded(
            flex: 2,
            child: Text(quota.appId ?? '—',
                style: GoogleFonts.firaCode(
                    fontSize: 11,
                    color: quota.appId != null ? c.text : c.textDim)),
          ),
          SizedBox(
            width: 70,
            child: Text(quota.period.toUpperCase(),
                style: GoogleFonts.firaCode(
                    fontSize: 10,
                    color: c.textMuted,
                    fontWeight: FontWeight.w700)),
          ),
          SizedBox(
            width: 100,
            child: Text(_fmt(quota.tokensLimit),
                style: GoogleFonts.firaCode(
                    fontSize: 12, color: c.textBright)),
          ),
          Expanded(
            flex: 3,
            child: Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: frac,
                      minHeight: 5,
                      backgroundColor: c.surfaceAlt,
                      valueColor: AlwaysStoppedAnimation(tint),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 38,
                  child: Text('${(frac * 100).toStringAsFixed(0)}%',
                      textAlign: TextAlign.right,
                      style: GoogleFonts.firaCode(
                          fontSize: 10.5, color: tint)),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 38,
            child: IconButton(
              tooltip: 'admin.common_delete'.tr(),
              iconSize: 14,
              icon: Icon(Icons.delete_outline_rounded, color: c.red),
              onPressed: onDelete,
            ),
          ),
        ],
      ),
    );
  }

  static String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return n.toString();
  }
}
