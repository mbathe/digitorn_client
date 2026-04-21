/// Admin overview — quick-glance dashboard with workspace stats
/// tiles, recent activity preview, and shortcuts to the most-used
/// admin actions.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/admin_service.dart';
import '../../../theme/app_theme.dart';
import '_section_scaffold.dart';

class AdminOverviewSection extends StatefulWidget {
  const AdminOverviewSection({super.key});

  @override
  State<AdminOverviewSection> createState() =>
      _AdminOverviewSectionState();
}

class _AdminOverviewSectionState extends State<AdminOverviewSection> {
  final _svc = AdminService();
  bool _loading = true;

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
    await Future.wait([
      _svc.loadStats(),
      _svc.loadAudit(limit: 8),
      _svc.listUsers(),
    ]);
    if (!mounted) return;
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final stats = _svc.stats;
    return AdminSectionScaffold(
      title: 'admin.section_overview'.tr(),
      subtitle: 'admin.overview_subtitle'.tr(),
      onRefresh: _load,
      loading: _loading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (stats != null) _buildStatsGrid(c, stats),
          if (stats == null && !_loading) _buildStatsFallback(c),
          const SizedBox(height: 26),
          _buildRecentActivity(c),
        ],
      ),
    );
  }

  Widget _buildStatsGrid(AppColors c, AdminStats s) {
    final tiles = <_StatTileData>[
      _StatTileData(
          icon: Icons.group_outlined,
          label: 'admin.stat_users'.tr(),
          value: '${s.users}',
          tint: c.blue),
      _StatTileData(
          icon: Icons.apps_rounded,
          label: 'admin.stat_apps'.tr(),
          value: '${s.apps}',
          tint: c.purple),
      _StatTileData(
          icon: Icons.inventory_2_outlined,
          label: 'admin.stat_packages'.tr(),
          value: '${s.packages}',
          subValue: 'admin.stat_system_suffix'
              .tr(namedArgs: {'n': '${s.systemPackages}'}),
          tint: c.cyan),
      _StatTileData(
          icon: Icons.vpn_key_outlined,
          label: 'admin.stat_credentials'.tr(),
          value: '${s.credentials}',
          subValue: 'admin.stat_system_suffix'
              .tr(namedArgs: {'n': '${s.systemCredentials}'}),
          tint: c.green),
      _StatTileData(
          icon: Icons.electrical_services_rounded,
          label: 'admin.stat_mcp_servers'.tr(),
          value: '${s.mcpServers}',
          tint: c.orange),
      _StatTileData(
          icon: Icons.bolt_rounded,
          label: 'admin.stat_live_sessions'.tr(),
          value: '${s.activeSessions}',
          tint: c.purple),
      _StatTileData(
          icon: Icons.attach_money_rounded,
          label: 'admin.stat_cost_month'.tr(),
          value: '\$${s.monthlyCostUsd.toStringAsFixed(2)}',
          tint: c.green),
      _StatTileData(
          icon: Icons.shield_outlined,
          label: 'admin.stat_admin_actions'.tr(),
          value: '${_svc.audit.length}',
          subValue: 'admin.stat_last_24h'.tr(),
          tint: c.red),
    ];
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 4,
      childAspectRatio: 1.55,
      crossAxisSpacing: 14,
      mainAxisSpacing: 14,
      children: [for (final t in tiles) _StatTile(data: t)],
    );
  }

  Widget _buildStatsFallback(AppColors c) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 14, color: c.orange),
              const SizedBox(width: 8),
              Text('admin.overview_stats_err_title'.tr(),
                  style: GoogleFonts.inter(
                      fontSize: 12.5,
                      color: c.textBright,
                      fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'admin.overview_stats_err_body'.tr(),
            style: GoogleFonts.inter(
                fontSize: 11.5, color: c.textMuted, height: 1.5),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _InlineFallbackTile(
                  label: 'admin.overview_stats_users'.tr(),
                  value: '${_svc.users.length}'),
              const SizedBox(width: 12),
              _InlineFallbackTile(
                  label: 'admin.overview_audit_24h'.tr(),
                  value: '${_svc.audit.length}'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRecentActivity(AppColors c) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.history_rounded, size: 14, color: c.textMuted),
              const SizedBox(width: 8),
              Text('admin.overview_recent_header'.tr(),
                  style: GoogleFonts.firaCode(
                      fontSize: 10,
                      color: c.textMuted,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8)),
            ],
          ),
          const SizedBox(height: 14),
          if (_svc.audit.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                _loading
                    ? 'admin.loading'.tr()
                    : 'admin.overview_no_audit'.tr(),
                style: GoogleFonts.inter(
                    fontSize: 11.5, color: c.textMuted),
              ),
            )
          else
            for (final entry in _svc.audit.take(8))
              AdminAuditRow(entry: entry, dense: true),
        ],
      ),
    );
  }
}

class _StatTileData {
  final IconData icon;
  final String label;
  final String value;
  final String? subValue;
  final Color tint;
  const _StatTileData({
    required this.icon,
    required this.label,
    required this.value,
    required this.tint,
    this.subValue,
  });
}

class _StatTile extends StatelessWidget {
  final _StatTileData data;
  const _StatTile({required this.data});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: data.tint.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(7),
                  border:
                      Border.all(color: data.tint.withValues(alpha: 0.35)),
                ),
                child: Icon(data.icon, size: 14, color: data.tint),
              ),
              const Spacer(),
              Text(data.label,
                  style: GoogleFonts.firaCode(
                      fontSize: 9,
                      color: c.textMuted,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6)),
            ],
          ),
          const Spacer(),
          Text(
            data.value,
            style: GoogleFonts.inter(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: c.textBright,
              letterSpacing: -0.5,
            ),
          ),
          if (data.subValue != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(data.subValue!,
                  style: GoogleFonts.firaCode(
                      fontSize: 10, color: c.textMuted)),
            ),
        ],
      ),
    );
  }
}

class _InlineFallbackTile extends StatelessWidget {
  final String label;
  final String value;
  const _InlineFallbackTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: GoogleFonts.firaCode(
                  fontSize: 9.5, color: c.textMuted)),
          const SizedBox(height: 2),
          Text(value,
              style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: c.textBright)),
        ],
      ),
    );
  }
}

