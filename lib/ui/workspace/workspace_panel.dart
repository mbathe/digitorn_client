import 'package:digitorn_client/theme/app_theme.dart';
import 'dart:io' as io;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:flutter_fancy_tree_view/flutter_fancy_tree_view.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../../services/workspace_service.dart';
import '../../main.dart';
import 'code_editor.dart';

class WorkspacePanel extends StatelessWidget {
  const WorkspacePanel({super.key});

  @override
  Widget build(BuildContext context) {
    return const _WorkspacePanelInner();
  }
}

class _WorkspacePanelInner extends StatefulWidget {
  const _WorkspacePanelInner();

  @override
  State<_WorkspacePanelInner> createState() => _WorkspacePanelInnerState();
}

class _WorkspacePanelInnerState extends State<_WorkspacePanelInner>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WorkspaceService>();
    final appState = context.watch<AppState>();

    // Sync tab with activeTab from service
    final tabIndex = switch (ws.activeTab) {
      'diagnostics' => 1,
      _ => 0,
    };
    if (_tabs.index != tabIndex) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _tabs.animateTo(tabIndex),
      );
    }

    return Container(
      color: context.colors.bg,
      child: Column(
        children: [
          // ── Header ──────────────────────────────────────────────────────
          _PanelHeader(
            appState: appState,
            ws: ws,
            tabs: _tabs,
            onTabChange: (i) {
              final tab = switch (i) { 1 => 'diagnostics', _ => 'files' };
              ws.setActiveTab(tab);
            },
          ),

          // ── Content ─────────────────────────────────────────────────────
          Expanded(
            child: TabBarView(
              controller: _tabs,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _FilesTab(ws: ws),
                _DiagnosticsTab(ws: ws),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Header with tabs ─────────────────────────────────────────────────────────

class _PanelHeader extends StatelessWidget {
  final AppState appState;
  final WorkspaceService ws;
  final TabController tabs;
  final ValueChanged<int> onTabChange;

  const _PanelHeader({
    required this.appState,
    required this.ws,
    required this.tabs,
    required this.onTabChange,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.colors.surface,
        border: Border(bottom: BorderSide(color: context.colors.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Title row ───────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              children: [
                // Git status
                if (ws.gitStatus != null && ws.gitStatus!.branch.isNotEmpty)
                  _GitBadge(ws.gitStatus!),
                if (ws.gitStatus != null && ws.gitStatus!.branch.isNotEmpty)
                  const SizedBox(width: 6),

                // Workspace path — must be Expanded to prevent overflow
                Expanded(
                  child: appState.workspace.isNotEmpty
                      ? Text(
                          appState.workspace.replaceAll('\\', '/').split('/').last,
                          style: GoogleFonts.firaCode(
                              fontSize: 11, color: context.colors.textMuted),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        )
                      : Text(
                          'Workspace',
                          style: GoogleFonts.inter(
                              fontSize: 12, color: context.colors.textMuted),
                        ),
                ),

                // Close button
                const SizedBox(width: 4),
                _IconBtn(
                  icon: Icons.close_rounded,
                  size: 13,
                  onTap: () => appState.closeWorkspace(),
                  tooltip: 'Close workspace',
                ),
              ],
            ),
          ),

          // ── Tabs ────────────────────────────────────────────────────────
          _TabBar(
            tabs: tabs,
            ws: ws,
            onTabChange: onTabChange,
          ),
        ],
      ),
    );
  }
}

class _GitBadge extends StatelessWidget {
  final GitStatus git;
  const _GitBadge(this.git);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: c.green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: c.green.withValues(alpha: 0.15)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.call_split_rounded,
              size: 10, color: c.green),
          const SizedBox(width: 4),
          Text(git.branch,
              style: GoogleFonts.firaCode(
                  fontSize: 10, color: c.green)),
          if (git.changes.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text('${git.changes.length}',
                style: GoogleFonts.firaCode(
                    fontSize: 10, color: c.orange)),
          ],
        ],
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  final TabController tabs;
  final WorkspaceService ws;
  final ValueChanged<int> onTabChange;

  const _TabBar({required this.tabs, required this.ws, required this.onTabChange});

  @override
  Widget build(BuildContext context) {
    return TabBar(
      controller: tabs,
      onTap: onTabChange,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      labelStyle: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w500),
      unselectedLabelStyle: GoogleFonts.inter(fontSize: 11),
      labelColor: context.colors.text,
      unselectedLabelColor: context.colors.textMuted,
      indicatorColor: context.colors.textMuted,
      indicatorWeight: 1,
      indicatorSize: TabBarIndicatorSize.tab,
      dividerColor: Colors.transparent,
      padding: EdgeInsets.zero,
      tabs: [
        // Files tab
        Tab(
          height: 36,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.folder_open_outlined, size: 12),
              const SizedBox(width: 5),
              const Text('Files'),
              if (ws.buffers.isNotEmpty) ...[
                const SizedBox(width: 4),
                _TabBadge('${ws.buffers.length}',
                    color: context.colors.textDim),
              ],
            ],
          ),
        ),
        // Diagnostics tab
        Tab(
          height: 36,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded,
                  size: 12,
                  color: ws.errorCount > 0
                      ? context.colors.red
                      : null),
              const SizedBox(width: 5),
              const Text('Diag.'),
              if (ws.errorCount > 0) ...[
                const SizedBox(width: 4),
                _TabBadge('${ws.errorCount}',
                    color: context.colors.red.withValues(alpha: 0.15),
                    fg: context.colors.red),
              ] else if (ws.warningCount > 0) ...[
                const SizedBox(width: 4),
                _TabBadge('${ws.warningCount}',
                    color: context.colors.orange.withValues(alpha: 0.15),
                    fg: context.colors.orange),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _TabBadge extends StatelessWidget {
  final String label;
  final Color color;
  final Color fg;
  const _TabBadge(this.label, {required this.color, this.fg = const Color(0xFF888888)});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label,
            style: GoogleFonts.firaCode(fontSize: 9, color: fg)),
      );
}

// ─── Files Tab ────────────────────────────────────────────────────────────────

class _FilesTab extends StatelessWidget {
  final WorkspaceService ws;
  const _FilesTab({required this.ws});

  @override
  Widget build(BuildContext context) {
    if (ws.buffers.isEmpty) {
      return _EmptyPane(
        icon: Icons.folder_open_outlined,
        title: 'No files open',
        subtitle: 'Files appear here when the agent reads or writes them',
      );
    }

    final isMobile = MediaQuery.of(context).size.width < 600;
    return Row(
      children: [
        // ── File tree (explorer) — hidden on mobile ─────────────────────
        if (ws.buffers.length > 1 && !isMobile)
          _FileTreePanel(ws: ws),
        // ── Editor area ──────────────────────────────────────────────────
        Expanded(
          child: Column(
            children: [
              // File tabs (horizontal)
              Container(
                height: 36,
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: context.colors.border)),
                ),
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: ws.buffers.length,
                  itemBuilder: (_, i) {
                    final buf = ws.buffers[i];
                    final isActive = buf.path == ws.activeBufferPath;
                    return _FileTab(
                      buffer: buf,
                      isActive: isActive,
                      onTap: () => ws.setActiveBuffer(buf.path),
                      onClose: () => ws.closeBuffer(buf.path),
                    );
                  },
                ),
              ),
              // Code view
              Expanded(
                child: ws.activeBuffer != null
                    ? _CodeView(buffer: ws.activeBuffer!)
                    : const _EmptyPane(
                        icon: Icons.code_rounded,
                        title: 'Select a file',
                        subtitle: '',
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FileTab extends StatefulWidget {
  final WorkbenchBuffer buffer;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onClose;

  const _FileTab({
    required this.buffer,
    required this.isActive,
    required this.onTap,
    required this.onClose,
  });

  @override
  State<_FileTab> createState() => _FileTabState();
}

class _FileTabState extends State<_FileTab> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: widget.isActive
                ? context.colors.bg
                : _hovered
                    ? context.colors.surfaceAlt
                    : context.colors.surface,
            border: Border(
              right: BorderSide(color: context.colors.border),
              bottom: widget.isActive
                  ? BorderSide(color: context.colors.bg, width: 2)
                  : BorderSide.none,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Edit dot if modified
              if (widget.buffer.isEdited)
                Container(
                  width: 6,
                  height: 6,
                  margin: const EdgeInsets.only(right: 5),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: context.colors.orange,
                  ),
                ),
              // File icon
              _fileIcon(widget.buffer.extension),
              const SizedBox(width: 6),
              Text(
                widget.buffer.filename,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: widget.isActive
                      ? context.colors.text
                      : context.colors.textMuted,
                ),
              ),
              const SizedBox(width: 6),
              // Close button
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: widget.onClose,
                  child: Icon(
                    Icons.close_rounded,
                    size: 12,
                    color: _hovered
                        ? context.colors.textMuted
                        : Colors.transparent,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fileIcon(String ext) {
    final color = switch (ext) {
      'dart' => const Color(0xFF54C5F8),
      'py' => const Color(0xFF3776AB),
      'ts' || 'tsx' => const Color(0xFF3178C6),
      'js' || 'jsx' => const Color(0xFFF7DF1E),
      'json' => const Color(0xFFD4A017),
      'yaml' || 'yml' => const Color(0xFFCB171E),
      'md' => const Color(0xFF888888),
      'html' => const Color(0xFFE34F26),
      'css' => const Color(0xFF1572B6),
      'go' => const Color(0xFF00ADD8),
      'rs' => const Color(0xFFF74C00),
      _ => const Color(0xFF555555),
    };
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Center(
        child: Text(
          ext.isNotEmpty ? ext[0].toUpperCase() : '?',
          style: TextStyle(fontSize: 8, color: color, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}

class _CodeView extends StatelessWidget {
  final WorkbenchBuffer buffer;
  const _CodeView({required this.buffer});

  static const _imageExts = {'png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp', 'svg', 'ico'};

  @override
  Widget build(BuildContext context) {
    // Markdown → preview (check both extension and path)
    final ext = buffer.extension;
    final isMarkdown = ext == 'md' || ext == 'markdown' ||
        buffer.path.endsWith('.md') || buffer.path.endsWith('.markdown');
    if (isMarkdown) {
      return _MarkdownPreview(content: buffer.content, filename: buffer.filename);
    }
    // Image → preview
    if (_imageExts.contains(buffer.extension)) {
      return _ImagePreview(path: buffer.path, filename: buffer.filename);
    }
    return CodeEditorPane(
      key: ValueKey('${buffer.path}-${buffer.chars}'),
      content: buffer.content,
      previousContent: buffer.previousContent,
      filename: buffer.filename,
      readOnly: true,
      isEdited: buffer.isEdited,
    );
  }
}

class _ImagePreview extends StatelessWidget {
  final String path;
  final String filename;
  const _ImagePreview({required this.path, required this.filename});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: context.colors.surface,
          child: Row(
            children: [
              Icon(Icons.image_outlined, size: 14, color: context.colors.textMuted),
              const SizedBox(width: 8),
              Text(filename, style: GoogleFonts.firaCode(fontSize: 12, color: context.colors.text)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: context.colors.border,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text('IMAGE',
                  style: GoogleFonts.firaCode(fontSize: 9, color: context.colors.textMuted)),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: context.colors.bg,
            padding: const EdgeInsets.all(16),
            child: Center(
              child: kIsWeb
                  ? Image.network(path, fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => _imageErrorWidget())
                  : Image.file(io.File(path), fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => _imageErrorWidget()),
            ),
          ),
        ),
      ],
    );
  }
}

Widget _imageErrorWidget() => const Column(
  mainAxisAlignment: MainAxisAlignment.center,
  children: [
    Icon(Icons.broken_image_outlined, size: 48, color: Color(0xFF555555)),
    SizedBox(height: 12),
    Text('Cannot load image', style: TextStyle(color: Color(0xFF555555), fontSize: 13)),
  ],
);

class _MarkdownPreview extends StatelessWidget {
  final String content;
  final String filename;
  const _MarkdownPreview({required this.content, required this.filename});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: context.colors.surface,
          child: Row(
            children: [
              Icon(Icons.description, size: 14, color: context.colors.textMuted),
              const SizedBox(width: 8),
              Text(filename, style: GoogleFonts.firaCode(fontSize: 12, color: context.colors.text)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: context.colors.border,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text('PREVIEW',
                  style: GoogleFonts.firaCode(fontSize: 9, color: context.colors.textMuted)),
              ),
            ],
          ),
        ),
        Expanded(
          child: Markdown(
            data: content,
            selectable: true,
            padding: const EdgeInsets.all(16),
            styleSheet: MarkdownStyleSheet(
              p: GoogleFonts.inter(fontSize: 14, color: context.colors.text, height: 1.65),
              h1: GoogleFonts.inter(fontSize: 22, fontWeight: FontWeight.w700, color: context.colors.text),
              h2: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w600, color: context.colors.text),
              h3: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600, color: context.colors.text),
              code: GoogleFonts.firaCode(fontSize: 12.5, color: context.colors.purple,
                  backgroundColor: context.colors.codeBg),
              codeblockDecoration: BoxDecoration(
                color: context.colors.codeBlockBg,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: context.colors.border),
              ),
              blockquoteDecoration: BoxDecoration(
                border: Border(left: BorderSide(color: context.colors.borderHover, width: 2.5)),
              ),
              strong: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, color: context.colors.text),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── File tree node ──────────────────────────────────────────────────────────

class _FileNode {
  final String name;
  final String fullPath;
  final bool isDir;
  final WorkbenchBuffer? buffer;
  final List<_FileNode> children;

  _FileNode({
    required this.name,
    required this.fullPath,
    this.isDir = false,
    this.buffer,
    List<_FileNode>? children,
  }) : children = children ?? [];
}

/// Build a tree from flat buffer list
List<_FileNode> _buildFileTree(List<WorkbenchBuffer> buffers) {
  // Group by directory
  final Map<String, List<WorkbenchBuffer>> grouped = {};
  for (final buf in buffers) {
    final dir = buf.directory;
    grouped.putIfAbsent(dir, () => []).add(buf);
  }

  final roots = <_FileNode>[];
  for (final entry in grouped.entries) {
    final dirName = entry.key.isEmpty
        ? '.'
        : entry.key.replaceAll('\\', '/').split('/').last;
    final fileNodes = entry.value
        .map((b) => _FileNode(name: b.filename, fullPath: b.path, buffer: b))
        .toList();

    if (grouped.length == 1) {
      // Single dir — show files flat
      roots.addAll(fileNodes);
    } else {
      // Multiple dirs — group under folder
      roots.add(_FileNode(
        name: dirName,
        fullPath: entry.key,
        isDir: true,
        children: fileNodes,
      ));
    }
  }
  return roots;
}

class _FileTreePanel extends StatefulWidget {
  final WorkspaceService ws;
  const _FileTreePanel({required this.ws});

  @override
  State<_FileTreePanel> createState() => _FileTreePanelState();
}

class _FileTreePanelState extends State<_FileTreePanel> {
  late TreeController<_FileNode> _treeCtrl;
  List<_FileNode> _roots = [];

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  @override
  void didUpdateWidget(_FileTreePanel old) {
    super.didUpdateWidget(old);
    _rebuild();
  }

  void _rebuild() {
    _roots = _buildFileTree(widget.ws.buffers);
    _treeCtrl = TreeController<_FileNode>(
      roots: _roots,
      childrenProvider: (node) => node.children,
    );
    // Expand all dirs by default
    for (final r in _roots) {
      if (r.isDir) _treeCtrl.expand(r);
    }
  }

  @override
  void dispose() {
    _treeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    if (isMobile) return const SizedBox.shrink(); // Hide tree on mobile
    return Container(
      width: 180,
      decoration: BoxDecoration(
        color: context.colors.bg,
        border: Border(right: BorderSide(color: context.colors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
            child: Text('EXPLORER',
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: context.colors.textMuted,
                letterSpacing: 0.5,
              ),
            ),
          ),
          Expanded(
            child: AnimatedTreeView<_FileNode>(
              treeController: _treeCtrl,
              nodeBuilder: (context, entry) {
                final node = entry.node;
                final isActive = node.buffer?.path == widget.ws.activeBufferPath;

                if (node.isDir) {
                  return _TreeDirRow(
                    name: node.name,
                    isExpanded: entry.isExpanded,
                    onTap: () => _treeCtrl.toggleExpansion(node),
                    indent: entry.level,
                  );
                }

                return _TreeFileRow(
                  buffer: node.buffer!,
                  isActive: isActive,
                  indent: entry.level,
                  onTap: () => widget.ws.setActiveBuffer(node.fullPath),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TreeDirRow extends StatelessWidget {
  final String name;
  final bool isExpanded;
  final VoidCallback onTap;
  final int indent;
  const _TreeDirRow({
    required this.name, required this.isExpanded,
    required this.onTap, required this.indent,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.only(left: 8.0 + indent * 12, top: 3, bottom: 3, right: 8),
        child: Row(
          children: [
            Icon(
              isExpanded ? Icons.folder_open_rounded : Icons.folder_rounded,
              size: 14, color: context.colors.orange,
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(name,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(fontSize: 12, color: context.colors.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TreeFileRow extends StatefulWidget {
  final WorkbenchBuffer buffer;
  final bool isActive;
  final int indent;
  final VoidCallback onTap;
  const _TreeFileRow({
    required this.buffer, required this.isActive,
    required this.indent, required this.onTap,
  });

  @override
  State<_TreeFileRow> createState() => _TreeFileRowState();
}

class _TreeFileRowState extends State<_TreeFileRow> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final buf = widget.buffer;
    final stats = buf.diffStats;
    final hasStats = stats.insertions > 0 || stats.deletions > 0;

    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: EdgeInsets.only(
            left: 8.0 + widget.indent * 12,
            top: 3, bottom: 3, right: 8,
          ),
          color: widget.isActive
              ? context.colors.surfaceAlt
              : _h ? context.colors.surface : Colors.transparent,
          child: Row(
            children: [
              Icon(
                _fileIcon(buf.extension),
                size: 13,
                color: widget.isActive
                    ? context.colors.text
                    : _fileColor(buf.extension),
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  buf.filename,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: widget.isActive ? context.colors.text : context.colors.textMuted,
                  ),
                ),
              ),
              // Diff stats: +N -N
              if (hasStats) ...[
                if (stats.insertions > 0)
                  Text('+${stats.insertions}',
                    style: GoogleFonts.firaCode(
                      fontSize: 10, color: context.colors.green),
                  ),
                if (stats.insertions > 0 && stats.deletions > 0)
                  const SizedBox(width: 3),
                if (stats.deletions > 0)
                  Text('-${stats.deletions}',
                    style: GoogleFonts.firaCode(
                      fontSize: 10, color: context.colors.red),
                  ),
              ] else if (buf.isEdited) ...[
                Container(
                  width: 6, height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: context.colors.orange,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

IconData _fileIcon(String ext) => switch (ext) {
  'py'   => Icons.code,
  'dart' => Icons.flutter_dash,
  'js' || 'jsx' || 'ts' || 'tsx' => Icons.javascript,
  'json' => Icons.data_object,
  'yaml' || 'yml' => Icons.settings,
  'md'   => Icons.description,
  'sh' || 'bash' => Icons.terminal,
  'html' => Icons.html,
  'css'  => Icons.css,
  'sql'  => Icons.storage,
  _ => Icons.insert_drive_file,
};

Color _fileColor(String ext) => switch (ext) {
  'py'   => const Color(0xFF3572A5),
  'dart' => const Color(0xFF02569B),
  'js' || 'jsx' => const Color(0xFFF7DF1E),
  'ts' || 'tsx' => const Color(0xFF3178C6),
  'html' => const Color(0xFFE34C26),
  'css'  => const Color(0xFF563D7C),
  'json' => const Color(0xFF555555),
  'yaml' || 'yml' => const Color(0xFFCB171E),
  'md'   => const Color(0xFF555555),
  'sh' || 'bash' => const Color(0xFF3FB950),
  'sql'  => const Color(0xFFE38C00),
  _ => const Color(0xFF555555),
};

// ─── Diagnostics Tab ──────────────────────────────────────────────────────────

class _DiagnosticsTab extends StatelessWidget {
  final WorkspaceService ws;
  const _DiagnosticsTab({required this.ws});

  @override
  Widget build(BuildContext context) {
    if (ws.diagnostics.isEmpty) {
      return const _EmptyPane(
        icon: Icons.check_circle_outline_rounded,
        title: 'No diagnostics',
        subtitle: 'Code issues will appear here after writes',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: ws.diagnostics.length,
      itemBuilder: (_, i) => _DiagnosticTile(ws.diagnostics[i]),
    );
  }
}

class _DiagnosticTile extends StatelessWidget {
  final DiagnosticItem item;
  const _DiagnosticTile(this.item);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (color, icon) = switch (item.severity) {
      'error' => (c.red, Icons.error_outline_rounded),
      'warning' => (c.orange, Icons.warning_amber_rounded),
      _ => (c.textMuted, Icons.info_outline_rounded),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.message,
                  style: GoogleFonts.inter(
                      fontSize: 12, color: context.colors.text, height: 1.4),
                ),
                const SizedBox(height: 3),
                Text(
                  '${item.path.split('/').last}:${item.line}',
                  style: GoogleFonts.firaCode(
                      fontSize: 10, color: context.colors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Shared widgets ───────────────────────────────────────────────────────────

class _EmptyPane extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _EmptyPane(
      {required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: context.colors.surfaceAlt,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: context.colors.border),
              ),
              child: Icon(icon, color: context.colors.borderHover, size: 22),
            ),
            const SizedBox(height: 16),
            Text(title,
                style: GoogleFonts.inter(
                    fontSize: 13,
                    color: context.colors.textMuted,
                    fontWeight: FontWeight.w500)),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(subtitle,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                      fontSize: 11.5,
                      color: context.colors.textDim,
                      height: 1.5)),
            ],
          ],
        ),
      );
}

class _IconBtn extends StatefulWidget {
  final IconData icon;
  final double size;
  final String tooltip;
  final VoidCallback onTap;
  const _IconBtn(
      {required this.icon,
      this.size = 14,
      required this.tooltip,
      required this.onTap});

  @override
  State<_IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<_IconBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: widget.tooltip,
        child: MouseRegion(
          onEnter: (_) => setState(() => _h = true),
          onExit: (_) => setState(() => _h = false),
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: widget.onTap,
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: _h
                    ? context.colors.surfaceAlt
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Icon(widget.icon,
                  size: widget.size,
                  color: _h
                      ? context.colors.text
                      : context.colors.textMuted),
            ),
          ),
        ),
      );
}
