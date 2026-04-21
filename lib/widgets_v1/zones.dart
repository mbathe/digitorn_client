/// Digitorn Widgets v1 — zone shells.
///
/// Thin chrome around a [WidgetHost] for each of the four display
/// zones defined in the spec:
///
///   * Z1 [WidgetBubbleZ1]       — inline chat bubble
///   * Z2 [ChatSidePanelZ2]      — companion panel left of chat
///   * Z3 [WorkspaceWidgetsTabZ3] — "Widgets" tab in WorkspacePanel
///   * Z4 [WidgetModalZ4]        — centered modal overlay
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_theme.dart';
import 'dispatcher.dart' as disp;
import 'host.dart';
import 'models.dart';
import 'primitives/layout.dart' show widgetIconByName;

// ─── Z1 · inline chat bubble ─────────────────────────────────────

class WidgetBubbleZ1 extends StatelessWidget {
  final String appId;
  final String widgetId;
  final WidgetPaneSpec pane;
  final Map<String, dynamic> ctx;
  final disp.ActionHooks hooks;
  const WidgetBubbleZ1({
    super.key,
    required this.appId,
    required this.widgetId,
    required this.pane,
    this.ctx = const {},
    required this.hooks,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      constraints: const BoxConstraints(maxWidth: 640),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      padding: const EdgeInsets.all(12),
      child: WidgetHost(
        appId: appId,
        paneKey: 'inline.$widgetId',
        pane: pane,
        ctx: ctx,
        hooks: hooks,
        subscribeToEvents: true,
        widgetId: widgetId,
      ),
    );
  }
}

// ─── Z2 · chat companion panel ───────────────────────────────────

class ChatSidePanelZ2 extends StatefulWidget {
  final String appId;
  final WidgetPaneSpec pane;
  final disp.ActionHooks hooks;
  final Map<String, dynamic> session;
  final Map<String, dynamic> app;
  const ChatSidePanelZ2({
    super.key,
    required this.appId,
    required this.pane,
    required this.hooks,
    this.session = const {},
    this.app = const {},
  });

  @override
  State<ChatSidePanelZ2> createState() => _ChatSidePanelZ2State();
}

class _ChatSidePanelZ2State extends State<ChatSidePanelZ2> {
  bool _open = true;

  @override
  void initState() {
    super.initState();
    _open = widget.pane.defaultOpen;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final width = widget.pane.width ?? 300;
    if (!_open) {
      return _collapsed(c);
    }
    return SizedBox(
      width: width,
      child: Container(
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(right: BorderSide(color: c.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(c),
            Container(height: 1, color: c.border),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: WidgetHost(
                  appId: widget.appId,
                  paneKey: 'chat_side',
                  pane: widget.pane,
                  session: widget.session,
                  app: widget.app,
                  hooks: widget.hooks,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _collapsed(AppColors c) {
    return SizedBox(
      width: 36,
      child: Container(
        color: c.surface,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Tooltip(
              message: widget.pane.title ?? 'Widgets',
              child: IconButton(
                icon: Icon(
                  widget.pane.icon != null
                      ? widgetIconByName(widget.pane.icon!)
                      : Icons.chevron_right_rounded,
                  size: 16,
                  color: c.textMuted,
                ),
                onPressed: () => setState(() => _open = true),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(AppColors c) {
    return Container(
      height: 44,
      padding: const EdgeInsets.fromLTRB(14, 0, 6, 0),
      child: Row(
        children: [
          if (widget.pane.icon != null) ...[
            Icon(widgetIconByName(widget.pane.icon!),
                size: 14, color: c.blue),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              widget.pane.title ?? 'Widgets',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: c.textBright,
              ),
            ),
          ),
          if (widget.pane.collapsible)
            IconButton(
              icon: Icon(Icons.chevron_left_rounded,
                  size: 15, color: c.textMuted),
              onPressed: () => setState(() => _open = false),
              tooltip: 'Collapse',
            ),
        ],
      ),
    );
  }
}

// ─── Z3 · workspace tab container ────────────────────────────────

class WorkspaceWidgetsTabZ3 extends StatefulWidget {
  final String appId;
  final List<WidgetPaneSpec> tabs;
  final disp.ActionHooks hooks;
  const WorkspaceWidgetsTabZ3({
    super.key,
    required this.appId,
    required this.tabs,
    required this.hooks,
  });

  @override
  State<WorkspaceWidgetsTabZ3> createState() => _WorkspaceWidgetsTabZ3State();
}

class _WorkspaceWidgetsTabZ3State extends State<WorkspaceWidgetsTabZ3> {
  int _active = 0;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (widget.tabs.isEmpty) {
      return Container(
        color: c.bg,
        alignment: Alignment.center,
        child: Text('No widgets declared.',
            style: GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
      );
    }
    final tab = widget.tabs[_active.clamp(0, widget.tabs.length - 1)];
    return Container(
      color: c.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.tabs.length > 1) _subTabs(c),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: WidgetHost(
                appId: widget.appId,
                paneKey: 'workspace.${tab.id ?? _active}',
                pane: tab,
                hooks: widget.hooks,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _subTabs(AppColors c) {
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < widget.tabs.length; i++)
              _subTabChip(c, widget.tabs[i], i),
          ],
        ),
      ),
    );
  }

  Widget _subTabChip(AppColors c, WidgetPaneSpec tab, int i) {
    final selected = _active == i;
    return Padding(
      padding: const EdgeInsets.only(right: 6, top: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => setState(() => _active = i),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? c.blue.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? c.blue.withValues(alpha: 0.4) : c.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (tab.icon != null) ...[
                Icon(widgetIconByName(tab.icon!),
                    size: 12, color: selected ? c.blue : c.textMuted),
                const SizedBox(width: 6),
              ],
              Text(
                tab.title ?? tab.id ?? '',
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

// ─── Z4 · modal overlay ──────────────────────────────────────────

Future<void> showWidgetModalZ4(
  BuildContext context, {
  required String appId,
  required String modalName,
  required WidgetPaneSpec pane,
  required disp.ActionHooks hooks,
  Map<String, dynamic> ctx = const {},
  Map<String, dynamic> session = const {},
  Map<String, dynamic> app = const {},
}) {
  final double width = pane.width ?? 560;
  return showDialog(
    context: context,
    barrierDismissible: pane.dismissible,
    builder: (dialogCtx) {
      final c = dialogCtx.colors;
      // Patch hooks so `close` inside the modal tree pops this route.
      final wiredHooks = disp.ActionHooks(
        chatSender: hooks.chatSender,
        toolRunner: hooks.toolRunner,
        openModal: hooks.openModal,
        openWorkspace: hooks.openWorkspace,
        navigate: hooks.navigate,
        closeHost: () => Navigator.of(dialogCtx).pop(),
      );
      return Dialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: c.border),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: width == double.infinity ? 1000 : width,
            maxHeight: MediaQuery.of(dialogCtx).size.height * 0.85,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if ((pane.title ?? '').isNotEmpty)
                _modalHeader(c, pane, dialogCtx),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: WidgetHost(
                    appId: appId,
                    paneKey: 'modal.$modalName',
                    pane: pane,
                    ctx: ctx,
                    session: session,
                    app: app,
                    hooks: wiredHooks,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

Widget _modalHeader(AppColors c, WidgetPaneSpec pane, BuildContext ctx) {
  return Container(
    padding: const EdgeInsets.fromLTRB(18, 14, 8, 14),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: c.border)),
    ),
    child: Row(
      children: [
        if (pane.icon != null) ...[
          Icon(widgetIconByName(pane.icon!), size: 16, color: c.blue),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Text(
            pane.title ?? '',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: c.textBright,
            ),
          ),
        ),
        IconButton(
          icon: Icon(Icons.close_rounded, size: 16, color: c.textMuted),
          onPressed: () => Navigator.of(ctx).pop(),
          tooltip: 'Close',
        ),
      ],
    ),
  );
}
