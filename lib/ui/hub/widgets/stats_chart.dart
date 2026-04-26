/// Stats tab on the Package detail page. Range selector (7/30/90d),
/// downloads area chart, total + avg/day summary cards, and a table
/// of downloads by version.
///
/// Mirror of web `StatsChart`
/// (`digitorn_web/src/components/hub/stats-chart.tsx`).
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../models/hub/hub_models.dart';
import '../../../services/hub_service.dart';
import '../../../theme/app_theme.dart';

class _Range {
  final int days;
  final String label;
  const _Range(this.days, this.label);
}

const _ranges = [
  _Range(7, '7d'),
  _Range(30, '30d'),
  _Range(90, '90d'),
];

class StatsChart extends StatefulWidget {
  final String publisher;
  final String packageId;

  const StatsChart({
    super.key,
    required this.publisher,
    required this.packageId,
  });

  @override
  State<StatsChart> createState() => _StatsChartState();
}

class _StatsChartState extends State<StatsChart> {
  int _range = 30;
  HubPackageStats? _data;
  bool _loading = false;
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
      final s = await HubService().stats(
        widget.publisher,
        widget.packageId,
        rangeDays: _range,
      );
      if (!mounted) return;
      setState(() {
        _data = s;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final data = _data;
    final versions = data == null
        ? const <MapEntry<String, int>>[]
        : (data.byVersion.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(Icons.trending_up_rounded, size: 14, color: c.blue),
                const SizedBox(width: 6),
                Text(
                  'Downloads',
                  style: GoogleFonts.inter(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: c.textBright,
                  ),
                ),
              ],
            ),
            _RangeSwitcher(
              value: _range,
              onChange: (v) {
                setState(() => _range = v);
                _load();
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _Card(
                label: 'Total',
                value: data == null
                    ? '–'
                    : data.totalDownloadsInRange.toString(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Card(
                label: 'Avg / day',
                value: data == null ? '–' : data.avgPerDay.toStringAsFixed(1),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: c.surface,
            border: Border.all(color: c.border),
            borderRadius: BorderRadius.circular(10),
          ),
          child: SizedBox(
            height: 220,
            child: _loading && data == null
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Text(
                          _error!,
                          style: TextStyle(fontSize: 12, color: c.red),
                          textAlign: TextAlign.center,
                        ),
                      )
                    : (data == null || data.series.isEmpty)
                        ? Center(
                            child: Text(
                              'No downloads in this range yet.',
                              style: TextStyle(
                                fontSize: 12,
                                color: c.textMuted,
                              ),
                            ),
                          )
                        : _AreaChart(series: data.series),
          ),
        ),
        if (versions.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: c.surface,
              border: Border.all(color: c.border),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: c.border)),
                  ),
                  child: Text(
                    'By version',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: c.textBright,
                    ),
                  ),
                ),
                for (var i = 0; i < versions.length; i++) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          versions[i].key,
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 12,
                            color: c.text,
                          ),
                        ),
                        Text(
                          versions[i].value.toString(),
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 12,
                            color: c.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (i < versions.length - 1)
                    Divider(height: 1, color: c.border),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _RangeSwitcher extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChange;
  const _RangeSwitcher({required this.value, required this.onChange});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: _ranges.map((r) {
          final active = r.days == value;
          return InkWell(
            onTap: () => onChange(r.days),
            borderRadius: BorderRadius.circular(5),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: active ? c.surfaceAlt : Colors.transparent,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                r.label,
                style: GoogleFonts.inter(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: active ? c.textBright : c.textMuted,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final String label;
  final String value;
  const _Card({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: GoogleFonts.inter(
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.5,
              color: c.textMuted,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.4,
              color: c.textBright,
            ),
          ),
        ],
      ),
    );
  }
}

class _AreaChart extends StatelessWidget {
  final List<HubStatsPoint> series;
  const _AreaChart({required this.series});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final spots = <FlSpot>[];
    for (var i = 0; i < series.length; i++) {
      spots.add(FlSpot(i.toDouble(), series[i].downloads.toDouble()));
    }
    final maxY = spots
            .map((s) => s.y)
            .fold<double>(0, (m, v) => v > m ? v : m) *
        1.15;

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: (series.length - 1).toDouble().clamp(1, double.infinity),
        minY: 0,
        maxY: maxY <= 0 ? 1 : maxY,
        gridData: FlGridData(
          drawVerticalLine: false,
          horizontalInterval: maxY <= 0 ? 1 : maxY / 4,
          getDrawingHorizontalLine: (_) => FlLine(
            color: c.border,
            strokeWidth: 1,
            dashArray: const [3, 3],
          ),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              getTitlesWidget: (v, _) => Text(
                v.toInt().toString(),
                style: TextStyle(fontSize: 10, color: c.textMuted),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 18,
              interval: (series.length / 6).clamp(1, 30).toDouble(),
              getTitlesWidget: (v, _) {
                final i = v.toInt();
                if (i < 0 || i >= series.length) return const SizedBox();
                final d = series[i].date;
                return Text(
                  d.length >= 5 ? d.substring(5) : d,
                  style: TextStyle(fontSize: 10, color: c.textMuted),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => c.surfaceAlt,
            getTooltipItems: (items) => items
                .map(
                  (it) => LineTooltipItem(
                    '${series[it.x.toInt()].date}\n${it.y.toInt()} downloads',
                    GoogleFonts.inter(fontSize: 11, color: c.textBright),
                  ),
                )
                .toList(),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.25,
            color: c.blue,
            barWidth: 1.5,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  c.blue.withValues(alpha: 0.35),
                  c.blue.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
