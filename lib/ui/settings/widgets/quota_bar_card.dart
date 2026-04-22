/// Per-(metric, window) quota progress card — used both in the
/// user Settings view (self-service) and on the admin "my quota for
/// this user" preview. Pure stateless presentation over a
/// [UsageCounter]; the parent is responsible for fetching / polling.
library;

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../models/quota.dart';
import '../../../theme/app_theme.dart';

/// Rendered inside a card — a labelled progress bar for one
/// `(metric, window)` pair with a live reset-countdown underneath.
class QuotaBarCard extends StatelessWidget {
  final String metric;
  final String window;
  final UsageCounter counter;
  final bool compact;

  const QuotaBarCard({
    super.key,
    required this.metric,
    required this.window,
    required this.counter,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tint = counter.exceeded
        ? c.red
        : counter.nearLimit
            ? c.orange
            : c.accentPrimary;
    final pct = counter.percent.clamp(0.0, 1.0);
    final pctText = (counter.percent * 100).round();
    return Container(
      padding: EdgeInsets.all(compact ? 12 : 16),
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
              Icon(_metricIcon(metric), size: 14, color: tint),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  metricLabel(metric),
                  style: GoogleFonts.inter(
                    fontSize: compact ? 12 : 13,
                    fontWeight: FontWeight.w700,
                    color: c.textBright,
                  ),
                ),
              ),
              Text(
                '${formatCounterValue(counter.current, metric)} / '
                '${formatCounterValue(counter.limit, metric)}',
                style: GoogleFonts.firaCode(
                  fontSize: compact ? 11 : 12,
                  color: counter.exceeded ? c.red : c.textBright,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Semantics(
            label: metricLabel(metric),
            value: '$pctText%',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: compact ? 6 : 8,
                backgroundColor: c.surfaceAlt,
                valueColor: AlwaysStoppedAnimation(tint),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                humanWindow(window),
                style: GoogleFonts.firaCode(
                    fontSize: 10, color: c.textMuted),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: CountdownText(
                  resetAt: counter.resetAt,
                  reset: counter.reset,
                ),
              ),
              Text('$pctText%',
                  style: GoogleFonts.firaCode(
                    fontSize: 10,
                    color: tint,
                    fontWeight: FontWeight.w700,
                  )),
            ],
          ),
          if (counter.exceeded) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, size: 12, color: c.red),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'settings.quota_exceeded_hint'.tr(),
                    style: GoogleFonts.inter(
                        fontSize: 10.5, color: c.red),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Formatters ──────────────────────────────────────────────────

/// Localised label for a metric key.
String metricLabel(String metric) {
  final key = 'settings.metric_$metric';
  final translated = key.tr();
  // `easy_localization` returns the key untouched when it's missing
  // — fall back to a title-cased metric name so the UI stays
  // readable even if we ship before the i18n update.
  if (translated == key) {
    return metric
        .replaceAll('_', ' ')
        .split(' ')
        .map((w) =>
            w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }
  return translated;
}

/// Icon hint for a metric — keeps the card scannable at a glance.
IconData _metricIcon(String metric) {
  switch (metric) {
    case 'requests':
      return Icons.bolt_rounded;
    case 'messages':
      return Icons.chat_bubble_outline_rounded;
    case 'tokens_input':
      return Icons.download_rounded;
    case 'tokens_output':
      return Icons.upload_rounded;
    case 'tokens_total':
      return Icons.memory_rounded;
    case 'cost_usd':
      return Icons.payments_outlined;
    default:
      return Icons.data_usage_rounded;
  }
}

/// Turn a window key like `per_day` / `5h` / `30m` into a localised
/// human label.
String humanWindow(String window) {
  switch (window) {
    case 'per_minute':
      return 'settings.window_per_minute'.tr();
    case 'per_hour':
      return 'settings.window_per_hour'.tr();
    case 'per_day':
      return 'settings.window_per_day'.tr();
    case 'per_week':
      return 'settings.window_per_week'.tr();
    case 'per_month':
      return 'settings.window_per_month'.tr();
  }
  final parsed = parseCustomWindow(window);
  if (parsed != null) {
    final unit = switch (parsed.unit) {
      's' => 'settings.unit_seconds'.tr(),
      'm' => 'settings.unit_minutes'.tr(),
      'h' => 'settings.unit_hours'.tr(),
      'd' => 'settings.unit_days'.tr(),
      'w' => 'settings.unit_weeks'.tr(),
      _ => parsed.unit,
    };
    return 'settings.rolling_window'
        .tr(namedArgs: {'n': '${parsed.count}', 'unit': unit});
  }
  return window;
}

// ─── Reset countdown ─────────────────────────────────────────────

/// Live-updating countdown to the next reset. Re-schedules itself
/// so the tick rate matches the remaining duration: every second
/// when < 1 min left, every 15 s when < 1 h, every minute otherwise.
/// This keeps the UI fresh without burning CPU on multi-hour resets.
class CountdownText extends StatefulWidget {
  final DateTime resetAt;
  final ResetStrategy reset;
  final TextStyle? style;

  const CountdownText({
    super.key,
    required this.resetAt,
    required this.reset,
    this.style,
  });

  @override
  State<CountdownText> createState() => _CountdownTextState();
}

class _CountdownTextState extends State<CountdownText> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(CountdownText old) {
    super.didUpdateWidget(old);
    if (old.resetAt != widget.resetAt) _schedule();
  }

  void _schedule() {
    _t?.cancel();
    final remaining =
        widget.resetAt.difference(DateTime.now().toUtc()).abs();
    final interval = remaining.inMinutes < 1
        ? const Duration(seconds: 1)
        : remaining.inHours < 1
            ? const Duration(seconds: 15)
            : const Duration(minutes: 1);
    _t = Timer(interval, () {
      if (mounted) setState(_schedule);
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Text(
      _humanReset(widget.resetAt, widget.reset),
      overflow: TextOverflow.ellipsis,
      style: widget.style ??
          GoogleFonts.firaCode(fontSize: 10, color: c.textMuted),
    );
  }
}

String _humanReset(DateTime resetAt, ResetStrategy reset) {
  final now = DateTime.now().toUtc();
  final d = resetAt.difference(now);
  if (d.isNegative) return 'settings.reset_imminent'.tr();
  final count = _humanDuration(d);
  switch (reset) {
    case ResetStrategy.rollingFromFirst:
      return 'settings.rolling_reset_in'.tr(namedArgs: {'dur': count});
    case ResetStrategy.fixedDaily:
      final localTime = resetAt.toLocal();
      final hh = localTime.hour.toString().padLeft(2, '0');
      final mm = localTime.minute.toString().padLeft(2, '0');
      return 'settings.fixed_daily_reset'
          .tr(namedArgs: {'time': '$hh:$mm', 'dur': count});
    case ResetStrategy.fixedWeekly:
      return 'settings.fixed_weekly_reset'
          .tr(namedArgs: {'dur': count});
    case ResetStrategy.fixedMonthly:
      final local = resetAt.toLocal();
      final date = '${local.day}/${local.month}';
      return 'settings.fixed_monthly_reset'
          .tr(namedArgs: {'date': date, 'dur': count});
    case ResetStrategy.fixed:
      return 'settings.fixed_reset_in'.tr(namedArgs: {'dur': count});
  }
}

String _humanDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) {
    final m = d.inMinutes.remainder(60);
    return m > 0 ? '${d.inHours}h ${m}m' : '${d.inHours}h';
  }
  return '${d.inDays}d';
}
