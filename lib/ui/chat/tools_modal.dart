import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../services/tool_service.dart';
import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';

/// Hidden system tools that shouldn't be shown to users
const _hiddenTools = {
  'set_goal', 'setgoal', 'remember', 'recall', 'forget',
  'add_todo', 'update_todo', 'todoadd', 'todoupdate',
  'spawn_agent', 'agent_spawn', 'agent_wait', 'agent_wait_all',
  'agentwaitall', 'agent_result', 'agent_status', 'agent_cancel', 'agent_list',
  'search_tools', 'get_tool', 'list_categories', 'browse_category',
};

bool _isSystemTool(String name) {
  final lower = name.toLowerCase().split(RegExp(r'[.__]')).last;
  return _hiddenTools.contains(lower) ||
      name.toLowerCase().contains('memory') ||
      name.toLowerCase().contains('agent_spawn');
}

class ToolsModal {
  static void show(BuildContext context, String appId) {
    showDialog(
      context: context,
      barrierColor: Colors.black38,
      builder: (_) => _ToolsDialog(appId: appId),
    );
  }
}

class _ToolsDialog extends StatefulWidget {
  final String appId;
  const _ToolsDialog({required this.appId});

  @override
  State<_ToolsDialog> createState() => _ToolsDialogState();
}

class _ToolsDialogState extends State<_ToolsDialog> {
  final _searchCtrl = TextEditingController();
  List<ToolCategory> _categories = [];
  List<ToolRecord> _allTools = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(() => setState(() {}));
  }

  Future<void> _load() async {
    final svc = ToolService();
    await svc.loadCategories(widget.appId);
    _categories = svc.categories;

    // Load tools from each category
    _allTools = [];
    for (final cat in _categories) {
      final tools = await svc.loadCategory(widget.appId, cat.id);
      _allTools.addAll(tools);
    }

    // Filter out system tools
    _allTools.removeWhere((t) => _isSystemTool(t.name));

    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final query = _searchCtrl.text.toLowerCase();

    // Filter tools by search
    final filtered = query.isEmpty
        ? _allTools
        : _allTools.where((t) =>
            t.name.toLowerCase().contains(query) ||
            t.description.toLowerCase().contains(query)
          ).toList();

    // Sort alphabetically by display name
    filtered.sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));

    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: c.border),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header + search
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(Icons.build_outlined, size: 18, color: c.textMuted),
                      const SizedBox(width: 8),
                      Text('Available Tools',
                        style: GoogleFonts.inter(
                          fontSize: 16, fontWeight: FontWeight.w600, color: c.textBright)),
                      const Spacer(),
                      if (!_loading)
                        Text('${filtered.length} tools',
                          style: GoogleFonts.firaCode(fontSize: 11, color: c.textMuted)),
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Icon(Icons.close_rounded, size: 18, color: c.textMuted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Search
                  SizedBox(
                    height: 34,
                    child: TextField(
                      controller: _searchCtrl,
                      autofocus: true,
                      style: GoogleFonts.inter(fontSize: 13, color: c.text),
                      decoration: InputDecoration(
                        hintText: 'Search tools...',
                        hintStyle: GoogleFonts.inter(fontSize: 13, color: c.textMuted),
                        prefixIcon: Icon(Icons.search_rounded, size: 16, color: c.textMuted),
                        prefixIconConstraints: const BoxConstraints(minWidth: 36),
                        filled: true,
                        fillColor: c.bg,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: c.border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: c.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: c.blue),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Divider(height: 1, color: c.border),

            // Tools list
            Flexible(
              child: _loading
                  ? Center(child: CircularProgressIndicator(strokeWidth: 1.5, color: c.textMuted))
                  : filtered.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(
                              query.isEmpty ? 'No tools available' : 'No tools matching "$query"',
                              style: GoogleFonts.inter(fontSize: 13, color: c.textMuted),
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: filtered.length,
                          itemBuilder: (_, i) => _ToolRow(tool: filtered[i], c: c),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolRow extends StatefulWidget {
  final ToolRecord tool;
  final AppColors c;
  const _ToolRow({required this.tool, required this.c});

  @override
  State<_ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<_ToolRow> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.tool;
    final c = widget.c;
    // User-friendly name: use label, convert snake_case to Title Case
    final friendlyName = _friendlyToolName(t.label.isNotEmpty ? t.label : t.name);

    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        color: _h ? c.surfaceAlt : Colors.transparent,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Tool icon
            Container(
              width: 32, height: 32,
              margin: const EdgeInsets.only(right: 12, top: 1),
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.border),
              ),
              child: Icon(
                _toolIcon(t.name),
                size: 15, color: c.blue,
              ),
            ),
            // Name + description
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(friendlyName,
                    style: GoogleFonts.inter(
                      fontSize: 13, fontWeight: FontWeight.w600, color: c.textBright)),
                  if (t.description.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      t.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(fontSize: 12, color: c.textMuted, height: 1.4),
                    ),
                  ],
                ],
              ),
            ),
            // Risk level badge
            if (t.riskLevel.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(left: 8, top: 2),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _riskColor(t.riskLevel).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(t.riskLevel,
                  style: GoogleFonts.firaCode(
                    fontSize: 9, color: _riskColor(t.riskLevel))),
              ),
          ],
        ),
      ),
    );
  }

  /// Convert "filesystem__read" or "read_file" → "Read File"
  String _friendlyToolName(String raw) {
    // Remove module prefix (filesystem.read → read, filesystem__read → read)
    final parts = raw.split(RegExp(r'[.__]'));
    final action = parts.length > 1 ? parts.sublist(1).join('_') : parts.last;
    // Convert snake_case to Title Case
    return action
        .split('_')
        .where((s) => s.isNotEmpty)
        .map((s) => s[0].toUpperCase() + s.substring(1))
        .join(' ');
  }

  IconData _toolIcon(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('read') || lower.contains('glob') || lower.contains('find')) return Icons.visibility_outlined;
    if (lower.contains('write') || lower.contains('edit')) return Icons.edit_outlined;
    if (lower.contains('bash') || lower.contains('shell')) return Icons.terminal_rounded;
    if (lower.contains('git')) return Icons.call_split_rounded;
    if (lower.contains('search') || lower.contains('grep')) return Icons.search_rounded;
    if (lower.contains('web') || lower.contains('fetch') || lower.contains('http')) return Icons.language_rounded;
    if (lower.contains('database') || lower.contains('sql')) return Icons.storage_rounded;
    return Icons.build_outlined;
  }

  Color _riskColor(String level) => switch (level.toLowerCase()) {
    'high' => const Color(0xFFEF4444),
    'medium' => const Color(0xFFF59E0B),
    'low' => const Color(0xFF22C55E),
    _ => const Color(0xFF888888),
  };
}
