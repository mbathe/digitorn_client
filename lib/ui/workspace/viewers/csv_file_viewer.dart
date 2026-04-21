import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:syncfusion_flutter_core/theme.dart';
import 'package:syncfusion_flutter_datagrid/datagrid.dart';
import '../../../theme/app_theme.dart';
import 'csv/csv_parser.dart';
import 'file_viewer.dart';

/// CSV / TSV viewer with separator auto-detection, type inference per
/// column, sortable headers, frozen header row, row-number gutter,
/// formula bar, search and copy-to-clipboard.
///
/// This viewer is the warm-up for the future Excel viewer: it
/// exercises the same [SfDataGrid] surface area we'll need (custom
/// cell builders, frozen panes, sorting) but on a much simpler
/// data model — plain text rows.
class CsvFileViewer extends FileViewer with SearchableViewer {
  const CsvFileViewer();

  @override
  String get id => 'csv';

  @override
  int get priority => 90;

  @override
  Set<String> get extensions => const {'csv', 'tsv'};

  @override
  Widget build(BuildContext context, ViewerContext vctx) {
    return _CsvPane(
      key: ValueKey('csv-${vctx.buffer.path}'),
      content: vctx.buffer.content,
      filename: vctx.buffer.filename,
    );
  }
}

class _CsvPane extends StatefulWidget {
  final String content;
  final String filename;
  const _CsvPane({super.key, required this.content, required this.filename});

  @override
  State<_CsvPane> createState() => _CsvPaneState();
}

class _CsvPaneState extends State<_CsvPane> {
  late ParsedCsv _parsed;
  late _CsvDataSource _source;

  // Selected cell — drives the formula bar.
  int? _selectedRow;
  int? _selectedColIndex; // index in parsed.columns

  // Search state
  bool _searching = false;
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  List<_SearchHit> _hits = [];
  int _hitIndex = 0;

  // Grid controller for selection / scroll-to-cell
  final DataGridController _gridCtrl = DataGridController();

  @override
  void initState() {
    super.initState();
    _reparse();
  }

  @override
  void didUpdateWidget(_CsvPane old) {
    super.didUpdateWidget(old);
    if (old.content != widget.content) {
      _reparse();
      _clearSearch();
    }
  }

  void _reparse() {
    _parsed = parseCsv(widget.content);
    _source = _CsvDataSource(_parsed);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _gridCtrl.dispose();
    super.dispose();
  }

  // ── Search ────────────────────────────────────────────────────────────

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (_searching) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _searchFocus.requestFocus());
      } else {
        _clearSearch();
      }
    });
  }

  void _clearSearch() {
    _searchCtrl.clear();
    _hits = [];
    _hitIndex = 0;
    _source.setHighlightedHits([]);
  }

  void _runSearch(String raw) {
    final q = raw.trim().toLowerCase();
    if (q.isEmpty) {
      setState(() {
        _hits = [];
        _hitIndex = 0;
        _source.setHighlightedHits([]);
      });
      return;
    }
    final hits = <_SearchHit>[];
    for (var r = 0; r < _parsed.rows.length; r++) {
      final row = _parsed.rows[r];
      for (var c = 0; c < row.length; c++) {
        if (row[c].toLowerCase().contains(q)) {
          hits.add(_SearchHit(row: r, col: c));
        }
      }
    }
    setState(() {
      _hits = hits;
      _hitIndex = 0;
      _source.setHighlightedHits(hits);
    });
    if (hits.isNotEmpty) _scrollToHit(0);
  }

  void _searchNext() {
    if (_hits.isEmpty) return;
    setState(() => _hitIndex = (_hitIndex + 1) % _hits.length);
    _scrollToHit(_hitIndex);
  }

  void _searchPrev() {
    if (_hits.isEmpty) return;
    setState(() => _hitIndex = (_hitIndex - 1 + _hits.length) % _hits.length);
    _scrollToHit(_hitIndex);
  }

  void _scrollToHit(int idx) {
    final hit = _hits[idx];
    _gridCtrl.scrollToRow(hit.row.toDouble());
    setState(() {
      _selectedRow = hit.row;
      _selectedColIndex = hit.col;
    });
  }

  // ── Selection ─────────────────────────────────────────────────────────

  void _onCellTap(DataGridCellTapDetails d) {
    // Column 0 is the synthetic row-number gutter — ignore taps on it
    // for selection purposes.
    final colIndex = d.column.columnName == _kRowNumColumn
        ? null
        : int.tryParse(d.column.columnName.replaceFirst('col_', ''));
    final rowIdx = d.rowColumnIndex.rowIndex - 1; // -1 because of header row
    if (rowIdx < 0 || rowIdx >= _parsed.rows.length) return;
    setState(() {
      _selectedRow = rowIdx;
      _selectedColIndex = colIndex;
    });
  }

  // ── Clipboard ─────────────────────────────────────────────────────────

  void _copySelection() {
    final r = _selectedRow;
    final c = _selectedColIndex;
    if (r == null || c == null) return;
    if (r >= _parsed.rows.length || c >= _parsed.rows[r].length) return;
    Clipboard.setData(ClipboardData(text: _parsed.rows[r][c]));
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (_parsed.rows.isEmpty && _parsed.columns.isEmpty) {
      return _buildEmpty(c);
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _toggleSearch,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_searching) _toggleSearch();
        },
        const SingleActivator(LogicalKeyboardKey.keyC, control: true):
            _copySelection,
      },
      child: Focus(
        autofocus: true,
        child: Container(
          color: c.bg,
          child: Column(
            children: [
              _buildHeader(c),
              Container(height: 1, color: c.border),
              _buildFormulaBar(c),
              Container(height: 1, color: c.border),
              Expanded(child: _buildGrid(c)),
              _buildStatusBar(c),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(AppColors c) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      color: c.surface,
      child: _searching ? _buildSearchBar(c) : _buildHeaderRow(c),
    );
  }

  Widget _buildHeaderRow(AppColors c) {
    return Row(
      children: [
        Icon(Icons.table_chart_outlined, size: 14, color: c.green),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            widget.filename,
            style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: c.green.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: c.green.withValues(alpha: 0.3)),
          ),
          child: Text(
            widget.filename.toLowerCase().endsWith('.tsv') ? 'TSV' : 'CSV',
            style: GoogleFonts.firaCode(
                fontSize: 9, color: c.green, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: 12),
        _CsvIconBtn(
          icon: Icons.search_rounded,
          tooltip: 'Search (Ctrl+F)',
          onTap: _toggleSearch,
        ),
        const SizedBox(width: 4),
        _CsvIconBtn(
          icon: Icons.content_copy_rounded,
          tooltip: 'Copy selected cell (Ctrl+C)',
          onTap: _copySelection,
          enabled: _selectedRow != null && _selectedColIndex != null,
        ),
      ],
    );
  }

  Widget _buildSearchBar(AppColors c) {
    return Row(
      children: [
        Icon(Icons.search_rounded, size: 14, color: c.textMuted),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _searchCtrl,
            focusNode: _searchFocus,
            onChanged: _runSearch,
            onSubmitted: (_) => _searchNext(),
            style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: 'Search in cells…',
              hintStyle: GoogleFonts.firaCode(
                  fontSize: 12, color: c.textMuted),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
        Text(
          _hits.isEmpty
              ? (_searchCtrl.text.isEmpty ? '' : 'No matches')
              : '${_hitIndex + 1} / ${_hits.length}',
          style: GoogleFonts.firaCode(
              fontSize: 11,
              color: _hits.isEmpty ? c.textMuted : c.text),
        ),
        const SizedBox(width: 6),
        _CsvIconBtn(
          icon: Icons.keyboard_arrow_up_rounded,
          tooltip: 'Previous match',
          enabled: _hits.isNotEmpty,
          onTap: _searchPrev,
        ),
        _CsvIconBtn(
          icon: Icons.keyboard_arrow_down_rounded,
          tooltip: 'Next match',
          enabled: _hits.isNotEmpty,
          onTap: _searchNext,
        ),
        const SizedBox(width: 6),
        _CsvIconBtn(
          icon: Icons.close_rounded,
          tooltip: 'Close search (Esc)',
          onTap: _toggleSearch,
        ),
      ],
    );
  }

  Widget _buildFormulaBar(AppColors c) {
    final r = _selectedRow;
    final cIdx = _selectedColIndex;
    String address = '';
    String value = '';
    String? typeLabel;

    if (r != null && cIdx != null && cIdx < _parsed.columns.length) {
      address = '${_excelColumnLabel(cIdx)}${r + 1}';
      if (r < _parsed.rows.length && cIdx < _parsed.rows[r].length) {
        value = _parsed.rows[r][cIdx];
      }
      typeLabel = _parsed.columns[cIdx].type.label;
    }

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      color: c.bg,
      child: Row(
        children: [
          // Cell address bubble
          Container(
            width: 72,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: c.border),
            ),
            child: Text(
              address.isEmpty ? '—' : address,
              style: GoogleFonts.firaCode(
                  fontSize: 11,
                  color: address.isEmpty ? c.textMuted : c.text),
            ),
          ),
          if (typeLabel != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                typeLabel,
                style: GoogleFonts.firaCode(
                    fontSize: 9,
                    color: c.textMuted,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ],
          const SizedBox(width: 8),
          Container(width: 1, height: 16, color: c.border),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid(AppColors c) {
    final cols = <GridColumn>[
      // Row-number gutter (frozen via frozenColumnsCount: 1)
      GridColumn(
        columnName: _kRowNumColumn,
        width: 56,
        allowSorting: false,
        label: Container(
          alignment: Alignment.center,
          color: c.surface,
          child: Text(
            '#',
            style: GoogleFonts.firaCode(
                fontSize: 11,
                color: c.textMuted,
                fontWeight: FontWeight.w600),
          ),
        ),
      ),
      for (final col in _parsed.columns)
        GridColumn(
          columnName: 'col_${col.index}',
          allowSorting: true,
          minimumWidth: 80,
          columnWidthMode: ColumnWidthMode.auto,
          label: Container(
            alignment: switch (col.type.alignment) {
              CsvAlign.left => Alignment.centerLeft,
              CsvAlign.center => Alignment.center,
              CsvAlign.right => Alignment.centerRight,
            },
            padding: const EdgeInsets.symmetric(horizontal: 8),
            color: c.surface,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    col.name,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color: c.text,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    col.type.label,
                    style: GoogleFonts.firaCode(
                        fontSize: 8,
                        color: c.textMuted,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
    ];

    return SfDataGridTheme(
      data: SfDataGridThemeData(
        gridLineColor: c.border,
        gridLineStrokeWidth: 0.5,
        headerColor: c.surface,
        headerHoverColor: c.surfaceAlt,
        rowHoverColor: c.surfaceAlt.withValues(alpha: 0.4),
        selectionColor: c.blue.withValues(alpha: 0.18),
        currentCellStyle: DataGridCurrentCellStyle(
          borderColor: c.blue,
          borderWidth: 1.5,
        ),
      ),
      child: SfDataGrid(
        controller: _gridCtrl,
        source: _source,
        columns: cols,
        gridLinesVisibility: GridLinesVisibility.both,
        headerGridLinesVisibility: GridLinesVisibility.both,
        rowHeight: 26,
        headerRowHeight: 30,
        frozenColumnsCount: 1,
        selectionMode: SelectionMode.single,
        navigationMode: GridNavigationMode.cell,
        allowSorting: true,
        allowSwiping: false,
        onCellTap: _onCellTap,
      ),
    );
  }

  Widget _buildStatusBar(AppColors c) {
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Text(
            '${_parsed.rowCount} rows × ${_parsed.columnCount} cols',
            style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted),
          ),
          const SizedBox(width: 12),
          Text(
            'separator: ${_parsed.separatorLabel}',
            style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted),
          ),
          if (_parsed.hadBom) ...[
            const SizedBox(width: 12),
            Text(
              'UTF-8 BOM',
              style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted),
            ),
          ],
          const Spacer(),
          if (_hits.isNotEmpty)
            Text('${_hits.length} matches',
                style:
                    GoogleFonts.firaCode(fontSize: 10, color: c.textMuted)),
        ],
      ),
    );
  }

  Widget _buildEmpty(AppColors c) {
    return Container(
      color: c.bg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.table_chart_outlined,
                size: 36, color: c.textMuted),
            const SizedBox(height: 12),
            Text('Empty CSV',
                style: GoogleFonts.inter(
                    fontSize: 13,
                    color: c.textMuted,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

// ─── Data source for SfDataGrid ──────────────────────────────────────────

const String _kRowNumColumn = '__row_num__';

class _CsvDataSource extends DataGridSource {
  final ParsedCsv parsed;
  List<DataGridRow> _rows = [];
  // (row,col) pairs that should pulse — used for search hits.
  // Encoded as `row * 100000 + col` for O(1) Set lookup per cell.
  Set<int> _highlightedCellIds = const {};

  _CsvDataSource(this.parsed) {
    _build();
  }

  void _build() {
    _rows = [];
    for (var r = 0; r < parsed.rows.length; r++) {
      final cells = <DataGridCell>[
        DataGridCell<int>(columnName: _kRowNumColumn, value: r + 1),
      ];
      for (final col in parsed.columns) {
        final raw = col.index < parsed.rows[r].length
            ? parsed.rows[r][col.index]
            : '';
        cells.add(DataGridCell<String>(
            columnName: 'col_${col.index}', value: raw));
      }
      _rows.add(DataGridRow(cells: cells));
    }
  }

  void setHighlightedHits(List<_SearchHit> hits) {
    _highlightedCellIds = hits.map((h) => h.row * 100000 + h.col).toSet();
    notifyListeners();
  }

  @override
  List<DataGridRow> get rows => _rows;

  @override
  DataGridRowAdapter? buildRow(DataGridRow row) {
    final rowIdx = (row.getCells().first.value as int) - 1;
    return DataGridRowAdapter(
      cells: row.getCells().map<Widget>((cell) {
        if (cell.columnName == _kRowNumColumn) {
          return _RowNumberCell(number: cell.value as int);
        }
        final colIndex =
            int.parse(cell.columnName.replaceFirst('col_', ''));
        final col = parsed.columns[colIndex];
        final isHit =
            _highlightedCellIds.contains(rowIdx * 100000 + colIndex);
        return _CsvDataCell(
          value: cell.value as String,
          column: col,
          isSearchHit: isHit,
        );
      }).toList(),
    );
  }

  @override
  Future<void> handleLoadMoreRows() async {}

  // Sorting: convert to numeric / date when possible to get the right
  // ordering instead of lexicographic.
  @override
  int compare(DataGridRow? a, DataGridRow? b, SortColumnDetails sortColumn) {
    if (a == null || b == null) return 0;
    final colName = sortColumn.name;
    if (colName == _kRowNumColumn) {
      final av = a.getCells().firstWhere((c) => c.columnName == colName).value
          as int;
      final bv = b.getCells().firstWhere((c) => c.columnName == colName).value
          as int;
      return av.compareTo(bv);
    }
    final colIdx = int.parse(colName.replaceFirst('col_', ''));
    final col = parsed.columns[colIdx];
    final av = a.getCells().firstWhere((c) => c.columnName == colName).value
        as String;
    final bv = b.getCells().firstWhere((c) => c.columnName == colName).value
        as String;
    return _smartCompare(av, bv, col.type);
  }

  int _smartCompare(String a, String b, CsvColumnType t) {
    switch (t) {
      case CsvColumnType.integer:
      case CsvColumnType.decimal:
        final na = double.tryParse(a) ?? double.negativeInfinity;
        final nb = double.tryParse(b) ?? double.negativeInfinity;
        return na.compareTo(nb);
      case CsvColumnType.dateTime:
        final da = DateTime.tryParse(a);
        final db = DateTime.tryParse(b);
        if (da != null && db != null) return da.compareTo(db);
        return a.compareTo(b);
      case CsvColumnType.boolean:
      case CsvColumnType.text:
        return a.toLowerCase().compareTo(b.toLowerCase());
    }
  }
}

class _RowNumberCell extends StatelessWidget {
  final int number;
  const _RowNumberCell({required this.number});
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      alignment: Alignment.center,
      color: c.surface,
      child: Text(
        '$number',
        style: GoogleFonts.firaCode(
            fontSize: 10, color: c.textMuted, fontWeight: FontWeight.w500),
      ),
    );
  }
}

class _CsvDataCell extends StatelessWidget {
  final String value;
  final CsvColumn column;
  final bool isSearchHit;
  const _CsvDataCell({
    required this.value,
    required this.column,
    required this.isSearchHit,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final align = switch (column.type.alignment) {
      CsvAlign.left => Alignment.centerLeft,
      CsvAlign.center => Alignment.center,
      CsvAlign.right => Alignment.centerRight,
    };
    final color = switch (column.type) {
      CsvColumnType.integer => c.cyan,
      CsvColumnType.decimal => c.cyan,
      CsvColumnType.dateTime => c.purple,
      CsvColumnType.boolean => c.orange,
      CsvColumnType.text => c.text,
    };
    return Container(
      alignment: align,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: isSearchHit
          ? BoxDecoration(
              color: c.orange.withValues(alpha: 0.18),
              border: Border.all(
                  color: c.orange.withValues(alpha: 0.4), width: 1),
            )
          : null,
      child: Text(
        value,
        style: GoogleFonts.firaCode(
          fontSize: 11,
          color: color,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

// ─── Helpers ───────────────────────────────────────────────────────────────

class _SearchHit {
  final int row;
  final int col;
  const _SearchHit({required this.row, required this.col});
}

/// Convert a 0-based column index to its Excel-style column letter
/// (`0 → A`, `25 → Z`, `26 → AA`, …).
String _excelColumnLabel(int index) {
  var n = index;
  final buf = StringBuffer();
  while (true) {
    buf.write(String.fromCharCode('A'.codeUnitAt(0) + (n % 26)));
    n = (n ~/ 26) - 1;
    if (n < 0) break;
  }
  return buf.toString().split('').reversed.join();
}

class _CsvIconBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;
  const _CsvIconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
  });
  @override
  State<_CsvIconBtn> createState() => _CsvIconBtnState();
}

class _CsvIconBtnState extends State<_CsvIconBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = widget.enabled
        ? (_h ? c.text : c.textMuted)
        : c.textDim;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.enabled ? widget.onTap : null,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: _h && widget.enabled
                  ? c.surfaceAlt
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Icon(widget.icon, size: 14, color: color),
          ),
        ),
      ),
    );
  }
}
