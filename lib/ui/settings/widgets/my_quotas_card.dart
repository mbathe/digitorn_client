/// Self-service "my quotas" card — one collapsible row per installed
/// app showing the caller's per-(metric, window) usage. Polls
/// `/api/apps/{app_id}/quota/me` every 30 s per the spec.
///
/// Layout is compact on purpose: users with many installed apps need
/// to scan the list quickly. Apps with warnings/exceedances expand by
/// default; healthy apps stay collapsed behind a status badge.
library;

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../models/app_summary.dart';
import '../../../models/quota.dart';
import '../../../services/app_admin_service.dart';
import '../../../services/apps_service.dart';
import '../../../theme/app_theme.dart';
import 'quota_bar_card.dart';

class MyQuotasCard extends StatefulWidget {
  const MyQuotasCard({super.key});

  @override
  State<MyQuotasCard> createState() => _MyQuotasCardState();
}

class _MyQuotasCardState extends State<MyQuotasCard> {
  final _svc = AppAdminService();
  final Map<String, QuotaResponse?> _byApp = {};
  final Set<String> _loading = {};
  final Set<String> _manuallyToggled = {};
  final Set<String> _expanded = {};
  Timer? _pollTimer;
  bool _bootLoading = true;
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    AppsService().addListener(_onAppsChanged);
    _refreshAll();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refreshAll(silent: true),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    AppsService().removeListener(_onAppsChanged);
    super.dispose();
  }

  void _onAppsChanged() {
    if (mounted) setState(() {});
  }

  List<AppSummary> get _apps => AppsService()
      .apps
      .where((a) => a.runtimeStatus == 'running')
      .toList();

  Future<void> _refreshAll({bool silent = false}) async {
    if (!silent && mounted) setState(() => _bootLoading = true);
    final apps = _apps;
    for (final a in apps) {
      if (!silent && mounted) setState(() => _loading.add(a.appId));
      final q = await _svc.getMyQuota(a.appId);
      if (!mounted) return;
      setState(() {
        _byApp[a.appId] = q;
        _loading.remove(a.appId);
      });
    }
    if (mounted) setState(() => _bootLoading = false);
  }

  _Severity _severityFor(QuotaResponse? r) {
    if (r == null) return _Severity.none;
    final flat = r.usageFlat;
    if (flat.isEmpty &&
        r.effective.concurrentSessions == null &&
        r.effective.messagesPerSession == null) {
      return _Severity.none;
    }
    if (flat.any((e) => e.counter.exceeded)) return _Severity.exceeded;
    if (flat.any((e) => e.counter.nearLimit)) return _Severity.warning;
    return _Severity.ok;
  }

  bool _isExpanded(String appId, _Severity sev) {
    if (_manuallyToggled.contains(appId)) {
      return _expanded.contains(appId);
    }
    return sev == _Severity.exceeded || sev == _Severity.warning;
  }

  void _toggle(String appId, _Severity sev) {
    setState(() {
      final currentlyOpen = _isExpanded(appId, sev);
      _manuallyToggled.add(appId);
      if (currentlyOpen) {
        _expanded.remove(appId);
      } else {
        _expanded.add(appId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final apps = _apps;
    if (_bootLoading && _byApp.isEmpty) {
      return _shell(
        c,
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
                strokeWidth: 1.5, color: c.textMuted),
          ),
        ),
      );
    }
    if (apps.isEmpty) {
      return _shell(
        c,
        child: Row(
          children: [
            Icon(Icons.data_usage_rounded, size: 14, color: c.textMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Text('settings.quota_no_running_apps'.tr(),
                  style: GoogleFonts.inter(
                      fontSize: 12, color: c.textMuted)),
            ),
          ],
        ),
      );
    }

    final entries = apps
        .map((a) => (app: a, response: _byApp[a.appId]))
        .toList()
      ..sort((a, b) {
        final sa = _severityFor(a.response).index;
        final sb = _severityFor(b.response).index;
        if (sa != sb) return sb.compareTo(sa);
        return a.app.name
            .toLowerCase()
            .compareTo(b.app.name.toLowerCase());
      });

    final visible = entries.where((e) {
      if (_filter == 'all') return true;
      final sev = _severityFor(e.response);
      return switch (_filter) {
        'exceeded' => sev == _Severity.exceeded,
        'warning' => sev == _Severity.warning || sev == _Severity.exceeded,
        _ => true,
      };
    }).toList();

    final counts = _buildCounts(entries);

    return _shell(
      c,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            total: entries.length,
            exceeded: counts.exceeded,
            warning: counts.warning,
            filter: _filter,
            onFilter: (v) => setState(() => _filter = v),
            onRefresh: () => _refreshAll(),
          ),
          const SizedBox(height: 10),
          if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'settings.quota_filter_empty'.tr(),
                style: GoogleFonts.inter(fontSize: 11, color: c.textMuted),
                textAlign: TextAlign.center,
              ),
            )
          else
            ...visible.map((e) {
              final sev = _severityFor(e.response);
              return _AppRow(
                app: e.app,
                response: e.response,
                severity: sev,
                loading: _loading.contains(e.app.appId),
                expanded: _isExpanded(e.app.appId, sev),
                onToggle: () => _toggle(e.app.appId, sev),
              );
            }),
        ],
      ),
    );
  }

  Widget _shell(AppColors c, {required Widget child}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: child,
    );
  }

  ({int exceeded, int warning, int ok}) _buildCounts(
      List<({AppSummary app, QuotaResponse? response})> entries) {
    var ex = 0, wn = 0, ok = 0;
    for (final e in entries) {
      switch (_severityFor(e.response)) {
        case _Severity.exceeded:
          ex++;
          break;
        case _Severity.warning:
          wn++;
          break;
        case _Severity.ok:
          ok++;
          break;
        case _Severity.none:
          break;
      }
    }
    return (exceeded: ex, warning: wn, ok: ok);
  }
}

enum _Severity { none, ok, warning, exceeded }

class _Header extends StatelessWidget {
  final int total;
  final int exceeded;
  final int warning;
  final String filter;
  final ValueChanged<String> onFilter;
  final VoidCallback onRefresh;
  const _Header({
    required this.total,
    required this.exceeded,
    required this.warning,
    required this.filter,
    required this.onFilter,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        Text('settings.quota_section_title'.tr(),
            style: GoogleFonts.firaCode(
                fontSize: 10,
                color: c.textMuted,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8)),
        const SizedBox(width: 10),
        _FilterChip(
            label: 'settings.quota_filter_all'
                .tr(namedArgs: {'n': '$total'}),
            active: filter == 'all',
            tone: c.textMuted,
            onTap: () => onFilter('all')),
        const SizedBox(width: 6),
        if (exceeded > 0) ...[
          _FilterChip(
              label: 'settings.quota_filter_exceeded'
                  .tr(namedArgs: {'n': '$exceeded'}),
              active: filter == 'exceeded',
              tone: c.red,
              onTap: () => onFilter('exceeded')),
          const SizedBox(width: 6),
        ],
        if (warning > 0)
          _FilterChip(
              label: 'settings.quota_filter_warning'
                  .tr(namedArgs: {'n': '$warning'}),
              active: filter == 'warning',
              tone: c.orange,
              onTap: () => onFilter('warning')),
        const Spacer(),
        IconButton(
          tooltip: 'settings.refresh'.tr(),
          iconSize: 14,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(
              minWidth: 28, minHeight: 28),
          icon: Icon(Icons.refresh_rounded, color: c.textMuted),
          onPressed: onRefresh,
        ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool active;
  final Color tone;
  final VoidCallback onTap;
  const _FilterChip({
    required this.label,
    required this.active,
    required this.tone,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: active ? tone.withValues(alpha: 0.15) : c.surfaceAlt,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: active ? tone.withValues(alpha: 0.6) : c.border),
        ),
        child: Text(
          label,
          style: GoogleFonts.firaCode(
            fontSize: 9.5,
            color: active ? tone : c.textMuted,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
  }
}

class _AppRow extends StatelessWidget {
  final AppSummary app;
  final QuotaResponse? response;
  final _Severity severity;
  final bool loading;
  final bool expanded;
  final VoidCallback onToggle;

  const _AppRow({
    required this.app,
    required this.response,
    required this.severity,
    required this.loading,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final flat = response?.usageFlat ?? const [];
    final concurrent = response?.effective.concurrentSessions;
    final perSession = response?.effective.messagesPerSession;
    final isNoQuota = severity == _Severity.none;
    final tone = switch (severity) {
      _Severity.exceeded => c.red,
      _Severity.warning => c.orange,
      _Severity.ok => c.green,
      _Severity.none => c.textDim,
    };
    final topPct = flat.isEmpty
        ? 0.0
        : flat.map((e) => e.counter.percent).reduce((a, b) => a > b ? a : b);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: isNoQuota ? null : onToggle,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Row(
                children: [
                  _AppIcon(app: app),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          app.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: c.textBright),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          _summaryLine(flat, concurrent, perSession),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.firaCode(
                              fontSize: 10, color: c.textDim),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  _StatusPill(
                      severity: severity,
                      topPct: topPct,
                      tone: tone,
                      isNoQuota: isNoQuota),
                  if (loading) ...[
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.2, color: c.textMuted),
                    ),
                  ],
                  if (!isNoQuota) ...[
                    const SizedBox(width: 4),
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: c.textMuted,
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (expanded && !isNoQuota) ...[
            Divider(height: 1, color: c.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final twoCol = constraints.maxWidth >= 520;
                  final tileWidth = twoCol
                      ? (constraints.maxWidth - 8) / 2
                      : constraints.maxWidth;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (flat.isNotEmpty)
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final entry in flat)
                              SizedBox(
                                width: tileWidth,
                                child: QuotaBarCard(
                                  metric: entry.metric,
                                  window: entry.window,
                                  counter: entry.counter,
                                  compact: true,
                                ),
                              ),
                          ],
                        ),
                      if (concurrent != null || perSession != null) ...[
                        const SizedBox(height: 8),
                        _SessionLimits(
                          concurrentSessions: concurrent,
                          messagesPerSession: perSession,
                        ),
                      ],
                      if (response?.updatedAt != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          'settings.quota_updated_at'.tr(namedArgs: {
                            'when': _shortAgo(response!.updatedAt!),
                          }),
                          style: GoogleFonts.firaCode(
                              fontSize: 9.5, color: c.textDim),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _summaryLine(
    List<({String metric, String window, UsageCounter counter})> flat,
    int? concurrent,
    int? perSession,
  ) {
    if (flat.isEmpty &&
        concurrent == null &&
        perSession == null) {
      return 'settings.quota_no_rules'.tr();
    }
    final parts = <String>[];
    if (flat.isNotEmpty) {
      parts.add('settings.quota_rules_count'
          .tr(namedArgs: {'n': '${flat.length}'}));
    }
    if (concurrent != null) {
      parts.add('$concurrent× ${'settings.quota_sessions_short'.tr()}');
    }
    if (perSession != null) {
      parts.add('$perSession× ${'settings.quota_msgs_short'.tr()}');
    }
    return parts.join(' · ');
  }

  static String _shortAgo(DateTime dt) {
    final d = DateTime.now().toUtc().difference(dt.toUtc());
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    if (d.inDays < 30) return '${d.inDays}d ago';
    return '${(d.inDays / 30).floor()}mo ago';
  }
}

class _StatusPill extends StatelessWidget {
  final _Severity severity;
  final double topPct;
  final Color tone;
  final bool isNoQuota;
  const _StatusPill({
    required this.severity,
    required this.topPct,
    required this.tone,
    required this.isNoQuota,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (isNoQuota) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: c.border),
        ),
        child: Text(
          'settings.quota_pill_none'.tr(),
          style: GoogleFonts.firaCode(
              fontSize: 9, color: c.textDim, fontWeight: FontWeight.w700),
        ),
      );
    }
    final pctText = (topPct.clamp(0, 9.99) * 100).round();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: tone.withValues(alpha: 0.5)),
      ),
      child: Text(
        '$pctText%',
        style: GoogleFonts.firaCode(
          fontSize: 9.5,
          color: tone,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

class _AppIcon extends StatelessWidget {
  final AppSummary app;
  const _AppIcon({required this.app});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hasEmoji = app.icon.trim().isNotEmpty;
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.border),
      ),
      child: hasEmoji
          ? Text(app.icon, style: const TextStyle(fontSize: 12))
          : Icon(Icons.apps_rounded, size: 12, color: c.textMuted),
    );
  }
}

class _SessionLimits extends StatelessWidget {
  final int? concurrentSessions;
  final int? messagesPerSession;
  const _SessionLimits({
    required this.concurrentSessions,
    required this.messagesPerSession,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final rows = <Widget>[];
    if (concurrentSessions != null) {
      rows.add(_limitRow(
          c,
          Icons.timeline_rounded,
          'settings.metric_concurrent_sessions'.tr(),
          concurrentSessions.toString()));
    }
    if (messagesPerSession != null) {
      rows.add(_limitRow(
          c,
          Icons.message_rounded,
          'settings.metric_messages_per_session'.tr(),
          messagesPerSession.toString()));
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }

  Widget _limitRow(AppColors c, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 12, color: c.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label,
                style: GoogleFonts.inter(
                    fontSize: 11, color: c.text)),
          ),
          Text(value,
              style: GoogleFonts.firaCode(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: c.textBright)),
        ],
      ),
    );
  }
}
