/// Admin → Activity log. Full feed of admin actions sourced from
/// `GET /api/admin/audit-log`. Filterable by action prefix.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/admin_service.dart';
import '../../../theme/app_theme.dart';
import '_section_scaffold.dart';

class AdminAuditSection extends StatefulWidget {
  const AdminAuditSection({super.key});

  @override
  State<AdminAuditSection> createState() => _AdminAuditSectionState();
}

class _AdminAuditSectionState extends State<AdminAuditSection> {
  final _svc = AdminService();
  bool _loading = true;
  String _filter = 'all'; // all | create | update | delete | revoke

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChange);
    _load();
  }

  @override
  void dispose() {
    _svc.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    await _svc.loadAudit(limit: 200);
    if (!mounted) return;
    setState(() => _loading = false);
  }

  List<AdminAuditEntry> get _filtered {
    if (_filter == 'all') return _svc.audit;
    return _svc.audit.where((e) => e.action.contains(_filter)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AdminSectionScaffold(
      title: 'admin.section_audit'.tr(),
      subtitle: 'admin.audit_subtitle'
          .tr(namedArgs: {'n': '${_svc.audit.length}'}),
      loading: _loading,
      onRefresh: _load,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildFilters(c),
          const SizedBox(height: 14),
          _filtered.isEmpty
              ? _buildEmpty(c)
              : Container(
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: c.border),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 8),
                    child: Column(
                      children: [
                        for (var i = 0; i < _filtered.length; i++) ...[
                          AdminAuditRow(entry: _filtered[i]),
                          if (i < _filtered.length - 1)
                            Divider(height: 1, color: c.border),
                        ],
                      ],
                    ),
                  ),
                ),
        ],
      ),
    );
  }

  Widget _buildFilters(AppColors c) {
    return Wrap(
      spacing: 8,
      children: [
        for (final f in const [
          ('all', 'All'),
          ('create', 'Create'),
          ('update', 'Update'),
          ('delete', 'Delete'),
          ('revoke', 'Revoke'),
        ])
          ChoiceChip(
            label: Text(f.$2),
            selected: _filter == f.$1,
            onSelected: (_) => setState(() => _filter = f.$1),
            selectedColor: c.purple.withValues(alpha: 0.18),
            labelStyle: GoogleFonts.inter(
              fontSize: 11,
              color: _filter == f.$1 ? c.purple : c.textMuted,
              fontWeight: FontWeight.w700,
            ),
            backgroundColor: c.surface,
            side: BorderSide(color: c.border),
          ),
      ],
    );
  }

  Widget _buildEmpty(AppColors c) => Container(
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
              Icon(Icons.history_rounded, size: 36, color: c.textMuted),
              const SizedBox(height: 12),
              Text(
                _loading
                    ? 'Loading…'
                    : (_filter != 'all'
                        ? 'No "$_filter" action recorded'
                        : 'No admin action recorded yet.'),
                style: GoogleFonts.inter(
                    fontSize: 12, color: c.textMuted),
              ),
            ],
          ),
        ),
      );
}
