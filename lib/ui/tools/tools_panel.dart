import 'package:digitorn_client/theme/app_theme.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../services/tool_service.dart';
import '../../main.dart';

class ToolsPanel extends StatefulWidget {
  const ToolsPanel({super.key});

  @override
  State<ToolsPanel> createState() => _ToolsPanelState();
}

class _ToolsPanelState extends State<ToolsPanel> {
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  ToolRecord? _selectedTool;
  String? _selectedCategory;
  List<ToolRecord> _categoryTools = [];
  bool _loadingCategory = false;
  ToolExecuteResult? _executeResult;
  bool _executing = false;
  final Map<String, TextEditingController> _paramCtrls = {};

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_onSearch);
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  void _init() {
    final appId = context.read<AppState>().activeApp?.appId;
    if (appId != null) ToolService().loadCategories(appId);
  }

  void _onSearch() {
    final appId = context.read<AppState>().activeApp?.appId;
    if (appId != null) ToolService().search(appId, _searchCtrl.text);
    if (_searchCtrl.text.isNotEmpty) {
      setState(() => _selectedCategory = null);
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    for (final c in _paramCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _selectCategory(String appId, String catId) async {
    setState(() {
      _selectedCategory = catId;
      _loadingCategory = true;
      _selectedTool = null;
      _searchCtrl.clear();
    });
    final tools = await ToolService().loadCategory(appId, catId);
    setState(() {
      _categoryTools = tools;
      _loadingCategory = false;
    });
  }

  Future<void> _executeTool(String appId) async {
    if (_selectedTool == null || _executing) return;
    setState(() => _executing = true);

    final params = <String, dynamic>{};
    for (final e in _paramCtrls.entries) {
      final val = e.value.text.trim();
      params[e.key] = val;
    }

    final result = await ToolService().executeTool(appId, _selectedTool!.name, params);
    setState(() {
      _executeResult = result;
      _executing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final ts = context.watch<ToolService>();
    final appId = appState.activeApp?.appId ?? '';
    final c = context.colors;

    final isSearching = _searchCtrl.text.trim().isNotEmpty;
    final displayTools = isSearching ? ts.searchResults : _categoryTools;

    return Container(
      color: c.bg,
      child: Column(
        children: [
          // ── Header ────────────────────────────────────────────────────
          _header(appId),

          // ── Search ────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Container(
              height: 32,
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.border),
              ),
              child: TextField(
                controller: _searchCtrl,
                focusNode: _searchFocus,
                style: GoogleFonts.inter(fontSize: 12, color: c.text),
                decoration: InputDecoration(
                  hintText: 'Search tools…',
                  hintStyle: GoogleFonts.inter(fontSize: 12, color: c.textMuted),
                  prefixIcon: ts.isSearching
                      ? Padding(
                          padding: const EdgeInsets.all(9),
                          child: SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 1.5, color: c.textMuted),
                          ),
                        )
                      : Icon(Icons.search_rounded,
                          size: 16, color: c.textMuted),
                  suffixIcon: _searchCtrl.text.isNotEmpty
                      ? GestureDetector(
                          onTap: () {
                            _searchCtrl.clear();
                            setState(() {});
                          },
                          child: Icon(Icons.close_rounded,
                              size: 14, color: c.textMuted),
                        )
                      : null,
                  border: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 0, horizontal: 4),
                  isDense: true,
                ),
              ),
            ),
          ),

          Expanded(
            child: Row(
              children: [
                // ── Left pane: categories or tools ──────────────────────
                SizedBox(
                  width: 200,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border(right: BorderSide(color: c.border)),
                    ),
                    child: isSearching
                        ? _ToolList(
                            tools: displayTools,
                            selected: _selectedTool,
                            onSelect: (t) => setState(() {
                              _selectedTool = t;
                              _executeResult = null;
                              _buildParamCtrls(t);
                            }),
                          )
                        : _CategoryList(
                            service: ts,
                            selected: _selectedCategory,
                            onSelect: (cat) => _selectCategory(appId, cat.id),
                          ),
                  ),
                ),

                // ── Middle pane: tools in category ───────────────────────
                if (!isSearching && _selectedCategory != null)
                  SizedBox(
                    width: 200,
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(right: BorderSide(color: c.border)),
                      ),
                      child: _loadingCategory
                          ? Center(
                              child: CircularProgressIndicator(
                                  strokeWidth: 1.5, color: c.textMuted),
                            )
                          : _ToolList(
                              tools: _categoryTools,
                              selected: _selectedTool,
                              onSelect: (t) => setState(() {
                                _selectedTool = t;
                                _executeResult = null;
                                _buildParamCtrls(t);
                              }),
                            ),
                    ),
                  ),

                // ── Right pane: tool detail + execute ────────────────────
                Expanded(
                  child: _selectedTool != null
                      ? _ToolDetail(
                          tool: _selectedTool!,
                          paramCtrls: _paramCtrls,
                          executing: _executing,
                          result: _executeResult,
                          onExecute: () => _executeTool(appId),
                        )
                      : _EmptyDetail(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(String appId) {
    final c = context.colors;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.construction_rounded, size: 14, color: c.textMuted),
          const SizedBox(width: 8),
          Text('Tools',
              style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: c.text)),
          const Spacer(),
          Consumer<ToolService>(
            builder: (_, ts, __) => Text(
              ts.isLoading ? 'Loading…' : '${ts.categories.length} categories',
              style: GoogleFonts.inter(fontSize: 11, color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  void _buildParamCtrls(ToolRecord tool) {
    for (final c in _paramCtrls.values) {
      c.dispose();
    }
    _paramCtrls.clear();
    final props = tool.schema['properties'] as Map? ?? {};
    for (final key in props.keys) {
      _paramCtrls[key as String] = TextEditingController();
    }
  }
}

class _CategoryList extends StatelessWidget {
  final ToolService service;
  final String? selected;
  final ValueChanged<ToolCategory> onSelect;

  const _CategoryList({required this.service, required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (service.isLoading) {
      return Center(child: CircularProgressIndicator(strokeWidth: 1.5, color: c.textMuted));
    }
    if (service.categories.isEmpty) {
      return Center(
        child: Text('No categories', style: GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: service.categories.length,
      itemBuilder: (_, i) {
        final cat = service.categories[i];
        final isActive = selected == cat.id;
        return _CatTile(cat: cat, isActive: isActive, onTap: () => onSelect(cat));
      },
    );
  }
}

class _CatTile extends StatefulWidget {
  final ToolCategory cat;
  final bool isActive;
  final VoidCallback onTap;
  const _CatTile({required this.cat, required this.isActive, required this.onTap});

  @override
  State<_CatTile> createState() => _CatTileState();
}

class _CatTileState extends State<_CatTile> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: widget.isActive
                  ? c.surfaceAlt
                  : _h ? c.surfaceAlt : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: widget.isActive
                  ? Border.all(color: c.borderHover)
                  : null,
            ),
            child: Row(
              children: [
                Text(widget.cat.icon,
                    style: const TextStyle(fontSize: 14)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.cat.name,
                    style: GoogleFonts.inter(
                        fontSize: 12,
                        color: widget.isActive ? c.text : c.textMuted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.cat.toolCount > 0)
                  Text(
                    '${widget.cat.toolCount}',
                    style: GoogleFonts.firaCode(
                        fontSize: 10, color: c.textMuted),
                  ),
              ],
            ),
          ),
        ),
      );
  }
}

class _ToolList extends StatelessWidget {
  final List<ToolRecord> tools;
  final ToolRecord? selected;
  final ValueChanged<ToolRecord> onSelect;

  const _ToolList({required this.tools, required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (tools.isEmpty) {
      return Center(
        child: Text('No tools', style: GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: tools.length,
      itemBuilder: (_, i) {
        final t = tools[i];
        final isActive = selected?.name == t.name;
        return _ToolTile(tool: t, isActive: isActive, onTap: () => onSelect(t));
      },
    );
  }
}

class _ToolTile extends StatefulWidget {
  final ToolRecord tool;
  final bool isActive;
  final VoidCallback onTap;
  const _ToolTile({required this.tool, required this.isActive, required this.onTap});

  @override
  State<_ToolTile> createState() => _ToolTileState();
}

class _ToolTileState extends State<_ToolTile> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: widget.isActive
                  ? c.surfaceAlt
                  : _h ? c.surfaceAlt : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: widget.isActive
                  ? Border.all(color: c.borderHover)
                  : null,
            ),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.isActive ? c.green : c.textMuted,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.tool.label,
                    style: GoogleFonts.inter(
                        fontSize: 12,
                        color: widget.isActive ? c.text : c.textMuted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
  }
}

class _EmptyDetail extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: c.border),
              ),
              child: Icon(Icons.construction_rounded,
                  color: c.textDim, size: 20),
            ),
            const SizedBox(height: 14),
            Text('Select a tool',
                style: GoogleFonts.inter(
                    fontSize: 13, color: c.textMuted)),
          ],
        ),
      );
  }
}

class _ToolDetail extends StatelessWidget {
  final ToolRecord tool;
  final Map<String, TextEditingController> paramCtrls;
  final bool executing;
  final ToolExecuteResult? result;
  final VoidCallback onExecute;

  const _ToolDetail({
    required this.tool,
    required this.paramCtrls,
    required this.executing,
    required this.result,
    required this.onExecute,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final props = tool.schema['properties'] as Map? ?? {};
    final required = (tool.schema['required'] as List? ?? []).cast<String>();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Tool header ───────────────────────────────────────────────
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                    shape: BoxShape.circle, color: c.green),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(tool.label,
                    style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: c.text)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(tool.name,
              style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted)),
          if (tool.description.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(tool.description,
                style: GoogleFonts.inter(
                    fontSize: 12,
                    color: c.textMuted,
                    height: 1.5)),
          ],

          // ── Category badge ─────────────────────────────────────────────
          if (tool.category.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: c.border),
              ),
              child: Text(tool.category,
                  style: GoogleFonts.inter(
                      fontSize: 10, color: c.textMuted)),
            ),
          ],

          const SizedBox(height: 20),
          Divider(color: c.border, height: 1),
          const SizedBox(height: 16),

          // ── Parameters ────────────────────────────────────────────────
          if (props.isNotEmpty) ...[
            Text('Parameters',
                style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: c.textMuted,
                    letterSpacing: 0.5)),
            const SizedBox(height: 10),
            ...props.entries.map((e) {
              final key = e.key as String;
              final def = e.value as Map? ?? {};
              final isReq = required.contains(key);
              return _ParamField(
                name: key,
                definition: def,
                isRequired: isReq,
                controller: paramCtrls[key] ?? TextEditingController(),
              );
            }),
            const SizedBox(height: 16),
          ],

          // ── Execute button ─────────────────────────────────────────────
          _ExecButton(executing: executing, onTap: onExecute),

          // ── Result ────────────────────────────────────────────────────
          if (result != null) ...[
            const SizedBox(height: 16),
            _ResultPane(result: result!),
          ],
        ],
      ),
    );
  }
}

class _ParamField extends StatelessWidget {
  final String name;
  final Map definition;
  final bool isRequired;
  final TextEditingController controller;

  const _ParamField({
    required this.name,
    required this.definition,
    required this.isRequired,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final type = definition['type'] as String? ?? 'string';
    final description = definition['description'] as String? ?? '';
    final isMultiline = type == 'string' &&
        (name.contains('content') ||
            name.contains('text') ||
            name.contains('code') ||
            (definition['enum'] == null && description.length > 40));

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(name,
                  style: GoogleFonts.firaCode(
                      fontSize: 11, color: c.text)),
              if (isRequired) ...[
                const SizedBox(width: 4),
                Text('*',
                    style: TextStyle(color: c.red, fontSize: 11)),
              ],
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(type,
                    style: GoogleFonts.firaCode(
                        fontSize: 9, color: c.blue)),
              ),
            ],
          ),
          if (description.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(description,
                style: GoogleFonts.inter(
                    fontSize: 10.5, color: c.textMuted, height: 1.4)),
          ],
          const SizedBox(height: 5),
          Container(
            decoration: BoxDecoration(
              color: c.inputBg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: c.border),
            ),
            child: TextField(
              controller: controller,
              minLines: isMultiline ? 3 : 1,
              maxLines: isMultiline ? 8 : 1,
              style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
              decoration: InputDecoration(
                hintText: definition['enum'] != null
                    ? (definition['enum'] as List).join(' | ')
                    : 'Value…',
                hintStyle:
                    GoogleFonts.firaCode(fontSize: 12, color: c.textMuted),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.all(10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExecButton extends StatefulWidget {
  final bool executing;
  final VoidCallback onTap;
  const _ExecButton({required this.executing, required this.onTap});

  @override
  State<_ExecButton> createState() => _ExecButtonState();
}

class _ExecButtonState extends State<_ExecButton> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.executing ? null : widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            height: 36,
            decoration: BoxDecoration(
              color: widget.executing
                  ? c.surfaceAlt
                  : _h
                      ? c.skeletonHighlight
                      : c.border,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.borderHover),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.executing)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: c.textMuted),
                  )
                else
                  Icon(Icons.play_arrow_rounded,
                      size: 15, color: c.green),
                const SizedBox(width: 8),
                Text(
                  widget.executing ? 'Executing…' : 'Execute',
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: widget.executing ? c.textMuted : c.text),
                ),
              ],
            ),
          ),
        ),
      );
  }
}

class _ResultPane extends StatelessWidget {
  final ToolExecuteResult result;
  const _ResultPane({required this.result});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = result.success ? c.green : c.red;
    String display = '';
    if (result.success) {
      try {
        display = const JsonEncoder.withIndent('  ')
            .convert(result.data ?? {});
      } catch (_) {
        display = result.data?.toString() ?? '';
      }
    } else {
      display = result.error;
    }

    return Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: [
                Icon(
                  result.success
                      ? Icons.check_circle_outline_rounded
                      : Icons.error_outline_rounded,
                  size: 13,
                  color: color,
                ),
                const SizedBox(width: 6),
                Text(
                  result.success ? 'Success' : 'Error',
                  style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: color),
                ),
                const Spacer(),
                Text(
                  '${result.durationMs.toStringAsFixed(0)} ms',
                  style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => Clipboard.setData(ClipboardData(text: display)),
                  child: Icon(Icons.copy_outlined, size: 12, color: c.textMuted),
                ),
              ],
            ),
          ),
          Container(
            height: 1,
            color: color.withValues(alpha: 0.1),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              display,
              style: GoogleFonts.firaCode(
                  fontSize: 11,
                  color: result.success ? c.text : c.red,
                  height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
