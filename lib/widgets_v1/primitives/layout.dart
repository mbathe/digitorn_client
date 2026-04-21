/// Digitorn Widgets v1 — layout primitives.
///
/// column, row, card, section, tabs, split, grid, spacer, divider.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../theme/app_theme.dart';
import '../bindings.dart';
import '../models.dart';
import '../runtime.dart';

// Builders are imported lazily via runtime.dart; we re-declare the
// top-level `buildNode` here with a forward reference.
Widget _build(WidgetNode n, WidgetRuntime r, Map<String, dynamic>? s) =>
    buildNode(n, r, scopeExtra: s);

Widget buildColumn(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  final children = node.children ?? const [];
  final gap = asDouble(node.props['gap']) ?? 8;
  final align = _crossAlign(node.props['align']);
  final mainAlign = _mainAlign(node.props['main_align']);
  final padding = parsePadding(node.props['padding']);
  final scrollable = node.props['scrollable'] == true;

  Widget col = Column(
    crossAxisAlignment: align,
    mainAxisAlignment: mainAlign,
    mainAxisSize: MainAxisSize.min,
    children: _withGap(
      [for (final c in children) _build(c, runtime, extra)],
      gap,
      vertical: true,
    ),
  );
  if (padding != EdgeInsets.zero) {
    col = Padding(padding: padding, child: col);
  }
  if (scrollable) {
    col = SingleChildScrollView(child: col);
  }
  return col;
}

Widget buildRow(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  final children = node.children ?? const [];
  final gap = asDouble(node.props['gap']) ?? 8;
  final align = _crossAlign(node.props['align']);
  final mainAlign = _mainAlign(node.props['main_align']);
  final wrap = node.props['wrap'] == true;
  final padding = parsePadding(node.props['padding']);

  final built = [for (final c in children) _build(c, runtime, extra)];
  Widget row;
  if (wrap) {
    row = Wrap(
      spacing: gap,
      runSpacing: gap,
      alignment: _wrapAlign(node.props['main_align']),
      crossAxisAlignment: _wrapCrossAlign(node.props['align']),
      children: built,
    );
  } else {
    row = Row(
      crossAxisAlignment: align,
      mainAxisAlignment: mainAlign,
      mainAxisSize: MainAxisSize.max,
      children: _withGap(built, gap, vertical: false),
    );
  }
  if (padding != EdgeInsets.zero) {
    row = Padding(padding: padding, child: row);
  }
  return row;
}

Widget buildCard(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final scope = runtime.state.buildScope(extra: extra);
    final title = evalTemplate(node.props['title'] as String?, scope);
    final subtitle = evalTemplate(node.props['subtitle'] as String?, scope);
    final iconName = node.props['icon'] as String?;
    final pad = parsePadding(node.props['padding'], 14);
    final elevation = asInt(node.props['elevation']) ?? 0;
    final action = node.actionAt('action');
    final children = node.children ?? const [];

    Widget body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title.isNotEmpty || subtitle.isNotEmpty || iconName != null)
          Padding(
            padding: EdgeInsets.only(
                bottom: children.isNotEmpty ? 10 : 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (iconName != null) ...[
                  Icon(
                    _iconByName(iconName),
                    size: 16,
                    color: runtime.accentColor(node, c),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (title.isNotEmpty)
                        Text(
                          title,
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: c.textBright,
                          ),
                        ),
                      if (subtitle.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
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
              ],
            ),
          ),
        for (final child in children) _build(child, runtime, extra),
      ],
    );

    body = Container(
      decoration: BoxDecoration(
        color: elevation > 0 ? c.surface : c.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
        boxShadow: elevation > 1
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                )
              ]
            : null,
      ),
      padding: pad,
      child: body,
    );

    if (action != null) {
      body = InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => runtime.dispatcher.run(
          action,
          context: ctx,
          scopeExtra: extra,
        ),
        child: body,
      );
    }
    return body;
  });
}

Widget buildSection(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return _SectionStateful(node: node, runtime: runtime, extra: extra);
}

class _SectionStateful extends StatefulWidget {
  final WidgetNode node;
  final WidgetRuntime runtime;
  final Map<String, dynamic>? extra;
  const _SectionStateful({
    required this.node,
    required this.runtime,
    this.extra,
  });

  @override
  State<_SectionStateful> createState() => _SectionStatefulState();
}

class _SectionStatefulState extends State<_SectionStateful> {
  late bool _open;

  @override
  void initState() {
    super.initState();
    _open = widget.node.props['default_open'] != false;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final scope = widget.runtime.state.buildScope(extra: widget.extra);
    final title =
        evalTemplate(widget.node.props['title'] as String?, scope);
    final iconName = widget.node.props['icon'] as String?;
    final collapsible = widget.node.props['collapsible'] != false;
    final children = widget.node.children ?? const [];
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
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: collapsible ? () => setState(() => _open = !_open) : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Row(
                children: [
                  if (iconName != null) ...[
                    Icon(_iconByName(iconName),
                        size: 14, color: c.textMuted),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      title,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: c.textBright,
                      ),
                    ),
                  ),
                  if (collapsible)
                    Icon(
                      _open
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 16,
                      color: c.textMuted,
                    ),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final child in children)
                    _build(child, widget.runtime, widget.extra),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

Widget buildTabs(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return _TabsStateful(node: node, runtime: runtime, extra: extra);
}

class _TabsStateful extends StatefulWidget {
  final WidgetNode node;
  final WidgetRuntime runtime;
  final Map<String, dynamic>? extra;
  const _TabsStateful({
    required this.node,
    required this.runtime,
    this.extra,
  });

  @override
  State<_TabsStateful> createState() => _TabsStatefulState();
}

class _TabsStatefulState extends State<_TabsStateful> {
  String _active = '';

  @override
  void initState() {
    super.initState();
    final scope = widget.runtime.state.buildScope(extra: widget.extra);
    final def = widget.node.props['default'];
    _active = def is String ? evalTemplate(def, scope) : '';
    final tabs = widget.node.nodesAt('tabs');
    if (_active.isEmpty && tabs.isNotEmpty) {
      _active = tabs.first.props['id']?.toString() ?? '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tabs = widget.node.nodesAt('tabs');
    final activeNode = tabs.firstWhere(
      (t) => t.props['id']?.toString() == _active,
      orElse: () => tabs.isEmpty
          ? const WidgetNode(type: 'empty_state')
          : tabs.first,
    );
    final accent = widget.runtime.accentColor(widget.node, c);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final t in tabs)
                _tabChip(
                  t,
                  c,
                  accent,
                  selected: _active == t.props['id'],
                  onTap: () =>
                      setState(() => _active = t.props['id']?.toString() ?? ''),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _build(
          WidgetNode(
            type: 'column',
            props: {
              'children': activeNode.props['children'],
              'gap': 10,
            },
          ),
          widget.runtime,
          widget.extra,
        ),
      ],
    );
  }

  Widget _tabChip(
    WidgetNode tab,
    AppColors c,
    Color accent, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    final title = tab.props['title']?.toString() ?? '';
    final iconName = tab.props['icon'] as String?;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? accent.withValues(alpha: 0.12) : c.surfaceAlt,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: selected ? accent.withValues(alpha: 0.4) : c.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (iconName != null) ...[
                Icon(_iconByName(iconName),
                    size: 12, color: selected ? accent : c.textMuted),
                const SizedBox(width: 6),
              ],
              Text(
                title,
                style: GoogleFonts.inter(
                  fontSize: 11.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? c.textBright : c.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget buildSplit(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final ratio =
        (asDouble(node.props['ratio']) ?? 0.5).clamp(0.1, 0.9).toDouble();
    final horizontal = (node.props['direction'] ?? 'horizontal') == 'horizontal';
    final first = node.nodeAt('first') ?? const WidgetNode(type: 'column');
    final second = node.nodeAt('second') ?? const WidgetNode(type: 'column');
    if (horizontal) {
      return LayoutBuilder(builder: (_, cs) {
        final w = cs.maxWidth;
        final firstW = (w * ratio).clamp(100.0, w - 100.0);
        return Row(
          children: [
            SizedBox(width: firstW, child: _build(first, runtime, extra)),
            Container(width: 1, color: c.border),
            Expanded(child: _build(second, runtime, extra)),
          ],
        );
      });
    }
    return LayoutBuilder(builder: (_, cs) {
      final h = cs.maxHeight;
      final firstH = (h * ratio).clamp(80.0, h - 80.0);
      return Column(
        children: [
          SizedBox(height: firstH, child: _build(first, runtime, extra)),
          Container(height: 1, color: c.border),
          Expanded(child: _build(second, runtime, extra)),
        ],
      );
    });
  });
}

Widget buildGrid(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  final columns = asInt(node.props['columns']) ?? 2;
  final gap = asDouble(node.props['gap']) ?? 10;
  final children = node.children ?? const [];
  return LayoutBuilder(builder: (_, cs) {
    final w = cs.maxWidth;
    final childW = (w - gap * (columns - 1)) / columns;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += columns) {
      final row = <Widget>[];
      for (var j = 0; j < columns; j++) {
        final idx = i + j;
        if (idx >= children.length) {
          row.add(SizedBox(width: childW));
        } else {
          row.add(SizedBox(
            width: childW,
            child: _build(children[idx], runtime, extra),
          ));
        }
        if (j < columns - 1) row.add(SizedBox(width: gap));
      }
      rows.add(Row(children: row));
      if (i + columns < children.length) rows.add(SizedBox(height: gap));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  });
}

Widget buildSpacer(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  final size = asDouble(node.props['size']);
  if (size != null) return SizedBox(width: size, height: size);
  final flex = asInt(node.props['flex']) ?? 1;
  return Spacer(flex: flex);
}

Widget buildDivider(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: c.border,
    );
  });
}

// ── helpers ──────────────────────────────────────────────────────

List<Widget> _withGap(List<Widget> items, double gap, {required bool vertical}) {
  if (items.isEmpty || gap <= 0) return items;
  final out = <Widget>[];
  for (var i = 0; i < items.length; i++) {
    out.add(items[i]);
    if (i < items.length - 1) {
      out.add(vertical
          ? SizedBox(height: gap)
          : SizedBox(width: gap));
    }
  }
  return out;
}

CrossAxisAlignment _crossAlign(dynamic v) {
  switch (v) {
    case 'center':
      return CrossAxisAlignment.center;
    case 'end':
      return CrossAxisAlignment.end;
    case 'stretch':
      return CrossAxisAlignment.stretch;
    case 'start':
    default:
      return CrossAxisAlignment.start;
  }
}

MainAxisAlignment _mainAlign(dynamic v) {
  switch (v) {
    case 'center':
      return MainAxisAlignment.center;
    case 'end':
      return MainAxisAlignment.end;
    case 'space_between':
      return MainAxisAlignment.spaceBetween;
    case 'space_around':
      return MainAxisAlignment.spaceAround;
    case 'space_evenly':
      return MainAxisAlignment.spaceEvenly;
    case 'start':
    default:
      return MainAxisAlignment.start;
  }
}

WrapAlignment _wrapAlign(dynamic v) {
  switch (v) {
    case 'center':
      return WrapAlignment.center;
    case 'end':
      return WrapAlignment.end;
    case 'space_between':
      return WrapAlignment.spaceBetween;
    default:
      return WrapAlignment.start;
  }
}

WrapCrossAlignment _wrapCrossAlign(dynamic v) {
  switch (v) {
    case 'center':
      return WrapCrossAlignment.center;
    case 'end':
      return WrapCrossAlignment.end;
    default:
      return WrapCrossAlignment.start;
  }
}

/// Shared icon lookup — builders across primitive files call this
/// to map a material icon name string to an [IconData].
IconData _iconByName(String name) => widgetIconByName(name);

/// Public alias so other primitive files can use the same mapping
/// without duplicating the switch.
IconData widgetIconByName(String name) {
  switch (name) {
    case 'add':
      return Icons.add_rounded;
    case 'delete':
      return Icons.delete_outline_rounded;
    case 'edit':
      return Icons.edit_outlined;
    case 'check':
      return Icons.check_rounded;
    case 'check_circle':
      return Icons.check_circle_outline_rounded;
    case 'close':
      return Icons.close_rounded;
    case 'search':
      return Icons.search_rounded;
    case 'refresh':
      return Icons.refresh_rounded;
    case 'info':
    case 'info_outline':
      return Icons.info_outline_rounded;
    case 'warning':
      return Icons.warning_amber_rounded;
    case 'error':
      return Icons.error_outline_rounded;
    case 'help':
      return Icons.help_outline_rounded;
    case 'dashboard':
      return Icons.dashboard_outlined;
    case 'storage':
      return Icons.storage_outlined;
    case 'monitoring':
      return Icons.analytics_outlined;
    case 'trending_up':
      return Icons.trending_up_rounded;
    case 'trending_down':
      return Icons.trending_down_rounded;
    case 'person':
      return Icons.person_outline_rounded;
    case 'mail':
      return Icons.mail_outline_rounded;
    case 'library_books':
      return Icons.library_books_outlined;
    case 'confirmation_number':
      return Icons.confirmation_number_outlined;
    case 'inbox':
      return Icons.inbox_outlined;
    case 'tune':
      return Icons.tune_rounded;
    case 'link':
      return Icons.link_rounded;
    case 'open_in_new':
      return Icons.open_in_new_rounded;
    case 'chevron_right':
      return Icons.chevron_right_rounded;
    case 'chevron_down':
    case 'keyboard_arrow_down':
      return Icons.keyboard_arrow_down_rounded;
    case 'folder':
      return Icons.folder_outlined;
    case 'article':
      return Icons.article_outlined;
    case 'description':
      return Icons.description_outlined;
    case 'settings':
      return Icons.settings_outlined;
    case 'star':
      return Icons.star_outline_rounded;
    case 'bookmark':
      return Icons.bookmark_outline_rounded;
    case 'filter_list':
      return Icons.filter_list_rounded;
    case 'sort':
      return Icons.sort_rounded;
    case 'upload':
      return Icons.upload_outlined;
    case 'download':
      return Icons.download_outlined;
    case 'file':
    case 'insert_drive_file':
      return Icons.insert_drive_file_outlined;
    default:
      return Icons.widgets_outlined;
  }
}
