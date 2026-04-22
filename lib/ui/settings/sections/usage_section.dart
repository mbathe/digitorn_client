/// "Usage & quotas" section — real data from the daemon's
/// `GET /api/users/me/usage`. Replaces the old client-side estimate.
///
/// Renders:
///   * Big-number header tiles (total tokens, cost $, quota %)
///   * Quota progress bar with "resets in X days"
///   * 30-day bar chart of daily token consumption
///   * 24-hour sparkline of hourly consumption
///   * Cost breakdown by model (table)
///   * Per-app breakdown (list with progress bars)
///
/// When the daemon doesn't respond we fall back to the client-side
/// estimate from [BackgroundAppService.loadStats] so the screen
/// stays alive offline.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/quotas_service.dart';
import '../../../services/usage_service.dart';
import '../../../theme/app_theme.dart';
import '../widgets/my_quotas_card.dart';
import '_shared.dart';

class UsageSection extends StatefulWidget {
  const UsageSection({super.key});

  @override
  State<UsageSection> createState() => _UsageSectionState();
}

class _UsageSectionState extends State<UsageSection> {
  final _svc = UsageService();
  final _quotasSvc = QuotasService();
  bool _loading = true;
  List<UserQuota> _myQuotas = const [];

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChange);
    _quotasSvc.addListener(_onChange);
    _load();
  }

  @override
  void dispose() {
    _svc.removeListener(_onChange);
    _quotasSvc.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final results = await Future.wait([
      _svc.load(),
      _quotasSvc.loadMyQuotas(),
    ]);
    if (!mounted) return;
    setState(() {
      _myQuotas = (results[1] as List<UserQuota>);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final snap = _svc.snapshot;
    return SectionScaffold(
      title: 'settings.section_usage'.tr(),
      subtitle:
          'settings.section_usage_subtitle'.tr(),
      icon: Icons.bar_chart_rounded,
      actions: [
        IconButton(
          tooltip: 'common.refresh'.tr(),
          icon: Icon(Icons.refresh_rounded, size: 18, color: c.textMuted),
          onPressed: _loading ? null : _load,
        ),
      ],
      children: [
        if (_loading && snap == null) _buildLoading(c),
        if (!_loading && snap == null) _buildError(c),
        if (snap != null) ...[
          _buildHeaderTiles(c, snap),
          if (snap.hasQuota) ...[
            const SizedBox(height: 18),
            _buildQuotaCard(c, snap),
          ],
          if (_myQuotas.isNotEmpty) ...[
            const SizedBox(height: 18),
            _buildMyQuotasCard(c),
          ],
          // Per-app quotas (new 2026-04 schema — messages / tokens /
          // cost_usd / requests × custom/named windows). Self-polls
          // every 30 s against `/api/apps/{id}/quota/me`.
          const SizedBox(height: 24),
          const MyQuotasCard(),
          const SizedBox(height: 24),
          _build30dChart(c, snap),
          const SizedBox(height: 18),
          _build24hSparkline(c, snap),
          const SizedBox(height: 24),
          if (snap.costByModel.isNotEmpty) ...[
            _buildCostByModelTable(c, snap),
            const SizedBox(height: 24),
          ],
          if (snap.byApp.isNotEmpty) _buildByAppList(c, snap),
        ],
      ],
    );
  }

  // ── Header tiles ────────────────────────────────────────────────

  Widget _buildHeaderTiles(AppColors c, UsageSnapshot snap) {
    return Row(
      children: [
        Expanded(
          child: StatTile(
            label: 'settings.usage_tokens_month'.tr(),
            value: _fmtInt(snap.totalTokens),
            subValue:
                '${_fmtInt(snap.promptTokens)} in · ${_fmtInt(snap.completionTokens)} out',
            icon: Icons.bolt_rounded,
            tint: c.accentPrimary,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: StatTile(
            label: 'settings.usage_cost_month'.tr(),
            value: '\$${snap.costThisMonth.toStringAsFixed(2)}',
            subValue: snap.costByModel.isNotEmpty
                ? '${snap.costByModel.length} models'
                : 'Real cost from daemon',
            icon: Icons.attach_money_rounded,
            tint: c.green,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: StatTile(
            label: snap.hasQuota ? 'QUOTA USED' : 'QUOTA',
            value: snap.hasQuota
                ? '${(snap.quotaFraction * 100).toStringAsFixed(0)}%'
                : '∞',
            subValue: snap.hasQuota
                ? (snap.daysUntilReset != null
                    ? 'resets in ${snap.daysUntilReset} days'
                    : 'monthly')
                : 'unlimited',
            icon: Icons.speed_rounded,
            tint: snap.hasQuota && snap.quotaFraction > 0.9
                ? c.red
                : (snap.hasQuota && snap.quotaFraction > 0.7
                    ? c.orange
                    : c.purple),
          ),
        ),
      ],
    );
  }

  // ── Quota card ──────────────────────────────────────────────────

  Widget _buildQuotaCard(AppColors c, UsageSnapshot snap) {
    final frac = snap.quotaFraction;
    final tint =
        frac > 0.9 ? c.red : (frac > 0.7 ? c.orange : c.green);
    final used = snap.quotaTokenUsed ?? snap.totalTokens;
    final limit = snap.quotaTokenLimit!;
    return Container(
      padding: const EdgeInsets.all(18),
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
              Icon(Icons.speed_rounded, size: 14, color: tint),
              const SizedBox(width: 8),
              Text('settings.usage_monthly_quota'.tr(),
                  style: GoogleFonts.firaCode(
                      fontSize: 10,
                      color: c.textMuted,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8)),
              const Spacer(),
              Text(
                '${_fmtInt(used)} / ${_fmtInt(limit)}',
                style: GoogleFonts.firaCode(
                    fontSize: 12,
                    color: c.textBright,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 12),
              Text('${(frac * 100).toStringAsFixed(1)}%',
                  style: GoogleFonts.firaCode(
                      fontSize: 12,
                      color: tint,
                      fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: frac,
              minHeight: 8,
              backgroundColor: c.surfaceAlt,
              valueColor: AlwaysStoppedAnimation(tint),
            ),
          ),
          if (snap.quotaResetsAt != null) ...[
            const SizedBox(height: 10),
            Text(
              'Resets ${_fmtDate(snap.quotaResetsAt!)} · '
              '${snap.quotaTokenRemaining != null ? "${_fmtInt(snap.quotaTokenRemaining!)} remaining" : ""}',
              style: GoogleFonts.inter(
                  fontSize: 11, color: c.textMuted, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }

  // ── My quotas (server-side rules applying to the caller) ──────

  Widget _buildMyQuotasCard(AppColors c) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
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
              Text('settings.usage_your_quotas'.tr(),
                  style: GoogleFonts.firaCode(
                      fontSize: 10,
                      color: c.textMuted,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8)),
              const Spacer(),
              Text('${_myQuotas.length} rule${_myQuotas.length == 1 ? '' : 's'}',
                  style: GoogleFonts.firaCode(
                      fontSize: 10, color: c.textMuted)),
            ],
          ),
          const SizedBox(height: 12),
          for (final q in _myQuotas) _MyQuotaRow(quota: q),
        ],
      ),
    );
  }

  // ── 30d bar chart ───────────────────────────────────────────────

  Widget _build30dChart(AppColors c, UsageSnapshot snap) {
    final series = snap.timeseries30d;
    if (series.isEmpty) return const SizedBox.shrink();
    final maxTok = series
        .map((p) => p.totalTokens)
        .fold<int>(0, (a, b) => a > b ? a : b);
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('settings.usage_last_30'.tr(),
              style: GoogleFonts.firaCode(
                  fontSize: 10,
                  color: c.textMuted,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8)),
          const SizedBox(height: 14),
          SizedBox(
            height: 160,
            child: BarChart(
              BarChartData(
                alignment: BarChartAlignment.spaceAround,
                maxY: maxTok == 0 ? 1 : (maxTok * 1.15),
                gridData: const FlGridData(show: false),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  leftTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 22,
                      interval: 5,
                      getTitlesWidget: (value, _) {
                        final idx = value.toInt();
                        if (idx < 0 || idx >= series.length) {
                          return const SizedBox.shrink();
                        }
                        final day = series[idx].day;
                        if (day == null) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '${day.day}/${day.month}',
                            style: GoogleFonts.firaCode(
                                fontSize: 8, color: c.textMuted),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                barGroups: [
                  for (var i = 0; i < series.length; i++)
                    BarChartGroupData(
                      x: i,
                      barRods: [
                        BarChartRodData(
                          toY: series[i].totalTokens.toDouble(),
                          width: 6,
                          color: c.accentPrimary,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
              'Total ${_fmtInt(series.fold<int>(0, (a, b) => a + b.totalTokens))} tokens',
              style: GoogleFonts.firaCode(
                  fontSize: 10, color: c.textMuted)),
        ],
      ),
    );
  }

  // ── 24h sparkline ───────────────────────────────────────────────

  Widget _build24hSparkline(AppColors c, UsageSnapshot snap) {
    final series = snap.timeseries24h;
    if (series.isEmpty) return const SizedBox.shrink();
    final maxTok = series
        .map((p) => p.totalTokens)
        .fold<int>(0, (a, b) => a > b ? a : b);
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
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
              Text('settings.usage_last_24h'.tr(),
                  style: GoogleFonts.firaCode(
                      fontSize: 10,
                      color: c.textMuted,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8)),
              const Spacer(),
              Text(
                '${_fmtInt(series.fold<int>(0, (a, b) => a + b.totalTokens))} tokens today',
                style: GoogleFonts.firaCode(
                    fontSize: 10, color: c.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 68,
            child: LineChart(
              LineChartData(
                minY: 0,
                maxY: maxTok == 0 ? 1 : maxTok.toDouble(),
                gridData: const FlGridData(show: false),
                borderData: FlBorderData(show: false),
                titlesData: const FlTitlesData(show: false),
                lineBarsData: [
                  LineChartBarData(
                    isCurved: true,
                    curveSmoothness: 0.35,
                    color: c.cyan,
                    barWidth: 2,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      color: c.cyan.withValues(alpha: 0.15),
                    ),
                    spots: [
                      for (var i = 0; i < series.length; i++)
                        FlSpot(
                            i.toDouble(), series[i].totalTokens.toDouble()),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Cost by model ───────────────────────────────────────────────

  Widget _buildCostByModelTable(AppColors c, UsageSnapshot snap) {
    final entries = snap.costByModel.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold<double>(0, (a, b) => a + b.value);
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('settings.usage_cost_by_model'.tr(),
              style: GoogleFonts.firaCode(
                  fontSize: 10,
                  color: c.textMuted,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8)),
          const SizedBox(height: 14),
          for (final e in entries) ...[
            _ModelCostRow(
              model: e.key,
              cost: e.value,
              fraction: total == 0 ? 0 : (e.value / total),
              currency: snap.currency,
            ),
          ],
        ],
      ),
    );
  }

  // ── By app breakdown ────────────────────────────────────────────

  Widget _buildByAppList(AppColors c, UsageSnapshot snap) {
    final total =
        snap.byApp.fold<int>(0, (a, b) => a + b.tokens);
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
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
              Text('settings.usage_by_app'.tr(),
                  style: GoogleFonts.firaCode(
                      fontSize: 10,
                      color: c.textMuted,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8)),
              const Spacer(),
              Text('${snap.byApp.length} apps',
                  style: GoogleFonts.firaCode(
                      fontSize: 10, color: c.textMuted)),
            ],
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < snap.byApp.length; i++)
            _AppUsageRow(
              entry: snap.byApp[i],
              fraction: total == 0 ? 0 : (snap.byApp[i].tokens / total),
              tint: _palette(c, i),
              currency: snap.currency,
            ),
        ],
      ),
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────

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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 32, color: c.red),
              const SizedBox(height: 10),
              Text(
                _svc.error ?? 'Could not load usage data',
                style:
                    GoogleFonts.firaCode(fontSize: 11, color: c.textMuted),
              ),
              const SizedBox(height: 14),
              ElevatedButton(
                onPressed: _load,
                child: Text('common.retry'.tr(),
                    style: GoogleFonts.inter(fontSize: 12)),
              ),
            ],
          ),
        ),
      );

  Color _palette(AppColors c, int i) {
    final p = [c.accentPrimary, c.purple, c.green, c.orange, c.cyan, c.red];
    return p[i % p.length];
  }

  String _fmtInt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return n.toString();
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

// ─── Row widgets ────────────────────────────────────────────────────

class _MyQuotaRow extends StatelessWidget {
  final UserQuota quota;
  const _MyQuotaRow({required this.quota});

  Color _scopeTint(AppColors c) {
    switch (quota.scopeType) {
      case 'user':
        return c.accentPrimary;
      case 'user_app':
        return c.purple;
      case 'app':
        return c.green;
      default:
        return c.textMuted;
    }
  }

  String _label() {
    switch (quota.scopeType) {
      case 'user':
        return 'Cross-app · ${quota.period}';
      case 'user_app':
        return '${quota.appId ?? "any app"} · ${quota.period}';
      case 'app':
        return 'Team · ${quota.appId ?? quota.scopeId} · ${quota.period}';
      default:
        return '${quota.scopeType} · ${quota.period}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final frac = quota.fraction;
    final tint = frac > 0.9 ? c.red : (frac > 0.7 ? c.orange : c.green);
    final scopeTint = _scopeTint(c);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
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
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _label(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                      fontSize: 12.5,
                      color: c.textBright,
                      fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '${_fmt(quota.tokensUsed ?? 0)} / ${_fmt(quota.tokensLimit)}',
                style: GoogleFonts.firaCode(
                    fontSize: 11, color: c.text,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 42,
                child: Text(
                  '${(frac * 100).toStringAsFixed(0)}%',
                  textAlign: TextAlign.right,
                  style: GoogleFonts.firaCode(
                      fontSize: 10.5, color: tint),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: frac,
              minHeight: 5,
              backgroundColor: c.surfaceAlt,
              valueColor: AlwaysStoppedAnimation(tint),
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

class _ModelCostRow extends StatelessWidget {
  final String model;
  final double cost;
  final double fraction;
  final String currency;
  const _ModelCostRow({
    required this.model,
    required this.cost,
    required this.fraction,
    required this.currency,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  model,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.firaCode(
                      fontSize: 11.5,
                      color: c.textBright,
                      fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '${_currencySymbol(currency)}${cost.toStringAsFixed(2)}',
                style: GoogleFonts.firaCode(
                    fontSize: 11.5,
                    color: c.text,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 42,
                child: Text(
                  '${(fraction * 100).toStringAsFixed(0)}%',
                  textAlign: TextAlign.right,
                  style: GoogleFonts.firaCode(
                      fontSize: 10, color: c.textMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 4,
              backgroundColor: c.surfaceAlt,
              valueColor: AlwaysStoppedAnimation(c.green),
            ),
          ),
        ],
      ),
    );
  }

  static String _currencySymbol(String c) {
    switch (c.toUpperCase()) {
      case 'USD':
        return '\$';
      case 'EUR':
        return '€';
      case 'GBP':
        return '£';
      default:
        return '$c ';
    }
  }
}

class _AppUsageRow extends StatelessWidget {
  final UsageByApp entry;
  final double fraction;
  final Color tint;
  final String currency;
  const _AppUsageRow({
    required this.entry,
    required this.fraction,
    required this.tint,
    required this.currency,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: tint,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  entry.appName ?? entry.appId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                      fontSize: 12.5,
                      color: c.textBright,
                      fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                _formatNumber(entry.tokens),
                style: GoogleFonts.firaCode(
                    fontSize: 11.5,
                    color: c.text,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 10),
              Text(
                '\$${entry.costUsd.toStringAsFixed(2)}',
                style: GoogleFonts.firaCode(
                    fontSize: 11, color: c.textMuted),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 44,
                child: Text(
                  '${(fraction * 100).toStringAsFixed(0)}%',
                  textAlign: TextAlign.right,
                  style: GoogleFonts.firaCode(
                      fontSize: 10.5, color: c.textMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 5,
              backgroundColor: c.surfaceAlt,
              valueColor: AlwaysStoppedAnimation(tint),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatNumber(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return n.toString();
  }
}
