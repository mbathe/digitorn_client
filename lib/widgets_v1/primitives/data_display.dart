/// Digitorn Widgets v1 — data display primitives.
///
/// list, table, stat, chart, tree, timeline, kanban, empty_state.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../theme/app_theme.dart';
import '../bindings.dart';
import '../models.dart';
import '../runtime.dart';
import 'layout.dart' show widgetIconByName;

Widget _build(WidgetNode n, WidgetRuntime r, Map<String, dynamic>? s) =>
    buildNode(n, r, scopeExtra: s);

// ─── list ────────────────────────────────────────────────────────

Widget buildList(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return _ListStateful(node: node, runtime: runtime, extra: extra);
}

class _ListStateful extends StatefulWidget {
  final WidgetNode node;
  final WidgetRuntime runtime;
  final Map<String, dynamic>? extra;
  const _ListStateful({
    required this.node,
    required this.runtime,
    this.extra,
  });

  @override
  State<_ListStateful> createState() => _ListStatefulState();
}

class _ListStatefulState extends State<_ListStateful> {
  String _query = '';
  late final TextEditingController _searchCtrl;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Filter items by the search keys declared on the list node.
  /// Case-insensitive substring match, short-circuits on the first
  /// matching key so we don't pay O(k) per item.
  List<dynamic> _applySearch(List items, Map<String, dynamic> search) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return items;
    final keys = (search['keys'] as List? ?? const [])
        .map((e) => e.toString())
        .toList();
    if (keys.isEmpty) {
      // Fallback: flat-string match on the whole item.
      return items
          .where((e) => e.toString().toLowerCase().contains(q))
          .toList();
    }
    return items.where((e) {
      if (e is! Map) return false;
      for (final k in keys) {
        final v = e[k];
        if (v != null && v.toString().toLowerCase().contains(q)) return true;
      }
      return false;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final node = widget.node;
    final runtime = widget.runtime;
    final scope = runtime.state.buildScope(extra: widget.extra);
    final itemsExpr = node.props['items'];
    final itemsRaw = resolve(itemsExpr, scope);
    final maxHeight = asDouble(node.props['max_height']);
    final separator = node.props['separator'] == true;
    final search = node.props['search'];

    var items = (itemsRaw is List) ? itemsRaw : const [];

    // Search bar (auto-generated if `search:` block is declared).
    Widget? searchBar;
    if (search is Map) {
      final placeholder =
          search['placeholder']?.toString() ?? 'Search…';
      searchBar = Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: _searchCtrl,
          style: GoogleFonts.inter(fontSize: 12.5, color: c.text),
          onChanged: (v) => setState(() => _query = v),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: c.surfaceAlt,
            hintText: placeholder,
            hintStyle: GoogleFonts.inter(
                fontSize: 12.5, color: c.textDim),
            prefixIcon: Icon(Icons.search_rounded,
                size: 14, color: c.textMuted),
            prefixIconConstraints:
                const BoxConstraints(minWidth: 34, minHeight: 20),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.close_rounded,
                        size: 13, color: c.textMuted),
                    onPressed: () {
                      _searchCtrl.clear();
                      setState(() => _query = '');
                    },
                  ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: BorderSide(color: c.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: BorderSide(color: c.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: BorderSide(
                color: runtime.accentColor(node, c),
              ),
            ),
          ),
        ),
      );
      items = _applySearch(items, search.cast<String, dynamic>());
    }

    if (items.isEmpty) {
      final empty = node.nodeAt('empty');
      final emptyWidget = empty != null
          ? _build(empty, runtime, widget.extra)
          : Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Center(
                child: Text(
                  _query.isNotEmpty ? 'No results.' : 'No items.',
                  style: GoogleFonts.inter(
                      fontSize: 12, color: c.textMuted),
                ),
              ),
            );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ?searchBar,
          emptyWidget,
        ],
      );
    }

    final itemTemplate = node.nodeAt('item');
    if (itemTemplate == null) return const SizedBox.shrink();

    final built = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      final e = items[i];
      final iterExtra = {
        ...?widget.extra,
        'item': e,
        'row': e,
        'index': i,
        'first': i == 0,
        'last': i == items.length - 1,
      };
      built.add(_build(itemTemplate, runtime, iterExtra));
      if (separator && i < items.length - 1) {
        built.add(Container(height: 1, color: c.border));
      }
    }

    Widget col = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final w in built)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: w,
          ),
      ],
    );
    if (maxHeight != null) {
      col = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(child: col),
      );
    }
    if (searchBar != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [searchBar, col],
      );
    }
    return col;
  }
}

// ─── table ────────────────────────────────────────────────────────

Widget buildTable(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return _TableStateful(node: node, runtime: runtime, extra: extra);
}

class _TableStateful extends StatefulWidget {
  final WidgetNode node;
  final WidgetRuntime runtime;
  final Map<String, dynamic>? extra;
  const _TableStateful({
    required this.node,
    required this.runtime,
    this.extra,
  });

  @override
  State<_TableStateful> createState() => _TableStatefulState();
}

class _TableStatefulState extends State<_TableStateful> {
  /// Current sort column key. Null = row order as-given.
  String? _sortKey;

  /// Ascending when true, descending when false.
  bool _sortAsc = true;

  /// Current page index (0-based). Only meaningful when
  /// `pagination: true` and `rows` exceed `page_size`.
  int _page = 0;

  /// Selected row identifiers. For v1 we key by row index since
  /// rows may not have a stable id — the caller can still read the
  /// row data via the `selected_rows` state binding.
  final Set<int> _selected = {};

  /// Fire the declared `on_reorder:` action with {from, to}. The
  /// daemon is expected to persist the order server-side; we don't
  /// mutate local state here because the rows arrive from a data
  /// binding (mutating the cache would desync on refresh).
  Future<void> _onReorder(int from, int to, WidgetNode node) async {
    final action = node.actionAt('on_reorder');
    if (action == null) return;
    await widget.runtime.dispatcher.run(
      action,
      context: context,
      scopeExtra: {
        ...?widget.extra,
        'from': from,
        'to': to,
      },
    );
  }

  List _applySort(List rows, String? key, bool asc) {
    if (key == null) return rows;
    final copy = [...rows];
    copy.sort((a, b) {
      final av = a is Map ? a[key] : null;
      final bv = b is Map ? b[key] : null;
      int cmp;
      if (av is num && bv is num) {
        cmp = av.compareTo(bv);
      } else {
        cmp = (av?.toString() ?? '').compareTo(bv?.toString() ?? '');
      }
      return asc ? cmp : -cmp;
    });
    return copy;
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final runtime = widget.runtime;
    final extra = widget.extra;
    final c = context.colors;
    final ctx = context;
    final scope = runtime.state.buildScope(extra: extra);
    final rowsExpr = node.props['rows'];
    final resolvedRows = resolve(rowsExpr, scope);
    final columns = (node.props['columns'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    final sortable = node.props['sortable'] == true;
    final selectable = node.props['selectable'];
    final selectMode =
        (selectable == 'single' || selectable == 'multi') ? selectable : null;
    final pagination = node.props['pagination'] == true;
    final pageSize = asInt(node.props['page_size']) ?? 20;
    final reorderable = node.props['reorderable'] == true;

    var rows = resolvedRows is List ? List.from(resolvedRows) : [];
    rows = _applySort(rows, _sortKey, _sortAsc);

    // Pagination slice. Guard the current page against out-of-range
    // indices (can happen when rows shrink after a refresh). We
    // clamp locally without mutating _page during build — the next
    // frame's build will pick the clamped page naturally because
    // we pass the clamped index to sublist.
    final totalRows = rows.length;
    var effectivePage = _page;
    if (pagination && pageSize > 0 && totalRows > pageSize) {
      final maxPage = ((totalRows - 1) / pageSize).floor();
      if (effectivePage > maxPage) effectivePage = 0;
      final start = effectivePage * pageSize;
      final end = (start + pageSize).clamp(0, totalRows);
      rows = rows.sublist(start, end);
      if (effectivePage != _page) {
        // Defer the state repair to after the current build so we
        // don't setState-during-build.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() => _page = effectivePage);
        });
      }
    }

    // Sync selection state to the runtime so {{state.selected_rows}}
    // works in downstream bindings. We push after build to avoid
    // notifying mid-frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = runtime.state.getState('selected_rows');
      final next = _selected.toList()..sort();
      if (current is! List || !_intListEquals(current.cast<dynamic>(), next)) {
        runtime.state.setState({'selected_rows': next});
      }
    });

    if (columns.isEmpty) {
      return Text(
        'table: no columns declared',
        style: GoogleFonts.firaCode(fontSize: 11, color: c.red),
      );
    }

    final accent = runtime.accentColor(node, c);

    // Build the header row.
    final headerCells = <Widget>[];
    if (reorderable) {
      headerCells.add(const SizedBox(width: 36));
    }
    if (selectMode == 'multi') {
      final allSelected = _selected.length == totalRows && totalRows > 0;
      headerCells.add(SizedBox(
        width: 40,
        child: Center(
          child: Checkbox(
            value: allSelected,
            tristate: false,
            activeColor: accent,
            onChanged: (v) {
              setState(() {
                if (v == true) {
                  _selected
                    ..clear()
                    ..addAll(List.generate(totalRows, (i) => i));
                } else {
                  _selected.clear();
                }
              });
            },
          ),
        ),
      ));
    } else if (selectMode == 'single') {
      headerCells.add(const SizedBox(width: 40));
    }
    for (final col in columns) {
      final label = col['label']?.toString() ?? col['key']?.toString() ?? '';
      final key = col['key']?.toString() ?? '';
      final widthRaw = col['width'];
      final flex = asInt(col['flex']) ?? 1;
      final canSort = sortable && key.isNotEmpty && !key.startsWith('_');
      final isActive = _sortKey == key;
      final labelWidget = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              style: GoogleFonts.firaCode(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: isActive ? accent : c.textMuted,
                letterSpacing: 0.6,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (canSort) ...[
            const SizedBox(width: 3),
            Icon(
              isActive
                  ? (_sortAsc
                      ? Icons.arrow_upward_rounded
                      : Icons.arrow_downward_rounded)
                  : Icons.unfold_more_rounded,
              size: 11,
              color: isActive ? accent : c.textDim,
            ),
          ],
        ],
      );
      Widget cell = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: canSort
            ? InkWell(
                onTap: () => setState(() {
                  if (_sortKey == key) {
                    _sortAsc = !_sortAsc;
                  } else {
                    _sortKey = key;
                    _sortAsc = true;
                  }
                }),
                child: labelWidget,
              )
            : labelWidget,
      );
      if (widthRaw != null) {
        cell = SizedBox(width: asDouble(widthRaw), child: cell);
      } else {
        cell = Expanded(flex: flex, child: cell);
      }
      headerCells.add(cell);
    }

    // Build body rows.
    final bodyRows = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      // Row index in the pre-paginated list so selection stays
      // stable across pages.
      final absoluteIndex = pagination && pageSize > 0
          ? (effectivePage * pageSize) + i
          : i;
      final iterExtra = {
        ...?extra,
        'row': row,
        'item': row,
        'index': absoluteIndex,
        'first': absoluteIndex == 0,
        'last': absoluteIndex == totalRows - 1,
      };
      final cells = <Widget>[];

      // Drag handle column (reorderable).
      if (reorderable) {
        cells.add(SizedBox(
          width: 36,
          child: Center(
            child: Icon(
              Icons.drag_indicator_rounded,
              size: 14,
              color: c.textMuted,
            ),
          ),
        ));
      }

      // Selection checkbox column.
      if (selectMode != null) {
        cells.add(SizedBox(
          width: 40,
          child: Center(
            child: selectMode == 'multi'
                ? Checkbox(
                    value: _selected.contains(absoluteIndex),
                    activeColor: accent,
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _selected.add(absoluteIndex);
                        } else {
                          _selected.remove(absoluteIndex);
                        }
                      });
                    },
                  )
                : InkWell(
                    onTap: () => setState(() {
                      _selected
                        ..clear()
                        ..add(absoluteIndex);
                    }),
                    child: Icon(
                      _selected.contains(absoluteIndex)
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 16,
                      color: _selected.contains(absoluteIndex)
                          ? accent
                          : c.textMuted,
                    ),
                  ),
          ),
        ));
      }

      for (final col in columns) {
        final renderNode = col['render'] is Map
            ? WidgetNode.fromJson(
                (col['render'] as Map).cast<String, dynamic>())
            : null;
        final key = col['key']?.toString() ?? '';
        final widthRaw = col['width'];
        final flex = asInt(col['flex']) ?? 1;
        final align = col['align']?.toString() ?? 'start';
        Widget inner;
        if (renderNode != null) {
          inner = _build(renderNode, runtime, iterExtra);
        } else {
          final rowVal = row is Map ? row[key] : null;
          inner = Text(
            rowVal?.toString() ?? '',
            style: GoogleFonts.inter(fontSize: 12, color: c.text),
            overflow: TextOverflow.ellipsis,
            textAlign: align == 'end'
                ? TextAlign.end
                : align == 'center'
                    ? TextAlign.center
                    : TextAlign.start,
          );
        }
        Widget cell = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Align(
            alignment: align == 'end'
                ? Alignment.centerRight
                : align == 'center'
                    ? Alignment.center
                    : Alignment.centerLeft,
            child: inner,
          ),
        );
        if (widthRaw != null) {
          cell = SizedBox(width: asDouble(widthRaw), child: cell);
        } else {
          cell = Expanded(flex: flex, child: cell);
        }
        cells.add(cell);
      }

      final rowAction = node.actionAt('row_action');
      final isSelected = _selected.contains(absoluteIndex);
      Widget rowWidget = Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: cells,
      );
      rowWidget = Container(
        decoration: BoxDecoration(
          color: isSelected
              ? accent.withValues(alpha: 0.06)
              : Colors.transparent,
          border: Border(bottom: BorderSide(color: c.border)),
        ),
        child: rowWidget,
      );
      if (rowAction != null) {
        rowWidget = InkWell(
          onTap: () => runtime.dispatcher.run(
            rowAction,
            context: ctx,
            scopeExtra: iterExtra,
          ),
          child: rowWidget,
        );
      }
      if (reorderable) {
        final rowIndex = absoluteIndex;
        rowWidget = DragTarget<int>(
          onWillAcceptWithDetails: (d) => d.data != rowIndex,
          onAcceptWithDetails: (d) => _onReorder(d.data, rowIndex, node),
          builder: (_, candidates, _) {
            final highlight = candidates.isNotEmpty;
            return Container(
              decoration: BoxDecoration(
                border: highlight
                    ? Border(
                        top: BorderSide(color: accent, width: 2),
                      )
                    : null,
              ),
              child: Draggable<int>(
                data: rowIndex,
                axis: Axis.vertical,
                feedback: Material(
                  color: Colors.transparent,
                  child: Opacity(
                    opacity: 0.85,
                    child: SizedBox(
                      width: MediaQuery.of(ctx).size.width * 0.6,
                      child: rowWidget,
                    ),
                  ),
                ),
                childWhenDragging:
                    Opacity(opacity: 0.3, child: rowWidget),
                child: rowWidget,
              ),
            );
          },
        );
      }
      bodyRows.add(rowWidget);
    }

    if (bodyRows.isEmpty) {
      final empty = node.nodeAt('empty');
      if (empty != null) return _build(empty, runtime, extra);
    }

    // Pagination footer.
    Widget? paginationFooter;
    if (pagination && pageSize > 0 && totalRows > pageSize) {
      final pages = ((totalRows - 1) / pageSize).floor() + 1;
      paginationFooter = Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: c.border)),
          color: c.surfaceAlt,
          borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(8),
          ),
        ),
        child: Row(
          children: [
            Text(
              '${effectivePage * pageSize + 1}–${(effectivePage * pageSize + rows.length)} '
              'of $totalRows',
              style: GoogleFonts.firaCode(
                fontSize: 10.5,
                color: c.textMuted,
              ),
            ),
            const Spacer(),
            IconButton(
              icon: Icon(Icons.chevron_left_rounded,
                  size: 14, color: c.textMuted),
              onPressed: effectivePage > 0
                  ? () => setState(() => _page = effectivePage - 1)
                  : null,
              tooltip: 'Previous',
              visualDensity: VisualDensity.compact,
            ),
            Text(
              '${effectivePage + 1}/$pages',
              style: GoogleFonts.firaCode(
                fontSize: 10.5,
                color: c.textMuted,
              ),
            ),
            IconButton(
              icon: Icon(Icons.chevron_right_rounded,
                  size: 14, color: c.textMuted),
              onPressed: effectivePage < pages - 1
                  ? () => setState(() => _page = effectivePage + 1)
                  : null,
              tooltip: 'Next',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            decoration: BoxDecoration(
              color: c.surfaceAlt,
              border: Border(bottom: BorderSide(color: c.border)),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Row(children: headerCells),
          ),
          ...bodyRows,
          ?paginationFooter,
        ],
      ),
    );
  }
}

bool _intListEquals(List a, List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ─── stat ─────────────────────────────────────────────────────────

Widget buildStat(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final scope = runtime.state.buildScope(extra: extra);
    final label = evalTemplate(node.props['label'] as String? ?? '', scope);
    final value = evalTemplate(node.props['value'] as String? ?? '', scope);
    final delta = evalTemplate(node.props['delta'] as String? ?? '', scope);
    final trend = node.props['trend'] as String?;
    final iconName = node.props['icon'] as String?;
    final color = runtime.semanticColor(node.props['color'] as String?, c);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: c.textMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (iconName != null)
                Icon(widgetIconByName(iconName), size: 14, color: color),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: c.textBright,
              letterSpacing: -0.3,
            ),
          ),
          if (delta.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  trend == 'up'
                      ? Icons.arrow_upward_rounded
                      : trend == 'down'
                          ? Icons.arrow_downward_rounded
                          : Icons.remove_rounded,
                  size: 11,
                  color: color,
                ),
                const SizedBox(width: 3),
                Text(
                  delta,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  });
}

// ─── empty_state ──────────────────────────────────────────────────

Widget buildEmptyState(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final scope = runtime.state.buildScope(extra: extra);
    final title = evalTemplate(node.props['title'] as String? ?? '', scope);
    final subtitle =
        evalTemplate(node.props['subtitle'] as String? ?? '', scope);
    final iconName = node.props['icon'] as String? ?? 'inbox';
    final action = node.actionAt('action');
    final actionLabel = node.props['action'] is Map
        ? (node.props['action'] as Map)['label']?.toString()
        : null;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(widgetIconByName(iconName), size: 32, color: c.textMuted),
            if (title.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                title,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: c.textBright,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 4),
              SizedBox(
                width: 260,
                child: Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    color: c.textMuted,
                    height: 1.5,
                  ),
                ),
              ),
            ],
            if (action != null && actionLabel != null) ...[
              const SizedBox(height: 14),
              ElevatedButton(
                onPressed: () => runtime.dispatcher.run(
                  action,
                  context: ctx,
                  scopeExtra: extra,
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: runtime.accentColor(node, c),
                  foregroundColor: Colors.white,
                  elevation: 0,
                ),
                child: Text(actionLabel),
              ),
            ],
          ],
        ),
      ),
    );
  });
}

// ─── chart (line/bar/area) ────────────────────────────────────────

Widget buildChart(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final scope = runtime.state.buildScope(extra: extra);
    final kind = (node.props['kind'] as String? ?? 'line').toLowerCase();
    final data = resolve(node.props['data'], scope);
    final height = asDouble(node.props['height']) ?? 220;
    // x-axis key reserved for future label rendering
    final seriesRaw = node.props['series'];
    final series = <_Series>[];
    if (seriesRaw is List) {
      for (final s in seriesRaw) {
        if (s is Map) {
          series.add(_Series(
            yKey: s['y']?.toString() ?? 'y',
            label: s['label']?.toString() ?? '',
            color: _colorOf(s['color']?.toString(), c),
          ));
        }
      }
    }
    if (data is! List || data.isEmpty || series.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            'No chart data',
            style: GoogleFonts.inter(fontSize: 11, color: c.textMuted),
          ),
        ),
      );
    }

    final lineBars = <LineChartBarData>[];
    final barGroups = <BarChartGroupData>[];
    for (var si = 0; si < series.length; si++) {
      final s = series[si];
      final spots = <FlSpot>[];
      for (var i = 0; i < data.length; i++) {
        final row = data[i];
        final y = row is Map ? (row[s.yKey] as num?) : null;
        if (y == null) continue;
        spots.add(FlSpot(i.toDouble(), y.toDouble()));
      }
      if (kind == 'line' || kind == 'area') {
        lineBars.add(LineChartBarData(
          spots: spots,
          isCurved: true,
          color: s.color,
          barWidth: 2,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(
            show: kind == 'area',
            color: s.color.withValues(alpha: 0.12),
          ),
        ));
      } else if (kind == 'bar') {
        for (var i = 0; i < spots.length; i++) {
          if (si == 0) barGroups.add(BarChartGroupData(x: i, barRods: []));
          barGroups[i] = BarChartGroupData(
            x: i,
            barRods: [
              ...barGroups[i].barRods,
              BarChartRodData(
                toY: spots[i].y,
                color: s.color,
                width: 10,
                borderRadius: BorderRadius.circular(2),
              ),
            ],
          );
        }
      }
    }

    return SizedBox(
      height: height,
      child: kind == 'bar'
          ? BarChart(
              BarChartData(
                barGroups: barGroups,
                gridData: const FlGridData(show: false),
                borderData: FlBorderData(show: false),
                titlesData: const FlTitlesData(show: false),
              ),
            )
          : LineChart(
              LineChartData(
                lineBarsData: lineBars,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: 1,
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: c.border,
                    strokeWidth: 1,
                  ),
                ),
                borderData: FlBorderData(show: false),
                titlesData: const FlTitlesData(show: false),
              ),
            ),
    );
  });
}

class _Series {
  final String yKey;
  final String label;
  final Color color;
  _Series({required this.yKey, required this.label, required this.color});
}

Color _colorOf(String? name, AppColors c) {
  switch (name) {
    case 'red':
      return c.red;
    case 'green':
      return c.green;
    case 'orange':
      return c.orange;
    case 'purple':
      return c.purple;
    case 'cyan':
      return c.cyan;
    case 'blue':
    default:
      return c.blue;
  }
}

// ─── tree (simple expandable) ─────────────────────────────────────

Widget buildTree(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final scope = runtime.state.buildScope(extra: extra);
    final roots = resolve(node.props['roots'], scope);
    if (roots is! List || roots.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          'No nodes',
          style: GoogleFonts.inter(fontSize: 11, color: c.textMuted),
        ),
      );
    }
    final childrenKey = node.props['children_key']?.toString() ?? 'children';
    final labelExpr = node.props['label']?.toString() ?? '{{node.name}}';
    final iconExpr = node.props['icon']?.toString();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final r in roots)
          _TreeNode(
            runtime: runtime,
            node: node,
            data: r,
            depth: 0,
            childrenKey: childrenKey,
            labelExpr: labelExpr,
            iconExpr: iconExpr,
            extra: extra,
          ),
      ],
    );
  });
}

class _TreeNode extends StatefulWidget {
  final WidgetRuntime runtime;
  final WidgetNode node;
  final dynamic data;
  final int depth;
  final String childrenKey;
  final String labelExpr;
  final String? iconExpr;
  final Map<String, dynamic>? extra;
  const _TreeNode({
    required this.runtime,
    required this.node,
    required this.data,
    required this.depth,
    required this.childrenKey,
    required this.labelExpr,
    required this.iconExpr,
    required this.extra,
  });

  @override
  State<_TreeNode> createState() => _TreeNodeState();
}

class _TreeNodeState extends State<_TreeNode> {
  late bool _open;

  @override
  void initState() {
    super.initState();
    final defaultDepth =
        asInt(widget.node.props['default_expanded']) ?? 0;
    _open = widget.depth < defaultDepth;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final iterExtra = {...?widget.extra, 'node': widget.data, 'item': widget.data};
    final scope = widget.runtime.state.buildScope(extra: iterExtra);
    final label = evalTemplate(widget.labelExpr, scope);
    final iconName = widget.iconExpr != null
        ? evalTemplate(widget.iconExpr!, scope)
        : 'folder';
    final onSelect = widget.node.actionAt('on_select');
    final children = widget.data is Map
        ? (widget.data as Map)[widget.childrenKey]
        : null;
    final hasChildren = children is List && children.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(5),
          onTap: () {
            if (hasChildren) setState(() => _open = !_open);
            if (onSelect != null) {
              widget.runtime.dispatcher
                  .run(onSelect, context: context, scopeExtra: iterExtra);
            }
          },
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                10 + widget.depth * 14.0, 6, 10, 6),
            child: Row(
              children: [
                Icon(
                  hasChildren
                      ? (_open
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.chevron_right_rounded)
                      : Icons.remove,
                  size: 13,
                  color: c.textMuted,
                ),
                const SizedBox(width: 4),
                Icon(widgetIconByName(iconName),
                    size: 13, color: c.textMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: c.text,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (hasChildren && _open)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final child in children)
                _TreeNode(
                  runtime: widget.runtime,
                  node: widget.node,
                  data: child,
                  depth: widget.depth + 1,
                  childrenKey: widget.childrenKey,
                  labelExpr: widget.labelExpr,
                  iconExpr: widget.iconExpr,
                  extra: iterExtra,
                ),
            ],
          ),
      ],
    );
  }
}

// ─── timeline ─────────────────────────────────────────────────────

Widget buildTimeline(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final scope = runtime.state.buildScope(extra: extra);
    final items = resolve(node.props['items'], scope);
    if (items is! List || items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          'No events',
          style: GoogleFonts.inter(fontSize: 11, color: c.textMuted),
        ),
      );
    }
    final item = node.props['item'] is Map
        ? (node.props['item'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++)
          _TimelineItem(
            runtime: runtime,
            data: items[i],
            index: i,
            total: items.length,
            item: item,
            extra: extra,
          ),
      ],
    );
  });
}

class _TimelineItem extends StatelessWidget {
  final WidgetRuntime runtime;
  final dynamic data;
  final int index;
  final int total;
  final Map<String, dynamic> item;
  final Map<String, dynamic>? extra;
  const _TimelineItem({
    required this.runtime,
    required this.data,
    required this.index,
    required this.total,
    required this.item,
    required this.extra,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final iterExtra = {...?extra, 'item': data, 'row': data, 'index': index};
    final scope = runtime.state.buildScope(extra: iterExtra);
    final title = evalTemplate(item['title']?.toString() ?? '', scope);
    final subtitle = evalTemplate(item['subtitle']?.toString() ?? '', scope);
    final iconName = item['icon']?.toString();
    final colorName = item['color']?.toString();
    final color = runtime.semanticColor(colorName, c);
    final isLast = index == total - 1;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 30,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const SizedBox(height: 4),
                Container(
                  width: 14,
                  height: 14,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(color: color.withValues(alpha: 0.5)),
                  ),
                  child: iconName != null
                      ? Icon(widgetIconByName(iconName),
                          size: 8, color: color)
                      : null,
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 1,
                      color: c.border,
                      margin: const EdgeInsets.symmetric(vertical: 2),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.inter(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: c.textBright,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: c.textMuted,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── kanban (draggable columns) ───────────────────────────────────
//
// v2: each card is a Draggable + each column is a DragTarget. When
// the user drops a card into a different column, we fire the
// `on_move:` action with scopeExtra = {item, from, to} so the host
// can persist the change via a tool call.
//
// Drop targets are visually highlighted with an accent overlay
// while a card is hovering. Drag feedback is a floating clone of
// the original card at cursor.

Widget buildKanban(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return _KanbanStateful(node: node, runtime: runtime, extra: extra);
}

class _KanbanStateful extends StatefulWidget {
  final WidgetNode node;
  final WidgetRuntime runtime;
  final Map<String, dynamic>? extra;
  const _KanbanStateful({
    required this.node,
    required this.runtime,
    this.extra,
  });

  @override
  State<_KanbanStateful> createState() => _KanbanStatefulState();
}

class _KanbanStatefulState extends State<_KanbanStateful> {
  String? _hoverColId;

  Future<void> _onDrop({
    required dynamic item,
    required String fromColId,
    required String toColId,
  }) async {
    if (fromColId == toColId) return;
    final onMove = widget.node.actionAt('on_move');
    if (onMove == null) return;
    final r = await widget.runtime.dispatcher.run(
      onMove,
      context: context,
      scopeExtra: {
        ...?widget.extra,
        'item': item,
        'from': fromColId,
        'to': toColId,
      },
    );
    if (!r.ok && mounted) {
      // Surface the failure — the UI only moves the card visually
      // via the data binding refresh, so a failed action means the
      // daemon didn't persist. Toast lets the user retry.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Move failed: ${r.error ?? 'unknown'}'),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final runtime = widget.runtime;
    final node = widget.node;
    final scope = runtime.state.buildScope(extra: widget.extra);
    final columns = (node.props['columns'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    final card = node.props['card'] is Map
        ? (node.props['card'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    if (columns.isEmpty) return const SizedBox.shrink();
    final accent = runtime.accentColor(node, c);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final col in columns) ...[
            _buildColumn(c, runtime, accent, col, card, scope),
            const SizedBox(width: 10),
          ],
        ],
      ),
    );
  }

  Widget _buildColumn(
    AppColors c,
    WidgetRuntime runtime,
    Color accent,
    Map<String, dynamic> col,
    Map<String, dynamic> card,
    BindingScope scope,
  ) {
    final colId = col['id']?.toString() ?? '';
    final items = (resolve(col['items'], scope) as List?) ?? const [];
    final isHover = _hoverColId == colId;
    return DragTarget<_KanbanDrag>(
      onWillAcceptWithDetails: (details) {
        if (details.data.fromColId == colId) return false;
        setState(() => _hoverColId = colId);
        return true;
      },
      onLeave: (_) {
        if (_hoverColId == colId) setState(() => _hoverColId = null);
      },
      onAcceptWithDetails: (details) {
        setState(() => _hoverColId = null);
        _onDrop(
          item: details.data.item,
          fromColId: details.data.fromColId,
          toColId: colId,
        );
      },
      builder: (_, _, _) => SizedBox(
        width: 260,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: isHover
                ? accent.withValues(alpha: 0.06)
                : c.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isHover
                  ? accent.withValues(alpha: 0.5)
                  : c.border,
              width: isHover ? 1.5 : 1,
            ),
          ),
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        col['title']?.toString() ?? '',
                        style: GoogleFonts.firaCode(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: isHover ? accent : c.textMuted,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                    Text(
                      '${items.length}',
                      style: GoogleFonts.firaCode(
                        fontSize: 9.5,
                        color: c.textDim,
                      ),
                    ),
                  ],
                ),
              ),
              for (final item in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _draggableCard(
                    runtime: runtime,
                    card: card,
                    item: item,
                    colId: colId,
                    c: c,
                  ),
                ),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: Text(
                      isHover ? 'Drop here' : '—',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: isHover ? accent : c.textDim,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _draggableCard({
    required WidgetRuntime runtime,
    required Map<String, dynamic> card,
    required dynamic item,
    required String colId,
    required AppColors c,
  }) {
    final body = _kanbanCardBody(runtime, card, item, c);
    return Draggable<_KanbanDrag>(
      data: _KanbanDrag(item: item, fromColId: colId),
      dragAnchorStrategy: childDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        child: Opacity(
          opacity: 0.9,
          child: SizedBox(width: 240, child: body),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: body),
      child: body,
    );
  }

  Widget _kanbanCardBody(
    WidgetRuntime runtime,
    Map<String, dynamic> card,
    dynamic item,
    AppColors c,
  ) {
    final extra = {...?widget.extra, 'item': item, 'row': item};
    final scope = runtime.state.buildScope(extra: extra);
    final title = evalTemplate(card['title']?.toString() ?? '', scope);
    final subtitle = evalTemplate(card['subtitle']?.toString() ?? '', scope);
    final colorName = card['color']?.toString();
    final accentBar = colorName != null
        ? runtime.semanticColor(colorName, c)
        : null;
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (accentBar != null)
            Container(
              height: 3,
              decoration: BoxDecoration(
                color: accentBar,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(7),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: c.textBright,
                  ),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color: c.textMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _KanbanDrag {
  final dynamic item;
  final String fromColId;
  const _KanbanDrag({required this.item, required this.fromColId});
}
