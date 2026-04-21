import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../design/tokens.dart';
import '../../../services/recent_attachments_service.dart';
import '../../../services/session_service.dart';
import '../../../services/workspace_module.dart';
import '../../../theme/app_theme.dart';
import 'attachment_helpers.dart';

/// Trigger button + overlay for the premium attach menu. Replaces
/// the previous PopupMenuButton with a wide 280-px dropdown whose
/// entries are 44-px rows (icon • title • subtitle • shortcut hint).
///
/// The caller feeds a single [onAttach] callback per file. Multi-
/// select is handled internally via `openFiles()` so the composer
/// doesn't need to care.
class AttachMenuButton extends StatefulWidget {
  final bool disabled;
  final TextEditingController controller;
  final FocusNode focusNode;
  final void Function(String name, String path, bool isImage)? onAttach;

  const AttachMenuButton({
    super.key,
    required this.disabled,
    required this.controller,
    required this.focusNode,
    this.onAttach,
  });

  @override
  State<AttachMenuButton> createState() => _AttachMenuButtonState();
}

class _AttachMenuButtonState extends State<AttachMenuButton> {
  final _buttonKey = GlobalKey();
  bool _hover = false;
  bool _open = false;
  OverlayEntry? _entry;
  ScaffoldMessengerState? _messenger;

  void _attachFile(String name, String path, bool isImage) {
    widget.onAttach?.call(name, path, isImage);
  }

  void _toast(String text, {Color? bg}) {
    _messenger ??= ScaffoldMessenger.maybeOf(context);
    _messenger?.showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: bg,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _pickFiles() async {
    _dismiss();
    try {
      final results = await openFiles();
      for (final f in results) {
        final isImg = isImagePath(f.path);
        _attachFile(f.name, f.path, isImg);
        unawaited(RecentAttachmentsService()
            .record(name: f.name, path: f.path, isImage: isImg));
      }
    } catch (e) {
      _toast('File picker failed: $e');
    }
  }

  Future<void> _pickImages() async {
    _dismiss();
    try {
      final results = await openFiles(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'Images',
            extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
          ),
        ],
      );
      for (final f in results) {
        _attachFile(f.name, f.path, true);
        unawaited(RecentAttachmentsService()
            .record(name: f.name, path: f.path, isImage: true));
      }
    } catch (e) {
      _toast('Image picker failed: $e');
    }
  }

  Future<void> _attachRecent(RecentAttachment r) async {
    _dismiss();
    if (!File(r.path).existsSync()) {
      _toast('File no longer exists — removed from recents');
      unawaited(RecentAttachmentsService().remove(r.path));
      return;
    }
    _attachFile(r.name, r.path, r.isImage);
    unawaited(RecentAttachmentsService()
        .record(name: r.name, path: r.path, isImage: r.isImage));
  }

  Future<void> _attachWorkspaceFile(WorkspaceFile f) async {
    _dismiss();
    final session = SessionService().activeSession;
    if (session == null) {
      _toast('No active session to download from');
      return;
    }
    _toast('Downloading ${_basename(f.path)}…');
    final tmp = await downloadWorkspaceFileToTemp(
      appId: session.appId,
      sessionId: session.sessionId,
      workspacePath: f.path,
    );
    if (tmp == null) {
      _toast('Failed to download workspace file');
      return;
    }
    final name = _basename(f.path);
    _attachFile(name, tmp, isImagePath(f.path));
  }

  static String _basename(String p) {
    final parts = p.split(RegExp(r'[\\/]'));
    for (final part in parts.reversed) {
      if (part.isNotEmpty) return part;
    }
    return p;
  }

  Future<void> _pasteClipboard() async {
    _dismiss();
    // Capture the error colour synchronously — using Theme.of after
    // an `await` triggers the use_build_context_synchronously lint
    // and is unsound on the off-chance the tree rebuilt in the gap.
    final errorColor = Theme.of(context).colorScheme.error;
    final path = await clipboardImageToTempFile();
    if (path == null) {
      _toast('Clipboard has no image', bg: errorColor);
      return;
    }
    final name = path.split(Platform.pathSeparator).last;
    _attachFile(name, path, true);
    _toast('Pasted image from clipboard');
  }

  Future<void> _capture() async {
    _dismiss();
    _toast('Select an area to capture…');
    final path = await captureScreenshot();
    if (path == null) {
      _toast(
        Platform.isLinux
            ? 'Screenshot tool unavailable — install gnome-screenshot or copy manually'
            : 'No screenshot captured',
      );
      return;
    }
    final name = path.split(Platform.pathSeparator).last;
    _attachFile(name, path, true);
    _toast('Screenshot attached');
  }

  void _openSlash() {
    _dismiss();
    widget.controller.text = '/';
    widget.controller.selection = const TextSelection.collapsed(offset: 1);
    widget.focusNode.requestFocus();
  }

  void _showMenu() {
    if (_open || widget.disabled) return;
    final render =
        _buttonKey.currentContext?.findRenderObject() as RenderBox?;
    if (render == null) return;
    final topLeft = render.localToGlobal(Offset.zero);
    // Cache the messenger before pushing the overlay — once the
    // menu's Overlay takes focus, a later ScaffoldMessenger.of(context)
    // call from inside our tap handlers may not resolve.
    _messenger = ScaffoldMessenger.maybeOf(context);
    _entry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _dismiss,
            ),
          ),
          Positioned(
            left: topLeft.dx,
            // Pop upward — composer sits near bottom of the screen.
            bottom: MediaQuery.of(context).size.height - topLeft.dy + 6,
            child: _AttachMenuPanel(
              onPickFiles: _pickFiles,
              onPickImages: _pickImages,
              onPaste: _pasteClipboard,
              onCapture: !kIsWeb ? _capture : null,
              onSlash: _openSlash,
              onAttachRecent: _attachRecent,
              onAttachWorkspaceFile: _attachWorkspaceFile,
            ),
          ),
        ],
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_entry!);
    setState(() => _open = true);
  }

  void _dismiss() {
    _entry?.remove();
    _entry = null;
    if (mounted) setState(() => _open = false);
  }

  @override
  void dispose() {
    _entry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final active = _hover || _open;
    return MouseRegion(
      onEnter: (_) {
        if (!widget.disabled && !_hover && mounted) {
          setState(() => _hover = true);
        }
      },
      onExit: (_) {
        if (_hover && mounted) setState(() => _hover = false);
      },
      child: GestureDetector(
        key: _buttonKey,
        behavior: HitTestBehavior.opaque,
        onTap: _open ? _dismiss : _showMenu,
        child: AnimatedContainer(
          duration: DsDuration.fast,
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active
                ? c.accentPrimary.withValues(alpha: 0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(DsRadius.xs),
            border: Border.all(
              color: active
                  ? c.accentPrimary.withValues(alpha: 0.4)
                  : Colors.transparent,
            ),
          ),
          child: Icon(
            Icons.attach_file_rounded,
            size: 16,
            color: widget.disabled
                ? c.textDim
                : (active ? c.accentPrimary : c.textMuted),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Menu panel — sections with 44px items
// ═══════════════════════════════════════════════════════════════════════════

enum _AttachView { main, recents, workspace }

class _AttachMenuPanel extends StatefulWidget {
  final VoidCallback onPickFiles;
  final VoidCallback onPickImages;
  final VoidCallback onPaste;
  final VoidCallback? onCapture;
  final VoidCallback onSlash;
  final void Function(RecentAttachment) onAttachRecent;
  final void Function(WorkspaceFile) onAttachWorkspaceFile;

  const _AttachMenuPanel({
    required this.onPickFiles,
    required this.onPickImages,
    required this.onPaste,
    required this.onCapture,
    required this.onSlash,
    required this.onAttachRecent,
    required this.onAttachWorkspaceFile,
  });

  @override
  State<_AttachMenuPanel> createState() => _AttachMenuPanelState();
}

class _AttachMenuPanelState extends State<_AttachMenuPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  _AttachView _view = _AttachView.main;
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
    )..forward();
    _searchCtrl.addListener(() {
      if (_searchCtrl.text != _query) {
        setState(() => _query = _searchCtrl.text);
      }
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _goto(_AttachView v) {
    setState(() {
      _view = v;
      _searchCtrl.clear();
      _query = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: Colors.transparent,
      child: AnimatedBuilder(
        animation: _anim,
        builder: (_, child) {
          final t = Curves.easeOutCubic.transform(_anim.value);
          return Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, (1 - t) * 6),
              child: Transform.scale(
                alignment: Alignment.bottomLeft,
                scale: 0.97 + (t * 0.03),
                child: child,
              ),
            ),
          );
        },
        child: Container(
          width: 320,
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(DsRadius.card),
            border: Border.all(color: c.border),
            boxShadow: [
              BoxShadow(
                color: c.shadow,
                blurRadius: 28,
                spreadRadius: -6,
                offset: const Offset(0, 12),
              ),
              BoxShadow(
                color: c.accentPrimary.withValues(alpha: 0.08),
                blurRadius: 24,
                spreadRadius: -8,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(DsRadius.card),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              alignment: Alignment.bottomLeft,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                switchInCurve: Curves.easeOut,
                transitionBuilder: (child, anim) {
                  final slide = Tween<Offset>(
                    begin: const Offset(0.04, 0),
                    end: Offset.zero,
                  ).animate(anim);
                  return SlideTransition(
                    position: slide,
                    child: FadeTransition(opacity: anim, child: child),
                  );
                },
                child: KeyedSubtree(
                  key: ValueKey(_view),
                  child: _buildView(c),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildView(AppColors c) {
    switch (_view) {
      case _AttachView.main:
        return _buildMain(c);
      case _AttachView.recents:
        return _buildSubView(
          c: c,
          title: 'Recent attachments',
          subtitle: 'Anything you have attached across sessions',
          child: _RecentsList(
            query: _query,
            onTap: widget.onAttachRecent,
          ),
        );
      case _AttachView.workspace:
        return _buildSubView(
          c: c,
          title: 'From workspace',
          subtitle: 'Files the agent is currently working on',
          child: _WorkspaceFilesList(
            query: _query,
            onTap: widget.onAttachWorkspaceFile,
          ),
        );
    }
  }

  Widget _buildMain(AppColors c) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionLabel(c, 'UPLOAD'),
        _MenuItem(
          icon: Icons.attach_file_rounded,
          accent: c.accentPrimary,
          title: 'Attach files',
          subtitle: 'Pick one or many from your computer',
          shortcut: null,
          onTap: widget.onPickFiles,
        ),
        _MenuItem(
          icon: Icons.image_rounded,
          accent: c.accentSecondary,
          title: 'Attach images',
          subtitle: 'Filtered to png · jpg · gif · webp · bmp',
          shortcut: null,
          onTap: widget.onPickImages,
        ),
        _divider(c),
        _sectionLabel(c, 'CLIPBOARD & CAPTURE'),
        _MenuItem(
          icon: Icons.content_paste_rounded,
          accent: c.green,
          title: 'Paste from clipboard',
          subtitle: 'Grab whatever image is on the clipboard',
          shortcut: _pasteShortcut(),
          onTap: widget.onPaste,
        ),
        if (widget.onCapture != null)
          _MenuItem(
            icon: Icons.crop_free_rounded,
            accent: c.orange,
            title: 'Take screenshot',
            subtitle: _captureSubtitle(),
            shortcut: null,
            onTap: widget.onCapture!,
          ),
        _divider(c),
        _sectionLabel(c, 'LIBRARY'),
        ListenableBuilder(
          listenable: RecentAttachmentsService(),
          builder: (_, _) => _MenuItem(
            icon: Icons.history_rounded,
            accent: c.purple,
            title: 'Recent attachments',
            subtitle: _recentsSubtitle(),
            trailing: Icons.chevron_right_rounded,
            shortcut: null,
            onTap: () => _goto(_AttachView.recents),
          ),
        ),
        ListenableBuilder(
          listenable: WorkspaceModule(),
          builder: (_, _) => _MenuItem(
            icon: Icons.folder_rounded,
            accent: c.cyan,
            title: 'From workspace',
            subtitle: _workspaceSubtitle(),
            trailing: Icons.chevron_right_rounded,
            shortcut: null,
            onTap: () => _goto(_AttachView.workspace),
          ),
        ),
        _divider(c),
        _sectionLabel(c, 'COMMAND'),
        _MenuItem(
          icon: Icons.terminal_rounded,
          accent: c.blue,
          title: 'Slash commands',
          subtitle: 'Insert / to trigger app commands',
          shortcut: '/',
          onTap: widget.onSlash,
        ),
        const SizedBox(height: 6),
      ],
    );
  }

  Widget _buildSubView({
    required AppColors c,
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 12, 8),
          child: Row(
            children: [
              _BackButton(onTap: () => _goto(_AttachView.main)),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: c.textBright,
                        letterSpacing: -0.1,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 10.5,
                        color: c.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: c.bg,
              borderRadius: BorderRadius.circular(DsRadius.xs),
              border: Border.all(color: c.border),
            ),
            child: Row(
              children: [
                Icon(Icons.search_rounded, size: 13, color: c.textDim),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    autofocus: true,
                    cursorColor: c.accentPrimary,
                    cursorWidth: 1.2,
                    style: GoogleFonts.inter(
                        fontSize: 12, color: c.textBright),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          vertical: 8),
                      border: InputBorder.none,
                      hintText: 'Filter by name…',
                      hintStyle: GoogleFonts.inter(
                          fontSize: 12, color: c.textDim),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: child,
        ),
        const SizedBox(height: 6),
      ],
    );
  }

  String _recentsSubtitle() {
    final n = RecentAttachmentsService().items.length;
    if (n == 0) return 'No recent attachments yet';
    return '$n recent ${n == 1 ? 'file' : 'files'}';
  }

  String _workspaceSubtitle() {
    final n = WorkspaceModule().files.length;
    if (n == 0) return 'No files open in workspace';
    return '$n ${n == 1 ? 'file' : 'files'} in workspace';
  }

  static String _pasteShortcut() {
    if (kIsWeb) return '⌘/Ctrl V';
    if (Platform.isMacOS) return '⌘ V';
    return 'Ctrl V';
  }

  static String _captureSubtitle() {
    if (kIsWeb) return 'Not available on web';
    if (Platform.isMacOS) return 'Opens the macOS selection marquee';
    if (Platform.isWindows) return 'Opens Snipping Tool overlay';
    if (Platform.isLinux) return 'Uses gnome-screenshot if installed';
    return 'Native OS capture';
  }

  Widget _sectionLabel(AppColors c, String label) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: c.textDim,
          ),
        ),
      );

  Widget _divider(AppColors c) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: Container(height: 1, color: c.border),
      );
}

// ═══════════════════════════════════════════════════════════════════════════
// Subview — Recents
// ═══════════════════════════════════════════════════════════════════════════

class _RecentsList extends StatelessWidget {
  final String query;
  final void Function(RecentAttachment) onTap;
  const _RecentsList({required this.query, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListenableBuilder(
      listenable: RecentAttachmentsService(),
      builder: (_, _) {
        final q = query.trim().toLowerCase();
        final all = RecentAttachmentsService().items;
        final items = q.isEmpty
            ? all
            : all
                .where((r) =>
                    r.name.toLowerCase().contains(q) ||
                    r.path.toLowerCase().contains(q))
                .toList();
        if (items.isEmpty) {
          return _EmptyHint(
            icon: all.isEmpty ? Icons.history_toggle_off_rounded
                : Icons.search_off_rounded,
            label: all.isEmpty
                ? 'No recent attachments yet'
                : 'No match for "$query"',
            colors: c,
          );
        }
        return ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          itemCount: items.length,
          itemBuilder: (_, i) => _RecentRow(
            attachment: items[i],
            onTap: () => onTap(items[i]),
          ),
        );
      },
    );
  }
}

class _RecentRow extends StatefulWidget {
  final RecentAttachment attachment;
  final VoidCallback onTap;
  const _RecentRow({required this.attachment, required this.onTap});

  @override
  State<_RecentRow> createState() => _RecentRowState();
}

class _RecentRowState extends State<_RecentRow> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final a = widget.attachment;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DsDuration.fast,
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          margin: const EdgeInsets.symmetric(vertical: 1),
          decoration: BoxDecoration(
            color: _h
                ? c.accentPrimary.withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(DsRadius.xs),
          ),
          child: Row(
            children: [
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: (a.isImage ? c.accentSecondary : c.textMuted)
                      .withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(DsRadius.xs - 2),
                ),
                child: Icon(
                  a.isImage
                      ? Icons.image_outlined
                      : iconForExtension(a.path),
                  size: 13,
                  color: a.isImage ? c.accentSecondary : c.textMuted,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      a.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _h ? c.textBright : c.text,
                      ),
                    ),
                    Text(
                      a.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.firaCode(
                        fontSize: 9.5,
                        color: c.textDim,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Text(
                a.ago,
                style: GoogleFonts.firaCode(
                  fontSize: 9.5,
                  color: c.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Subview — Workspace files (live from WorkspaceModule)
// ═══════════════════════════════════════════════════════════════════════════

class _WorkspaceFilesList extends StatelessWidget {
  final String query;
  final void Function(WorkspaceFile) onTap;
  const _WorkspaceFilesList({required this.query, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListenableBuilder(
      listenable: WorkspaceModule(),
      builder: (_, _) {
        final q = query.trim().toLowerCase();
        final all = WorkspaceModule().files.values.toList()
          ..sort((a, b) => a.path.toLowerCase()
              .compareTo(b.path.toLowerCase()));
        final filtered = q.isEmpty
            ? all
            : all
                .where((f) => f.path.toLowerCase().contains(q))
                .toList();
        if (filtered.isEmpty) {
          return _EmptyHint(
            icon: all.isEmpty
                ? Icons.folder_open_outlined
                : Icons.search_off_rounded,
            label: all.isEmpty
                ? 'No files in the workspace yet'
                : 'No match for "$query"',
            colors: c,
          );
        }
        return ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          itemCount: filtered.length,
          itemBuilder: (_, i) => _WorkspaceFileRow(
            file: filtered[i],
            onTap: () => onTap(filtered[i]),
          ),
        );
      },
    );
  }
}

class _WorkspaceFileRow extends StatefulWidget {
  final WorkspaceFile file;
  final VoidCallback onTap;
  const _WorkspaceFileRow({required this.file, required this.onTap});

  @override
  State<_WorkspaceFileRow> createState() => _WorkspaceFileRowState();
}

class _WorkspaceFileRowState extends State<_WorkspaceFileRow> {
  bool _h = false;

  String _basename(String p) {
    final parts = p.split(RegExp(r'[\\/]'));
    for (final part in parts.reversed) {
      if (part.isNotEmpty) return part;
    }
    return p;
  }

  String _parentDir(String p) {
    final normalised = p.replaceAll('\\', '/');
    final i = normalised.lastIndexOf('/');
    if (i <= 0) return '';
    return normalised.substring(0, i);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final f = widget.file;
    final name = _basename(f.path);
    final parent = _parentDir(f.path);
    final status = f.status.toLowerCase();
    final isAdded = status == 'added';
    final isModified = status == 'modified';
    final isDeleted = status == 'deleted';
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DsDuration.fast,
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          margin: const EdgeInsets.symmetric(vertical: 1),
          decoration: BoxDecoration(
            color: _h
                ? c.cyan.withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(DsRadius.xs),
          ),
          child: Row(
            children: [
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.cyan.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(DsRadius.xs - 2),
                ),
                child: Icon(
                  iconForExtension(f.path),
                  size: 13,
                  color: c.cyan,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: _h ? c.textBright : c.text,
                            ),
                          ),
                        ),
                        if (isAdded || isModified || isDeleted) ...[
                          const SizedBox(width: 6),
                          _StatusPill(
                            label: isAdded
                                ? 'A'
                                : (isModified ? 'M' : 'D'),
                            color: isAdded
                                ? c.green
                                : (isModified ? c.orange : c.red),
                          ),
                        ],
                      ],
                    ),
                    if (parent.isNotEmpty)
                      Text(
                        parent,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.firaCode(
                          fontSize: 9.5,
                          color: c.textDim,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              if (f.size > 0)
                Text(
                  formatFileSize(f.size),
                  style: GoogleFonts.firaCode(
                    fontSize: 9.5,
                    color: c.textMuted,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 14,
      height: 14,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: GoogleFonts.firaCode(
          fontSize: 8.5,
          fontWeight: FontWeight.w800,
          color: color,
          height: 1,
        ),
      ),
    );
  }
}

class _BackButton extends StatefulWidget {
  final VoidCallback onTap;
  const _BackButton({required this.onTap});

  @override
  State<_BackButton> createState() => _BackButtonState();
}

class _BackButtonState extends State<_BackButton> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DsDuration.fast,
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _h ? c.surfaceAlt : Colors.transparent,
            borderRadius: BorderRadius.circular(DsRadius.xs),
          ),
          child: Icon(
            Icons.arrow_back_rounded,
            size: 15,
            color: _h ? c.textBright : c.textMuted,
          ),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final IconData icon;
  final String label;
  final AppColors colors;
  const _EmptyHint({
    required this.icon,
    required this.label,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 26, color: colors.textDim),
          const SizedBox(height: 10),
          Text(
            label,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 12,
              color: colors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuItem extends StatefulWidget {
  final IconData icon;
  final Color accent;
  final String title;
  final String subtitle;
  final String? shortcut;
  final IconData? trailing;
  final VoidCallback onTap;

  const _MenuItem({
    required this.icon,
    required this.accent,
    required this.title,
    required this.subtitle,
    required this.shortcut,
    required this.onTap,
    this.trailing,
  });

  @override
  State<_MenuItem> createState() => _MenuItemState();
}

class _MenuItemState extends State<_MenuItem> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DsDuration.fast,
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: _h
                ? widget.accent.withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(DsRadius.xs),
          ),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: widget.accent.withValues(alpha: _h ? 0.2 : 0.12),
                  borderRadius: BorderRadius.circular(DsRadius.xs),
                ),
                child: Icon(widget.icon, size: 14, color: widget.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: _h ? c.textBright : c.text,
                        letterSpacing: -0.1,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      widget.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 10.5,
                        color: c.textMuted,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.shortcut != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(DsRadius.xs - 2),
                    border: Border.all(color: c.border),
                  ),
                  child: Text(
                    widget.shortcut!,
                    style: GoogleFonts.firaCode(
                      fontSize: 9.5,
                      color: c.textDim,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
              if (widget.trailing != null) ...[
                const SizedBox(width: 6),
                Icon(
                  widget.trailing,
                  size: 14,
                  color: _h ? widget.accent : c.textDim,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
