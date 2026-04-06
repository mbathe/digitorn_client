import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:provider/provider.dart';
import '../../models/session_metrics.dart';
import '../../theme/app_theme.dart';

class ContextModal {
  static void show(BuildContext context) {
    showDialog(
      context: context,
      barrierColor: Colors.black38,
      builder: (_) => const _ContextDialog(),
    );
  }
}

class _ContextDialog extends StatelessWidget {
  const _ContextDialog();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final m = context.watch<SessionMetrics>();

    final total = m.contextMax > 0 ? m.contextMax : 128000;
    final used = m.contextEstimated;
    final available = m.availableTokens > 0 ? m.availableTokens : total - used;
    final pct = total > 0 ? (used / total * 100).round() : 0;

    // Pie chart sections
    final sections = <_Section>[
      if (m.systemPromptTokens > 0)
        _Section('System Prompt', m.systemPromptTokens, const Color(0xFF3B82F6)),
      if (m.toolsSchemaTokens > 0)
        _Section('Tools Schema', m.toolsSchemaTokens, const Color(0xFFA78BFA)),
      if (m.messageHistoryTokens > 0)
        _Section('Messages', m.messageHistoryTokens, const Color(0xFF22C55E)),
      if (m.outputReserved > 0)
        _Section('Output Reserved', m.outputReserved, const Color(0xFFF59E0B)),
      _Section('Available', available, c.border),
    ];

    // Remove zero sections
    sections.removeWhere((s) => s.value <= 0);

    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: c.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Row(
                children: [
                  Text('Context Window',
                    style: GoogleFonts.inter(
                      fontSize: 16, fontWeight: FontWeight.w600, color: c.textBright)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Icon(Icons.close_rounded, size: 18, color: c.textMuted),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                m.model.isNotEmpty ? m.model : 'Unknown model',
                style: GoogleFonts.firaCode(fontSize: 12, color: c.textMuted),
              ),
              const SizedBox(height: 20),

              // Pie chart
              SizedBox(
                height: 180,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    PieChart(
                      PieChartData(
                        sectionsSpace: 2,
                        centerSpaceRadius: 55,
                        sections: sections.map((s) => PieChartSectionData(
                          value: s.value.toDouble(),
                          color: s.color,
                          radius: 30,
                          showTitle: false,
                        )).toList(),
                      ),
                    ),
                    // Center label
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$pct%',
                          style: GoogleFonts.inter(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                            color: pct < 60
                                ? c.green
                                : pct < 85
                                    ? c.orange
                                    : c.red,
                          ),
                        ),
                        Text('used',
                          style: GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Legend
              ...sections.where((s) => s.label != 'Available').map((s) => _LegendRow(
                color: s.color,
                label: s.label,
                tokens: s.value,
                pct: total > 0 ? (s.value / total * 100) : 0,
                textColor: c.text,
                mutedColor: c.textMuted,
              )),
              Divider(height: 16, color: c.border),

              // Summary stats
              _StatRow(label: 'Total Context', value: m.fmt(total), c: c),
              _StatRow(label: 'Used', value: m.fmt(used), c: c),
              _StatRow(label: 'Available', value: m.fmt(available), c: c),
              if (m.compactions > 0)
                _StatRow(label: 'Compactions', value: '${m.compactions}', c: c),
              if (m.effectiveMax > 0 && m.effectiveMax != total)
                _StatRow(label: 'Effective Max', value: m.fmt(m.effectiveMax), c: c),
            ],
          ),
        ),
      ),
    );
  }
}

class _Section {
  final String label;
  final int value;
  final Color color;
  const _Section(this.label, this.value, this.color);
}

class _LegendRow extends StatelessWidget {
  final Color color;
  final String label;
  final int tokens;
  final double pct;
  final Color textColor;
  final Color mutedColor;
  const _LegendRow({
    required this.color, required this.label, required this.tokens,
    required this.pct, required this.textColor, required this.mutedColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            width: 10, height: 10,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label,
              style: GoogleFonts.inter(fontSize: 13, color: textColor)),
          ),
          Text(_fmt(tokens),
            style: GoogleFonts.firaCode(fontSize: 12, color: mutedColor)),
          const SizedBox(width: 8),
          SizedBox(
            width: 40,
            child: Text('${pct.toStringAsFixed(1)}%',
              textAlign: TextAlign.right,
              style: GoogleFonts.firaCode(fontSize: 12, color: mutedColor)),
          ),
        ],
      ),
    );
  }

  String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return n.toString();
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final String value;
  final AppColors c;
  const _StatRow({required this.label, required this.value, required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(label, style: GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
          const Spacer(),
          Text(value, style: GoogleFonts.firaCode(fontSize: 12, color: c.text)),
        ],
      ),
    );
  }
}
