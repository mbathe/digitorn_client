import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../../theme/app_theme.dart';

/// Generic, format-agnostic viewer for any tree-shaped data
/// (Map / List / primitives) decoded from a textual format like
/// JSON, YAML, TOML, or XML-as-tree.
///
/// The format-specific work — parsing the raw text into a Dart object
/// graph and choosing the right badge / icon / language for the raw
/// view — is done by the caller. This widget owns everything else:
/// the collapsible tree, type-aware colouring, search, path bar,
/// expand/collapse-all, copy operations, and the raw-text fallback.
class StructuredDataViewer extends StatefulWidget {
  /// Filename shown in the header.
  final String filename;

  /// The full text of the file (used for the raw view).
  final String rawContent;

  /// Decoded tree, or `null` if [parseError] is set. Must be made of
  /// `Map`, `List`, `String`, `num`, `bool`, or `null`.
  final dynamic decodedValue;

  /// Set when the underlying parser failed; the viewer surfaces this
  /// instead of an empty tree.
  final String? parseError;

  /// Format label shown as a small badge (e.g. `JSON`, `YAML`).
  final String badgeLabel;

  /// Resolves the badge tint from the active theme so the same widget
  /// works in both light and dark modes.
  final Color Function(AppColors colors) badgeColorOf;

  /// Highlight.js language id used by the raw mode (e.g. `'json'`,
  /// `'yaml'`).
  final String rawLanguage;

  /// Header icon — defaults to a tree-shaped icon for any structured
  /// format.
  final IconData icon;

  const StructuredDataViewer({
    super.key,
    required this.filename,
    required this.rawContent,
    required this.decodedValue,
    required this.parseError,
    required this.badgeLabel,
    required this.badgeColorOf,
    required this.rawLanguage,
    this.icon = Icons.account_tree_outlined,
  });

  @override
  State<StructuredDataViewer> createState() => _StructuredDataViewerState();
}

// ─── Internal model ────────────────────────────────────────────────────────

enum _NodeType { object, array, string, number, boolean, nullValue }

extension _NodeTypeX on _NodeType {
  String get badge => switch (this) {
        _NodeType.object => 'OBJ',
        _NodeType.array => 'ARR',
        _NodeType.string => 'STR',
        _NodeType.number => 'NUM',
        _NodeType.boolean => 'BOOL',
        _NodeType.nullValue => 'NULL',
      };
}

class _TreeNode {
  final _NodeType type;
  final String? key;
  final int? arrayIndex;
  final dynamic value;
  final List<_TreeNode> children;
  final int depth;
  final String pathKey;
  final List<dynamic> path;

  _TreeNode({
    required this.type,
    required this.key,
    required this.arrayIndex,
    required this.value,
    required this.children,
    required this.depth,
    required this.pathKey,
    required this.path,
  });

  bool get isContainer => type == _NodeType.object || type == _NodeType.array;
  int get childCount => children.length;
}

_TreeNode _buildTree({
  required dynamic value,
  String? key,
  int? arrayIndex,
  required int depth,
  required List<dynamic> path,
}) {
  final pathKey = _serialiseKey(path);

  if (value is Map) {
    final children = <_TreeNode>[];
    final entries = value.entries.toList();
    for (final e in entries) {
      final ck = e.key.toString();
      children.add(_buildTree(
        value: e.value,
        key: ck,
        arrayIndex: null,
        depth: depth + 1,
        path: [...path, ck],
      ));
    }
    return _TreeNode(
      type: _NodeType.object,
      key: key,
      arrayIndex: arrayIndex,
      value: null,
      children: children,
      depth: depth,
      pathKey: pathKey,
      path: path,
    );
  }
  if (value is List) {
    final children = <_TreeNode>[];
    for (var i = 0; i < value.length; i++) {
      children.add(_buildTree(
        value: value[i],
        key: null,
        arrayIndex: i,
        depth: depth + 1,
        path: [...path, i],
      ));
    }
    return _TreeNode(
      type: _NodeType.array,
      key: key,
      arrayIndex: arrayIndex,
      value: null,
      children: children,
      depth: depth,
      pathKey: pathKey,
      path: path,
    );
  }
  // Leaf
  final type = value == null
      ? _NodeType.nullValue
      : value is bool
          ? _NodeType.boolean
          : value is num
              ? _NodeType.number
              : _NodeType.string;
  return _TreeNode(
    type: type,
    key: key,
    arrayIndex: arrayIndex,
    value: value,
    children: const [],
    depth: depth,
    pathKey: pathKey,
    path: path,
  );
}

String _serialiseKey(List<dynamic> path) {
  if (path.isEmpty) return r'$';
  final buf = StringBuffer(r'$');
  for (final seg in path) {
    if (seg is int) {
      buf.write('[$seg]');
    } else {
      buf.write('.');
      buf.write(seg);
    }
  }
  return buf.toString();
}

String _displayPath(List<dynamic> path) {
  if (path.isEmpty) return '(root)';
  final buf = StringBuffer();
  var first = true;
  for (final seg in path) {
    if (seg is int) {
      buf.write('[$seg]');
    } else {
      if (!first) buf.write('.');
      buf.write(seg);
    }
    first = false;
  }
  return buf.toString();
}

// ─── State ─────────────────────────────────────────────────────────────────

enum _ViewMode { tree, raw }

class _StructuredDataViewerState extends State<StructuredDataViewer> {
  _TreeNode? _root;

  // Expanded set keyed by pathKey. Auto-expanded to depth 2 on load.
  final Set<String> _expanded = {};

  _ViewMode _mode = _ViewMode.tree;
  _TreeNode? _selected;

  // Search
  bool _searching = false;
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _searchQuery = '';
  final Set<String> _matchedPathKeys = {};
  final List<_TreeNode> _matchedNodes = [];
  int _matchIndex = 0;

  final ScrollController _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  @override
  void didUpdateWidget(StructuredDataViewer old) {
    super.didUpdateWidget(old);
    if (old.decodedValue != widget.decodedValue ||
        old.parseError != widget.parseError ||
        old.rawContent != widget.rawContent) {
      _rebuild();
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _rebuild() {
    _expanded.clear();
    _matchedPathKeys.clear();
    _matchedNodes.clear();
    _matchIndex = 0;
    _selected = null;

    if (widget.parseError != null || widget.decodedValue == null) {
      _root = null;
      return;
    }
    _root = _buildTree(
      value: widget.decodedValue,
      key: null,
      arrayIndex: null,
      depth: 0,
      path: const [],
    );
    _autoExpand(_root!, maxDepth: 2);
  }

  void _autoExpand(_TreeNode node, {required int maxDepth}) {
    if (!node.isContainer) return;
    if (node.depth >= maxDepth) return;
    _expanded.add(node.pathKey);
    for (final c in node.children) {
      _autoExpand(c, maxDepth: maxDepth);
    }
  }

  void _expandAll() {
    if (_root == null) return;
    void walk(_TreeNode n) {
      if (n.isContainer) _expanded.add(n.pathKey);
      for (final c in n.children) {
        walk(c);
      }
    }

    walk(_root!);
    setState(() {});
  }

  void _collapseAll() {
    if (_root == null) return;
    setState(() {
      _expanded.clear();
      _expanded.add(_root!.pathKey);
    });
  }

  void _toggleNode(_TreeNode node) {
    setState(() {
      if (_expanded.contains(node.pathKey)) {
        _expanded.remove(node.pathKey);
      } else {
        _expanded.add(node.pathKey);
      }
    });
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
    _searchQuery = '';
    _matchedPathKeys.clear();
    _matchedNodes.clear();
    _matchIndex = 0;
  }

  void _runSearch(String raw) {
    final q = raw.trim().toLowerCase();
    setState(() {
      _searchQuery = q;
      _matchedPathKeys.clear();
      _matchedNodes.clear();
      _matchIndex = 0;
      if (q.isEmpty || _root == null) return;
      _collectMatches(_root!, q);
      for (final m in _matchedNodes) {
        for (var i = 0; i < m.path.length; i++) {
          final ancestorPath = m.path.sublist(0, i);
          _expanded.add(_serialiseKey(ancestorPath));
        }
      }
    });
    if (_matchedNodes.isNotEmpty) _jumpToMatch(0);
  }

  void _collectMatches(_TreeNode node, String q) {
    final keyMatch =
        node.key != null && node.key!.toLowerCase().contains(q);
    final valueMatch = !node.isContainer &&
        node.value != null &&
        node.value.toString().toLowerCase().contains(q);
    if (keyMatch || valueMatch) {
      _matchedNodes.add(node);
      _matchedPathKeys.add(node.pathKey);
    }
    for (final c in node.children) {
      _collectMatches(c, q);
    }
  }

  void _searchNext() {
    if (_matchedNodes.isEmpty) return;
    setState(() => _matchIndex = (_matchIndex + 1) % _matchedNodes.length);
    _jumpToMatch(_matchIndex);
  }

  void _searchPrev() {
    if (_matchedNodes.isEmpty) return;
    setState(() => _matchIndex =
        (_matchIndex - 1 + _matchedNodes.length) % _matchedNodes.length);
    _jumpToMatch(_matchIndex);
  }

  void _jumpToMatch(int i) {
    final node = _matchedNodes[i];
    setState(() => _selected = node);
    final visible = _flattenVisible();
    final idx = visible.indexWhere((n) => n.pathKey == node.pathKey);
    if (idx < 0) return;
    if (!_scrollCtrl.hasClients) return;
    const rowHeight = 22.0;
    final target = idx * rowHeight;
    final viewport = _scrollCtrl.position.viewportDimension;
    final centred = (target - viewport / 2 + rowHeight / 2)
        .clamp(0.0, _scrollCtrl.position.maxScrollExtent);
    _scrollCtrl.animateTo(
      centred,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  // ── Clipboard ─────────────────────────────────────────────────────────

  void _copyPath() {
    final n = _selected;
    if (n == null) return;
    Clipboard.setData(ClipboardData(text: _displayPath(n.path)));
  }

  void _copyValue() {
    final n = _selected;
    if (n == null) return;
    String text;
    if (n.isContainer) {
      text = const JsonEncoder.withIndent('  ')
          .convert(_subtreeToJson(n));
    } else {
      text = n.value?.toString() ?? 'null';
    }
    Clipboard.setData(ClipboardData(text: text));
  }

  dynamic _subtreeToJson(_TreeNode n) {
    switch (n.type) {
      case _NodeType.object:
        final m = <String, dynamic>{};
        for (final c in n.children) {
          m[c.key ?? ''] = _subtreeToJson(c);
        }
        return m;
      case _NodeType.array:
        return [for (final c in n.children) _subtreeToJson(c)];
      case _NodeType.string:
      case _NodeType.number:
      case _NodeType.boolean:
        return n.value;
      case _NodeType.nullValue:
        return null;
    }
  }

  // ── Visible flattening ────────────────────────────────────────────────

  List<_TreeNode> _flattenVisible() {
    final out = <_TreeNode>[];
    if (_root == null) return out;
    void walk(_TreeNode n) {
      out.add(n);
      if (n.isContainer && _expanded.contains(n.pathKey)) {
        for (final c in n.children) {
          walk(c);
        }
      }
    }

    walk(_root!);
    return out;
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _toggleSearch,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_searching) _toggleSearch();
        },
      },
      child: Focus(
        autofocus: true,
        child: Container(
          color: c.bg,
          child: Column(
            children: [
              _buildHeader(c),
              Container(height: 1, color: c.border),
              _buildPathBar(c),
              Container(height: 1, color: c.border),
              Expanded(
                child: _mode == _ViewMode.tree
                    ? _buildTreeView(c)
                    : _buildRawView(c),
              ),
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
    final badgeColor = widget.badgeColorOf(c);
    return Row(
      children: [
        Icon(widget.icon, size: 14, color: badgeColor),
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
            color: badgeColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: badgeColor.withValues(alpha: 0.3)),
          ),
          child: Text(
            widget.badgeLabel,
            style: GoogleFonts.firaCode(
                fontSize: 9,
                color: badgeColor,
                fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: 12),
        _SegmentedToggle(
          mode: _mode,
          onChanged: (m) => setState(() => _mode = m),
        ),
        const SizedBox(width: 8),
        _StructuredIconBtn(
          icon: Icons.unfold_more_rounded,
          tooltip: 'Expand all',
          enabled: _root != null && _mode == _ViewMode.tree,
          onTap: _expandAll,
        ),
        _StructuredIconBtn(
          icon: Icons.unfold_less_rounded,
          tooltip: 'Collapse all',
          enabled: _root != null && _mode == _ViewMode.tree,
          onTap: _collapseAll,
        ),
        _StructuredIconBtn(
          icon: Icons.search_rounded,
          tooltip: 'Search (Ctrl+F)',
          enabled: _root != null,
          onTap: _toggleSearch,
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
              hintText: 'Search keys & values…',
              hintStyle:
                  GoogleFonts.firaCode(fontSize: 12, color: c.textMuted),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
        Text(
          _matchedNodes.isEmpty
              ? (_searchQuery.isEmpty ? '' : 'No matches')
              : '${_matchIndex + 1} / ${_matchedNodes.length}',
          style: GoogleFonts.firaCode(
              fontSize: 11,
              color: _matchedNodes.isEmpty ? c.textMuted : c.text),
        ),
        const SizedBox(width: 6),
        _StructuredIconBtn(
          icon: Icons.keyboard_arrow_up_rounded,
          tooltip: 'Previous',
          enabled: _matchedNodes.isNotEmpty,
          onTap: _searchPrev,
        ),
        _StructuredIconBtn(
          icon: Icons.keyboard_arrow_down_rounded,
          tooltip: 'Next',
          enabled: _matchedNodes.isNotEmpty,
          onTap: _searchNext,
        ),
        const SizedBox(width: 6),
        _StructuredIconBtn(
          icon: Icons.close_rounded,
          tooltip: 'Close (Esc)',
          enabled: true,
          onTap: _toggleSearch,
        ),
      ],
    );
  }

  Widget _buildPathBar(AppColors c) {
    final selected = _selected;
    final pathText =
        selected != null ? _displayPath(selected.path) : '— no selection —';
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      color: c.bg,
      child: Row(
        children: [
          Icon(Icons.alternate_email_rounded, size: 12, color: c.textMuted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              pathText,
              style: GoogleFonts.firaCode(
                  fontSize: 11,
                  color: selected != null ? c.text : c.textMuted),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (selected != null) ...[
            _StructuredIconBtn(
              icon: Icons.copy_rounded,
              tooltip: 'Copy path',
              enabled: true,
              onTap: _copyPath,
            ),
            _StructuredIconBtn(
              icon: Icons.content_paste_rounded,
              tooltip: 'Copy value',
              enabled: true,
              onTap: _copyValue,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTreeView(AppColors c) {
    if (widget.parseError != null) {
      return _buildErrorState(c, widget.parseError!);
    }
    if (_root == null) {
      return _buildEmptyState(c);
    }
    final visible = _flattenVisible();
    return Scrollbar(
      controller: _scrollCtrl,
      child: ListView.builder(
        controller: _scrollCtrl,
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: visible.length,
        itemExtent: 22,
        itemBuilder: (_, i) {
          final node = visible[i];
          return _NodeRow(
            node: node,
            expanded: _expanded.contains(node.pathKey),
            selected: _selected?.pathKey == node.pathKey,
            isMatch: _matchedPathKeys.contains(node.pathKey),
            searchQuery: _searchQuery,
            onTap: () => setState(() => _selected = node),
            onToggle: () => _toggleNode(node),
          );
        },
      ),
    );
  }

  Widget _buildRawView(AppColors c) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final theme = Map<String, TextStyle>.from(
        isDark ? atomOneDarkTheme : atomOneLightTheme);
    theme['root'] = (theme['root'] ?? const TextStyle())
        .copyWith(backgroundColor: Colors.transparent);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: SelectionArea(
        child: HighlightView(
          widget.rawContent,
          language: widget.rawLanguage,
          theme: theme,
          textStyle: GoogleFonts.firaCode(fontSize: 12, height: 1.55),
          padding: EdgeInsets.zero,
        ),
      ),
    );
  }

  Widget _buildStatusBar(AppColors c) {
    final root = _root;
    int totalNodes = 0;
    int maxDepth = 0;
    if (root != null) {
      void walk(_TreeNode n) {
        totalNodes++;
        if (n.depth > maxDepth) maxDepth = n.depth;
        for (final ch in n.children) {
          walk(ch);
        }
      }

      walk(root);
    }
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
            root == null
                ? 'invalid ${widget.badgeLabel.toLowerCase()}'
                : '$totalNodes nodes · depth $maxDepth',
            style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted),
          ),
          const SizedBox(width: 12),
          if (root != null)
            Text(
              root.type == _NodeType.array
                  ? 'root: array(${root.childCount})'
                  : root.type == _NodeType.object
                      ? 'root: object(${root.childCount})'
                      : 'root: ${root.type.badge.toLowerCase()}',
              style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted),
            ),
          const Spacer(),
          if (_matchedNodes.isNotEmpty)
            Text('${_matchedNodes.length} matches',
                style:
                    GoogleFonts.firaCode(fontSize: 10, color: c.textMuted)),
        ],
      ),
    );
  }

  Widget _buildEmptyState(AppColors c) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(widget.icon, size: 36, color: c.textMuted),
          const SizedBox(height: 12),
          Text('Empty ${widget.badgeLabel.toLowerCase()}',
              style: GoogleFonts.inter(
                  fontSize: 13,
                  color: c.textMuted,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _buildErrorState(AppColors c, String error) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 36, color: c.red),
              const SizedBox(height: 12),
              Text('Cannot parse ${widget.badgeLabel.toLowerCase()}',
                  style: GoogleFonts.inter(
                      fontSize: 14,
                      color: c.text,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(
                error,
                textAlign: TextAlign.center,
                style: GoogleFonts.firaCode(
                    fontSize: 11, color: c.textMuted, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Tree row ──────────────────────────────────────────────────────────────

class _NodeRow extends StatefulWidget {
  final _TreeNode node;
  final bool expanded;
  final bool selected;
  final bool isMatch;
  final String searchQuery;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  const _NodeRow({
    required this.node,
    required this.expanded,
    required this.selected,
    required this.isMatch,
    required this.searchQuery,
    required this.onTap,
    required this.onToggle,
  });

  @override
  State<_NodeRow> createState() => _NodeRowState();
}

class _NodeRowState extends State<_NodeRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final n = widget.node;
    final indent = n.depth * 14.0;
    final isContainer = n.isContainer;

    final Color rowBg = widget.selected
        ? c.blue.withValues(alpha: 0.18)
        : widget.isMatch
            ? c.orange.withValues(alpha: 0.12)
            : _hover
                ? c.surfaceAlt.withValues(alpha: 0.5)
                : Colors.transparent;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          color: rowBg,
          padding: EdgeInsets.only(left: indent),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 16,
                child: isContainer
                    ? GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.onToggle,
                        child: Icon(
                          widget.expanded
                              ? Icons.keyboard_arrow_down_rounded
                              : Icons.keyboard_arrow_right_rounded,
                          size: 14,
                          color: c.textMuted,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              SizedBox(
                width: 12,
                child: Center(
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: _typeColor(c, n.type),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: _buildLine(c),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLine(AppColors c) {
    final n = widget.node;
    final keyStyle = GoogleFonts.firaCode(
      fontSize: 11.5,
      color: c.purple,
      fontWeight: FontWeight.w500,
    );
    final indexStyle = GoogleFonts.firaCode(
      fontSize: 11.5,
      color: c.textMuted,
    );
    final separatorStyle = GoogleFonts.firaCode(
      fontSize: 11.5,
      color: c.textMuted,
    );

    final children = <InlineSpan>[];

    if (n.key != null) {
      children.add(TextSpan(text: '"${n.key}"', style: keyStyle));
      children.add(TextSpan(text: ': ', style: separatorStyle));
    } else if (n.arrayIndex != null) {
      children.add(TextSpan(text: '[${n.arrayIndex}]', style: indexStyle));
      children.add(TextSpan(text: '  ', style: separatorStyle));
    }

    if (n.type == _NodeType.object) {
      children.add(TextSpan(
        text: widget.expanded
            ? '{'
            : '{ ${n.childCount} ${n.childCount == 1 ? "key" : "keys"} }',
        style: GoogleFonts.firaCode(fontSize: 11.5, color: c.textMuted),
      ));
    } else if (n.type == _NodeType.array) {
      children.add(TextSpan(
        text: widget.expanded
            ? '['
            : '[ ${n.childCount} ${n.childCount == 1 ? "item" : "items"} ]',
        style: GoogleFonts.firaCode(fontSize: 11.5, color: c.textMuted),
      ));
    } else {
      children.add(_primitiveSpan(c, n));
    }

    return RichText(
      text: TextSpan(children: children),
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
    );
  }

  TextSpan _primitiveSpan(AppColors c, _TreeNode n) {
    final base = GoogleFonts.firaCode(
        fontSize: 11.5,
        color: _typeColor(c, n.type),
        fontStyle: n.type == _NodeType.nullValue
            ? FontStyle.italic
            : FontStyle.normal);

    String text;
    switch (n.type) {
      case _NodeType.string:
        text = '"${n.value}"';
        break;
      case _NodeType.number:
      case _NodeType.boolean:
        text = '${n.value}';
        break;
      case _NodeType.nullValue:
        text = 'null';
        break;
      default:
        text = '';
    }

    final q = widget.searchQuery;
    if (q.isNotEmpty) {
      final lower = text.toLowerCase();
      final idx = lower.indexOf(q);
      if (idx >= 0) {
        return TextSpan(children: [
          TextSpan(text: text.substring(0, idx), style: base),
          TextSpan(
            text: text.substring(idx, idx + q.length),
            style: base.copyWith(
              backgroundColor: c.orange.withValues(alpha: 0.4),
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(text: text.substring(idx + q.length), style: base),
        ]);
      }
    }
    return TextSpan(text: text, style: base);
  }

  Color _typeColor(AppColors c, _NodeType t) => switch (t) {
        _NodeType.object => c.purple,
        _NodeType.array => c.blue,
        _NodeType.string => c.green,
        _NodeType.number => c.cyan,
        _NodeType.boolean => c.orange,
        _NodeType.nullValue => c.textMuted,
      };
}

// ─── Tiny themed widgets ───────────────────────────────────────────────────

class _SegmentedToggle extends StatelessWidget {
  final _ViewMode mode;
  final ValueChanged<_ViewMode> onChanged;
  const _SegmentedToggle({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 22,
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          _ToggleBtn(
            label: 'Tree',
            active: mode == _ViewMode.tree,
            onTap: () => onChanged(_ViewMode.tree),
          ),
          _ToggleBtn(
            label: 'Raw',
            active: mode == _ViewMode.raw,
            onTap: () => onChanged(_ViewMode.raw),
          ),
        ],
      ),
    );
  }
}

class _ToggleBtn extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _ToggleBtn({
    required this.label,
    required this.active,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? c.bg : Colors.transparent,
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            label,
            style: GoogleFonts.firaCode(
              fontSize: 10,
              color: active ? c.text : c.textMuted,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

class _StructuredIconBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;
  const _StructuredIconBtn({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });
  @override
  State<_StructuredIconBtn> createState() => _StructuredIconBtnState();
}

class _StructuredIconBtnState extends State<_StructuredIconBtn> {
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
