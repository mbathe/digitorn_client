import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:syncfusion_flutter_core/theme.dart';
import 'package:syncfusion_flutter_datagrid/datagrid.dart';
import '../../services/database_service.dart';
import '../../theme/app_theme.dart';

/// Passive observer of database tool_calls flowing through the SSE
/// stream. Renders one card per call, with per-action sub-renderers
/// (tabular grid for SELECTs, JSON tree for schema, status block for
/// transactions, etc.).
///
/// The user does **not** drive queries from here — that's the agent's
/// job. This panel is purely a window into what the agent has been
/// doing against the database.
class DatabasePanel extends StatefulWidget {
  const DatabasePanel({super.key});

  @override
  State<DatabasePanel> createState() => _DatabasePanelState();
}

class _DatabasePanelState extends State<DatabasePanel> {
  final ScrollController _scrollCtrl = ScrollController();
  final Set<String> _collapsed = {};
  bool _autoScroll = true;
  int _lastSeenCount = 0;

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _maybeAutoScroll(int currentCount) {
    if (!_autoScroll) return;
    if (currentCount == _lastSeenCount) return;
    _lastSeenCount = currentCount;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  void _toggle(String id) {
    setState(() {
      if (_collapsed.contains(id)) {
        _collapsed.remove(id);
      } else {
        _collapsed.add(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final db = context.watch<DatabaseService>();
    _maybeAutoScroll(db.calls.length);

    return Container(
      color: c.bg,
      child: Column(
        children: [
          _buildHeader(c, db),
          Container(height: 1, color: c.border),
          Expanded(child: _buildBody(c, db)),
        ],
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────

  Widget _buildHeader(AppColors c, DatabaseService db) {
    final active = db.activeConnection;
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: c.surface,
      child: Row(
        children: [
          Icon(Icons.storage_rounded, size: 14, color: c.green),
          const SizedBox(width: 8),
          if (active != null) ...[
            _ConnectionDot(connected: true, color: c.green),
            const SizedBox(width: 6),
            Text(
              active.name ?? active.id,
              style: GoogleFonts.firaCode(
                  fontSize: 12, color: c.text, fontWeight: FontWeight.w600),
            ),
            if (active.engine != null) ...[
              const SizedBox(width: 6),
              _Tag(label: active.engine!.toUpperCase(), color: c.green),
            ],
            if (active.database != null) ...[
              const SizedBox(width: 6),
              Text('· ${active.database}',
                  style: GoogleFonts.firaCode(
                      fontSize: 10, color: c.textMuted)),
            ],
          ] else ...[
            _ConnectionDot(connected: false, color: c.textMuted),
            const SizedBox(width: 6),
            Text(
              db.connections.isEmpty
                  ? 'No connection observed yet'
                  : '${db.connections.length} known connection(s)',
              style: GoogleFonts.firaCode(fontSize: 11, color: c.textMuted),
            ),
          ],
          const Spacer(),
          if (db.runningCount > 0) ...[
            _Tag(
              label: '${db.runningCount} running',
              color: c.orange,
            ),
            const SizedBox(width: 8),
          ],
          if (db.errorCount > 0) ...[
            _Tag(
              label: '${db.errorCount} failed',
              color: c.red,
            ),
            const SizedBox(width: 8),
          ],
          _DbIconBtn(
            icon: _autoScroll
                ? Icons.vertical_align_bottom_rounded
                : Icons.pause_circle_outline_rounded,
            tooltip: _autoScroll ? 'Auto-scroll on' : 'Auto-scroll paused',
            onTap: () => setState(() => _autoScroll = !_autoScroll),
            active: _autoScroll,
          ),
          _DbIconBtn(
            icon: Icons.delete_sweep_outlined,
            tooltip: 'Clear all calls',
            onTap: db.calls.isEmpty ? null : db.clearCalls,
          ),
        ],
      ),
    );
  }

  // ── Body ──────────────────────────────────────────────────────────────

  Widget _buildBody(AppColors c, DatabaseService db) {
    if (db.calls.isEmpty) {
      return _buildEmpty(c);
    }
    return Scrollbar(
      controller: _scrollCtrl,
      child: ListView.builder(
        controller: _scrollCtrl,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        itemCount: db.calls.length,
        itemBuilder: (_, i) {
          final call = db.calls[i];
          // Latest is expanded by default; older ones default to expanded
          // too unless the user collapsed them.
          final collapsed = _collapsed.contains(call.id);
          return _CallCard(
            call: call,
            collapsed: collapsed,
            onToggle: () => _toggle(call.id),
          );
        },
      ),
    );
  }

  Widget _buildEmpty(AppColors c) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.storage_outlined, size: 36, color: c.textMuted),
          const SizedBox(height: 12),
          Text('No database calls yet',
              style: GoogleFonts.inter(
                  fontSize: 13,
                  color: c.textMuted,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          Text(
            'Ask the agent to query the database — every SQL,\n'
            'schema, transaction or browse call appears here.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
                fontSize: 11, color: c.textDim, height: 1.5),
          ),
        ],
      ),
    );
  }
}

// ─── Single call card ──────────────────────────────────────────────────────

class _CallCard extends StatelessWidget {
  final DatabaseCall call;
  final bool collapsed;
  final VoidCallback onToggle;

  const _CallCard({
    required this.call,
    required this.collapsed,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(context),
          if (!collapsed) ...[
            Container(height: 1, color: c.border),
            _buildBody(context),
          ],
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final c = context.colors;
    final iconData = _iconForName(call.bareName);
    final tint = _tintForName(c, call.bareName);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onToggle,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                collapsed
                    ? Icons.keyboard_arrow_right_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 16,
                color: c.textMuted,
              ),
              const SizedBox(width: 4),
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: tint.withValues(alpha: 0.3)),
                ),
                child: Icon(iconData, size: 13, color: tint),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          call.label.isNotEmpty
                              ? call.label
                              : call.bareName.toUpperCase(),
                          style: GoogleFonts.inter(
                              fontSize: 12,
                              color: c.text,
                              fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(width: 8),
                        _StatusBadge(call: call),
                        const Spacer(),
                        if (call.result?.elapsedMs != null) ...[
                          Icon(Icons.schedule_rounded,
                              size: 10, color: c.textMuted),
                          const SizedBox(width: 3),
                          Text('${call.result!.elapsedMs}ms',
                              style: GoogleFonts.firaCode(
                                  fontSize: 10, color: c.textMuted)),
                          const SizedBox(width: 8),
                        ],
                        if (call.result?.count != null) ...[
                          Text('${call.result!.count} rows',
                              style: GoogleFonts.firaCode(
                                  fontSize: 10, color: c.textMuted)),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          _formatTime(call.timestamp),
                          style: GoogleFonts.firaCode(
                              fontSize: 9, color: c.textDim),
                        ),
                      ],
                    ),
                    if (call.detail.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        call.detail,
                        style: GoogleFonts.firaCode(
                            fontSize: 11,
                            color: c.textMuted,
                            height: 1.4),
                        maxLines: collapsed ? 1 : 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final c = context.colors;

    // Error state takes precedence over result rendering.
    if (call.isFailed) {
      return Container(
        padding: const EdgeInsets.all(12),
        color: c.red.withValues(alpha: 0.05),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded, size: 14, color: c.red),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                call.error.isNotEmpty ? call.error : 'Call failed',
                style: GoogleFonts.firaCode(
                    fontSize: 11, color: c.red, height: 1.45),
              ),
            ),
          ],
        ),
      );
    }

    if (call.isRunning) {
      return Container(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: c.orange,
              ),
            ),
            const SizedBox(width: 10),
            Text('running…',
                style: GoogleFonts.firaCode(
                    fontSize: 11, color: c.textMuted)),
          ],
        ),
      );
    }

    final result = call.result;
    if (result == null) return const SizedBox.shrink();

    // Per-action renderer
    switch (call.bareName) {
      case 'sql':
      case 'browse':
      case 'search_data':
      case 'relations':
        if (result.isTabular) return _ResultGrid(result: result);
        return _RawJsonView(raw: result.raw);

      case 'schema':
        return _SchemaView(raw: result.raw);

      case 'list_connections':
        return _ConnectionsTable(raw: result.raw);

      case 'connect':
      case 'disconnect':
        return _ConnectionStatusBlock(call: call);

      case 'transaction':
        return _TransactionStatusBlock(call: call);

      case 'bulk_insert':
        return _BulkInsertStatus(result: result);

      default:
        if (result.isTabular) return _ResultGrid(result: result);
        return _RawJsonView(raw: result.raw);
    }
  }
}

// ─── Per-action renderers ──────────────────────────────────────────────────

class _ResultGrid extends StatelessWidget {
  final DatabaseResult result;
  const _ResultGrid({required this.result});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cols = result.columns!;
    final rws = result.rows!;
    if (rws.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(14),
        child: Text(
          '— no rows —',
          style:
              GoogleFonts.firaCode(fontSize: 11, color: c.textMuted),
        ),
      );
    }

    final source = _SqlDataSource(columns: cols, sourceRows: rws);
    // Cap height so the grid doesn't push everything offscreen for big
    // result sets.
    final rowHeight = 26.0;
    final maxRows = 12;
    final shownRows = rws.length > maxRows ? maxRows : rws.length;
    final gridHeight = 30.0 + shownRows * rowHeight + 4;

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: gridHeight),
            child: SfDataGridTheme(
              data: SfDataGridThemeData(
                gridLineColor: c.border,
                gridLineStrokeWidth: 0.5,
                headerColor: c.surfaceAlt,
                rowHoverColor: c.surfaceAlt.withValues(alpha: 0.4),
              ),
              child: SfDataGrid(
                source: source,
                rowHeight: rowHeight,
                headerRowHeight: 30,
                gridLinesVisibility: GridLinesVisibility.both,
                headerGridLinesVisibility: GridLinesVisibility.both,
                columnWidthMode: ColumnWidthMode.fill,
                columns: [
                  for (final col in cols)
                    GridColumn(
                      columnName: col,
                      minimumWidth: 80,
                      label: Container(
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          col,
                          style: GoogleFonts.inter(
                              fontSize: 11,
                              color: c.text,
                              fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (rws.length > maxRows) ...[
            const SizedBox(height: 4),
            Text(
              '… ${rws.length - maxRows} more rows',
              textAlign: TextAlign.right,
              style: GoogleFonts.firaCode(
                  fontSize: 10, color: c.textDim),
            ),
          ],
        ],
      ),
    );
  }
}

class _SqlDataSource extends DataGridSource {
  final List<String> columns;
  final List<List<dynamic>> sourceRows;
  late final List<DataGridRow> _rows;

  _SqlDataSource({required this.columns, required this.sourceRows}) {
    _rows = [
      for (final r in sourceRows)
        DataGridRow(cells: [
          for (var i = 0; i < columns.length; i++)
            DataGridCell<String>(
              columnName: columns[i],
              value: i < r.length ? _formatCell(r[i]) : '',
            ),
        ]),
    ];
  }

  static String _formatCell(dynamic v) {
    if (v == null) return 'NULL';
    if (v is Map || v is List) return jsonEncode(v);
    return v.toString();
  }

  @override
  List<DataGridRow> get rows => _rows;

  @override
  DataGridRowAdapter? buildRow(DataGridRow row) {
    return DataGridRowAdapter(
      cells: row.getCells().map<Widget>((cell) {
        return Builder(
          builder: (ctx) {
            final c = ctx.colors;
            final value = cell.value as String;
            final isNull = value == 'NULL';
            return Container(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                value,
                style: GoogleFonts.firaCode(
                  fontSize: 11,
                  color: isNull ? c.textMuted : c.text,
                  fontStyle:
                      isNull ? FontStyle.italic : FontStyle.normal,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                overflow: TextOverflow.ellipsis,
              ),
            );
          },
        );
      }).toList(),
    );
  }
}

class _SchemaView extends StatelessWidget {
  final Map<String, dynamic> raw;
  const _SchemaView({required this.raw});

  @override
  Widget build(BuildContext context) {
    return _RawJsonView(raw: raw);
  }
}

class _ConnectionsTable extends StatelessWidget {
  final Map<String, dynamic> raw;
  const _ConnectionsTable({required this.raw});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final list = raw['connections'];
    if (list is! List || list.isEmpty) {
      return _RawJsonView(raw: raw);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final item in list)
            if (item is Map)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Icon(Icons.dns_rounded, size: 12, color: c.green),
                    const SizedBox(width: 8),
                    Text(
                      (item['name'] ?? item['id'] ?? '?').toString(),
                      style: GoogleFonts.firaCode(
                          fontSize: 11,
                          color: c.text,
                          fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 8),
                    if (item['engine'] != null || item['driver'] != null)
                      _Tag(
                        label: (item['engine'] ?? item['driver'])
                            .toString()
                            .toUpperCase(),
                        color: c.green,
                      ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        [
                          if (item['host'] != null) item['host'],
                          if (item['port'] != null) ':${item['port']}',
                          if (item['database'] != null) '/${item['database']}',
                        ].join(),
                        style: GoogleFonts.firaCode(
                            fontSize: 10, color: c.textMuted),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

class _ConnectionStatusBlock extends StatelessWidget {
  final DatabaseCall call;
  const _ConnectionStatusBlock({required this.call});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isConnect = call.bareName == 'connect';
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(
            isConnect ? Icons.power_rounded : Icons.power_off_rounded,
            size: 14,
            color: isConnect ? c.green : c.textMuted,
          ),
          const SizedBox(width: 8),
          Text(
            isConnect ? 'Connected' : 'Disconnected',
            style: GoogleFonts.firaCode(
                fontSize: 11,
                color: c.text,
                fontWeight: FontWeight.w600),
          ),
          if (call.connectionId != null) ...[
            const SizedBox(width: 6),
            Text('· ${call.connectionId}',
                style: GoogleFonts.firaCode(
                    fontSize: 11, color: c.textMuted)),
          ],
        ],
      ),
    );
  }
}

class _TransactionStatusBlock extends StatelessWidget {
  final DatabaseCall call;
  const _TransactionStatusBlock({required this.call});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final op = call.params['op'] ?? call.params['operation'] ?? 'unknown';
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(Icons.swap_horiz_rounded, size: 14, color: c.cyan),
          const SizedBox(width: 8),
          Text(
            'Transaction · $op',
            style: GoogleFonts.firaCode(
                fontSize: 11,
                color: c.text,
                fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _BulkInsertStatus extends StatelessWidget {
  final DatabaseResult result;
  const _BulkInsertStatus({required this.result});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final inserted = result.count ??
        result.raw['inserted'] ??
        result.raw['affected'] ??
        '?';
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(Icons.upload_rounded, size: 14, color: c.green),
          const SizedBox(width: 8),
          Text(
            '$inserted row(s) inserted',
            style: GoogleFonts.firaCode(
                fontSize: 11,
                color: c.text,
                fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _RawJsonView extends StatelessWidget {
  final dynamic raw;
  const _RawJsonView({required this.raw});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    String pretty;
    try {
      pretty = const JsonEncoder.withIndent('  ').convert(raw);
    } catch (_) {
      pretty = raw.toString();
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      constraints: const BoxConstraints(maxHeight: 320),
      child: SingleChildScrollView(
        child: SelectableText(
          pretty,
          style: GoogleFonts.firaCode(
              fontSize: 11, color: c.text, height: 1.45),
        ),
      ),
    );
  }
}

// ─── Tiny themed widgets ───────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final DatabaseCall call;
  const _StatusBadge({required this.call});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (label, color, icon) = call.isFailed
        ? ('FAILED', c.red, Icons.error_outline_rounded)
        : call.isRunning
            ? ('RUNNING', c.orange, Icons.hourglass_empty_rounded)
            : ('OK', c.green, Icons.check_circle_outline_rounded);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 9, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: GoogleFonts.firaCode(
                fontSize: 9, color: color, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String label;
  final Color color;
  const _Tag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: GoogleFonts.firaCode(
            fontSize: 9, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _ConnectionDot extends StatelessWidget {
  final bool connected;
  final Color color;
  const _ConnectionDot({required this.connected, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: connected
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.5),
                  blurRadius: 4,
                  spreadRadius: 1,
                )
              ]
            : null,
      ),
    );
  }
}

class _DbIconBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;
  const _DbIconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  @override
  State<_DbIconBtn> createState() => _DbIconBtnState();
}

class _DbIconBtnState extends State<_DbIconBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final enabled = widget.onTap != null;
    final color = enabled
        ? (_h || widget.active ? c.text : c.textMuted)
        : c.textDim;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: widget.active
                  ? c.green.withValues(alpha: 0.15)
                  : (_h && enabled ? c.surfaceAlt : Colors.transparent),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                color: widget.active
                    ? c.green.withValues(alpha: 0.3)
                    : Colors.transparent,
              ),
            ),
            child: Icon(widget.icon, size: 13, color: color),
          ),
        ),
      ),
    );
  }
}

// ─── Helpers ───────────────────────────────────────────────────────────────

IconData _iconForName(String bare) => switch (bare) {
      'sql' => Icons.code_rounded,
      'browse' => Icons.table_rows_rounded,
      'schema' => Icons.account_tree_outlined,
      'transaction' => Icons.swap_horiz_rounded,
      'bulk_insert' => Icons.upload_rounded,
      'relations' => Icons.share_outlined,
      'search_data' => Icons.search_rounded,
      'connect' => Icons.power_rounded,
      'disconnect' => Icons.power_off_rounded,
      'list_connections' => Icons.dns_rounded,
      _ => Icons.storage_rounded,
    };

Color _tintForName(AppColors c, String bare) => switch (bare) {
      'sql' || 'browse' || 'search_data' || 'relations' => c.cyan,
      'schema' => c.purple,
      'transaction' => c.blue,
      'bulk_insert' => c.green,
      'connect' || 'list_connections' => c.green,
      'disconnect' => c.textMuted,
      _ => c.textMuted,
    };

String _formatTime(DateTime t) {
  final h = t.hour.toString().padLeft(2, '0');
  final m = t.minute.toString().padLeft(2, '0');
  final s = t.second.toString().padLeft(2, '0');
  return '$h:$m:$s';
}
