/// UI surfaces for the snippets library:
///
///   * `SnippetsPicker.show(context)`  — fuzzy picker that returns a
///     [Snippet]. The chat panel calls this on `/snippet`.
///   * `SnippetVariablesDialog.show()` — when the picked snippet has
///     `{{var}}` placeholders, asks the user to fill each one before
///     inserting. Returns the rendered text.
///   * `SnippetEditor.show()`          — create / edit / delete one
///     snippet. Hooked from the picker's "Manage" button.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../design/tokens.dart';
import '../../services/snippets_service.dart';
import '../../theme/app_theme.dart';

/// Inline variant of the snippets picker — rendered above the chat
/// composer like the Tools / Context / Tasks panels, so it stays
/// inside the chat zone regardless of the drawer / workspace layout.
///
/// Emits [onInsert] with the final rendered snippet text (after any
/// `{{var}}` filling). The caller is expected to close the panel
/// via [onClose] — we also call it ourselves right after a successful
/// insert so the user's next keystroke lands in the composer.
class SnippetsPanel extends StatefulWidget {
  final void Function(String rendered) onInsert;
  final VoidCallback onClose;

  const SnippetsPanel({
    super.key,
    required this.onInsert,
    required this.onClose,
  });

  @override
  State<SnippetsPanel> createState() => _SnippetsPanelState();
}

class _SnippetsPanelState extends State<SnippetsPanel> {
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  String _q = '';

  @override
  void initState() {
    super.initState();
    SnippetsService().load();
    _searchCtrl.addListener(() {
      if (_searchCtrl.text != _q) {
        setState(() => _q = _searchCtrl.text);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _pick(Snippet s) async {
    if (s.variables.isEmpty) {
      widget.onInsert(s.body);
      widget.onClose();
      return;
    }
    final values = await SnippetVariablesDialog.show(context, s);
    if (values == null) return;
    widget.onInsert(s.render(values));
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListenableBuilder(
      listenable: SnippetsService(),
      builder: (ctx, _) {
        final all = SnippetsService().items;
        final q = _q.trim().toLowerCase();
        final filtered = q.isEmpty
            ? all
            : all.where((s) {
                return s.name.toLowerCase().contains(q) ||
                    s.body.toLowerCase().contains(q) ||
                    (s.description?.toLowerCase().contains(q) ?? false);
              }).toList();
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(DsRadius.card),
            border: Border.all(color: c.border),
            boxShadow: [
              BoxShadow(
                color: c.shadow,
                blurRadius: 20,
                spreadRadius: -4,
                offset: const Offset(0, -4),
              ),
              BoxShadow(
                color: c.accentPrimary.withValues(alpha: 0.05),
                blurRadius: 30,
                spreadRadius: -10,
              ),
            ],
          ),
          // Content-driven height: empty library → tiny panel with
          // just the empty hint. A handful of snippets → panel grows
          // naturally. Beyond 340 px the list scrolls inside the
          // panel so the composer stays in view.
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SnippetsHeader(
                total: all.length,
                filteredCount: filtered.length,
                onClose: widget.onClose,
                onNew: () async {
                  final created = await SnippetEditor.show(context);
                  if (created != null && mounted) setState(() {});
                },
              ),
              _SnippetsSearchBar(
                controller: _searchCtrl,
                focusNode: _searchFocus,
              ),
              Container(height: 1, color: c.border),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 340),
                child: filtered.isEmpty
                    ? _SnippetsEmpty(
                        noSnippets: all.isEmpty,
                        query: _q,
                        colors: c,
                        onNew: () async {
                          final created = await SnippetEditor.show(context);
                          if (created != null && mounted) setState(() {});
                        },
                      )
                    : SingleChildScrollView(
                        padding:
                            const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final s in filtered)
                              _SnippetPanelRow(
                                snippet: s,
                                onSelect: () => _pick(s),
                                onEdit: () async {
                                  final edited =
                                      await SnippetEditor.show(
                                          context, s);
                                  if (edited != null && mounted) {
                                    setState(() {});
                                  }
                                },
                              ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SnippetsHeader extends StatelessWidget {
  final int total;
  final int filteredCount;
  final VoidCallback onClose;
  final VoidCallback onNew;
  const _SnippetsHeader({
    required this.total,
    required this.filteredCount,
    required this.onClose,
    required this.onNew,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 10),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  c.accentPrimary,
                  Color.lerp(c.accentPrimary, c.accentSecondary, 0.55) ??
                      c.accentPrimary,
                ],
              ),
              borderRadius: BorderRadius.circular(DsRadius.xs),
            ),
            child: Icon(Icons.bookmark_rounded, size: 14, color: c.onAccent),
          ),
          const SizedBox(width: 10),
          Text(
            'Snippets',
            style: GoogleFonts.inter(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: c.textBright,
              letterSpacing: -0.1,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: c.surfaceAlt,
              borderRadius: BorderRadius.circular(DsRadius.pill),
              border: Border.all(color: c.border),
            ),
            child: Text(
              '$filteredCount / $total',
              style: GoogleFonts.firaCode(
                fontSize: 10,
                color: c.textMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Spacer(),
          _SnippetsPillButton(
            icon: Icons.add_rounded,
            label: 'New',
            onTap: onNew,
          ),
          const SizedBox(width: 6),
          _SnippetsTinyBtn(
            icon: Icons.close_rounded,
            tooltip: 'Close',
            onTap: onClose,
          ),
        ],
      ),
    );
  }
}

class _SnippetsSearchBar extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  const _SnippetsSearchBar({
    required this.controller,
    required this.focusNode,
  });

  @override
  State<_SnippetsSearchBar> createState() => _SnippetsSearchBarState();
}

class _SnippetsSearchBarState extends State<_SnippetsSearchBar> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(() => setState(() {}));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final focused = widget.focusNode.hasFocus;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: AnimatedContainer(
        duration: DsDuration.fast,
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: c.bg,
          borderRadius: BorderRadius.circular(DsRadius.input),
          border: Border.all(
            color: focused
                ? c.accentPrimary.withValues(alpha: 0.5)
                : c.border,
            width: focused ? 1.2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.search_rounded,
              size: 14,
              color: focused ? c.accentPrimary : c.textDim,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: widget.focusNode,
                cursorColor: c.accentPrimary,
                cursorWidth: 1.2,
                style:
                    GoogleFonts.inter(fontSize: 12.5, color: c.textBright),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  border: InputBorder.none,
                  hintText: 'Search snippets…',
                  hintStyle:
                      GoogleFonts.inter(fontSize: 12.5, color: c.textDim),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SnippetPanelRow extends StatefulWidget {
  final Snippet snippet;
  final VoidCallback onSelect;
  final VoidCallback onEdit;
  const _SnippetPanelRow({
    required this.snippet,
    required this.onSelect,
    required this.onEdit,
  });

  @override
  State<_SnippetPanelRow> createState() => _SnippetPanelRowState();
}

class _SnippetPanelRowState extends State<_SnippetPanelRow> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = widget.snippet;
    final preview = s.body.length > 80 ? '${s.body.substring(0, 80)}…' : s.body;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelect,
        child: AnimatedContainer(
          duration: DsDuration.fast,
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _h
                ? c.accentPrimary.withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(DsRadius.xs),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.accentPrimary.withValues(alpha: _h ? 0.18 : 0.1),
                  borderRadius: BorderRadius.circular(DsRadius.xs),
                ),
                child: Icon(
                  Icons.bookmark_outlined,
                  size: 13,
                  color: c.accentPrimary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: c.textBright,
                        letterSpacing: -0.1,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      preview.replaceAll('\n', ' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.firaCode(
                        fontSize: 10.5,
                        color: c.textMuted,
                        height: 1.35,
                      ),
                    ),
                    if (s.variables.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final v in s.variables)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: c.accentSecondary
                                    .withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(3),
                                border: Border.all(
                                  color: c.accentSecondary
                                      .withValues(alpha: 0.3),
                                ),
                              ),
                              child: Text(
                                '{{$v}}',
                                style: GoogleFonts.firaCode(
                                  fontSize: 9,
                                  color: c.accentSecondary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 6),
              _SnippetsTinyBtn(
                icon: Icons.edit_outlined,
                tooltip: 'Edit',
                onTap: widget.onEdit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SnippetsEmpty extends StatelessWidget {
  final bool noSnippets;
  final String query;
  final AppColors colors;
  final VoidCallback onNew;
  const _SnippetsEmpty({
    required this.noSnippets,
    required this.query,
    required this.colors,
    required this.onNew,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.accentPrimary.withValues(alpha: 0.08),
              shape: BoxShape.circle,
              border: Border.all(
                color: colors.accentPrimary.withValues(alpha: 0.25),
              ),
            ),
            child: Icon(
              noSnippets
                  ? Icons.bookmark_border_rounded
                  : Icons.search_off_rounded,
              size: 20,
              color: colors.accentPrimary,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            noSnippets
                ? 'No snippets yet'
                : 'No snippet matches "$query"',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: colors.textBright,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            noSnippets
                ? 'Save a message or prompt as a reusable snippet.'
                : 'Try a shorter search term.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 11.5,
              color: colors.textMuted,
            ),
          ),
          if (noSnippets) ...[
            const SizedBox(height: 12),
            _SnippetsPillButton(
              icon: Icons.add_rounded,
              label: 'Create a snippet',
              onTap: onNew,
            ),
          ],
        ],
      ),
    );
  }
}

class _SnippetsPillButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _SnippetsPillButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  State<_SnippetsPillButton> createState() => _SnippetsPillButtonState();
}

class _SnippetsPillButtonState extends State<_SnippetsPillButton> {
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
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: _h
                ? c.accentPrimary.withValues(alpha: 0.16)
                : c.accentPrimary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(DsRadius.input),
            border: Border.all(
              color: c.accentPrimary.withValues(alpha: _h ? 0.45 : 0.3),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 12, color: c.accentPrimary),
              const SizedBox(width: 5),
              Text(
                widget.label,
                style: GoogleFonts.inter(
                  fontSize: 11.5,
                  color: c.accentPrimary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SnippetsTinyBtn extends StatefulWidget {
  final IconData icon;
  final String? tooltip;
  final VoidCallback onTap;
  const _SnippetsTinyBtn({
    required this.icon,
    this.tooltip,
    required this.onTap,
  });

  @override
  State<_SnippetsTinyBtn> createState() => _SnippetsTinyBtnState();
}

class _SnippetsTinyBtnState extends State<_SnippetsTinyBtn> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final btn = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DsDuration.fast,
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _h ? c.surfaceAlt : Colors.transparent,
            borderRadius: BorderRadius.circular(DsRadius.xs),
          ),
          child: Icon(
            widget.icon,
            size: 13,
            color: _h ? c.textBright : c.textMuted,
          ),
        ),
      ),
    );
    return widget.tooltip != null
        ? Tooltip(message: widget.tooltip!, child: btn)
        : btn;
  }
}

class SnippetsPicker {
  /// Show the picker and return the rendered text the chat input
  /// should receive (or null if cancelled).
  static Future<String?> pick(BuildContext context) async {
    await SnippetsService().load();
    if (!context.mounted) return null;
    final selected = await showDialog<Snippet>(
      context: context,
      builder: (_) => const _PickerDialog(),
    );
    if (selected == null || !context.mounted) return null;
    if (selected.variables.isEmpty) return selected.body;
    final values = await SnippetVariablesDialog.show(context, selected);
    if (values == null) return null;
    return selected.render(values);
  }
}

class _PickerDialog extends StatefulWidget {
  const _PickerDialog();
  @override
  State<_PickerDialog> createState() => _PickerDialogState();
}

class _PickerDialogState extends State<_PickerDialog> {
  final _filterCtrl = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _filterCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final svc = SnippetsService();
    final all = svc.items;
    final filtered = _q.isEmpty
        ? all
        : all.where((s) {
            final q = _q.toLowerCase();
            return s.name.toLowerCase().contains(q) ||
                s.body.toLowerCase().contains(q) ||
                (s.description?.toLowerCase().contains(q) ?? false);
          }).toList();
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.only(top: 80, left: 40, right: 40),
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      child: Builder(builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        final w = size.width < 600 ? size.width - 32 : 560.0;
        final h = size.height < 520 ? size.height - 96 : 480.0;
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: w, maxHeight: h),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Search header
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              child: Row(
                children: [
                  Icon(Icons.bookmark_border_rounded,
                      size: 16, color: c.textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _filterCtrl,
                      autofocus: true,
                      onChanged: (v) => setState(() => _q = v.trim()),
                      style: GoogleFonts.inter(fontSize: 13, color: c.text),
                      decoration: InputDecoration(
                        hintText: 'Search snippets…',
                        hintStyle: GoogleFonts.inter(
                            fontSize: 13, color: c.textMuted),
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      final created = await SnippetEditor.show(context);
                      if (created != null) setState(() {});
                    },
                    icon: Icon(Icons.add_rounded, size: 14, color: c.blue),
                    label: Text('New',
                        style:
                            GoogleFonts.inter(fontSize: 11.5, color: c.blue)),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      minimumSize: const Size(0, 28),
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: c.border),
            // List
            Flexible(
              child: filtered.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(40),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.bookmark_border_rounded,
                                size: 32, color: c.textDim),
                            const SizedBox(height: 10),
                            Text(
                              all.isEmpty
                                  ? 'No snippets yet — click New to create one'
                                  : 'No match',
                              style: GoogleFonts.inter(
                                  fontSize: 12, color: c.textMuted),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      shrinkWrap: true,
                      itemCount: filtered.length,
                      itemBuilder: (_, i) => _SnippetRow(
                        snippet: filtered[i],
                        onSelect: () =>
                            Navigator.of(context).pop(filtered[i]),
                        onEdit: () async {
                          final edited =
                              await SnippetEditor.show(context, filtered[i]);
                          if (edited != null) setState(() {});
                        },
                      ),
                    ),
            ),
          ],
        ),
        );
      }),
    );
  }
}

class _SnippetRow extends StatefulWidget {
  final Snippet snippet;
  final VoidCallback onSelect;
  final VoidCallback onEdit;
  const _SnippetRow({
    required this.snippet,
    required this.onSelect,
    required this.onEdit,
  });
  @override
  State<_SnippetRow> createState() => _SnippetRowState();
}

class _SnippetRowState extends State<_SnippetRow> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = widget.snippet;
    final preview = s.body.length > 80 ? '${s.body.substring(0, 80)}…' : s.body;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onSelect,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          color: _h ? c.surfaceAlt : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.blue.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: c.blue.withValues(alpha: 0.3)),
                ),
                child:
                    Icon(Icons.bookmark_outlined, size: 14, color: c.blue),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.name,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.textBright,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      preview.replaceAll('\n', ' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.firaCode(
                          fontSize: 10.5, color: c.textMuted),
                    ),
                    if (s.variables.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Wrap(
                        spacing: 4,
                        children: [
                          for (final v in s.variables)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: c.purple.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Text(
                                '{{$v}}',
                                style: GoogleFonts.firaCode(
                                  fontSize: 9,
                                  color: c.purple,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Edit',
                icon: Icon(Icons.edit_outlined, size: 14, color: c.textMuted),
                onPressed: widget.onEdit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SnippetVariablesDialog {
  static Future<Map<String, String>?> show(
      BuildContext context, Snippet snippet) {
    return showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _VariablesDialog(snippet: snippet),
    );
  }
}

class _VariablesDialog extends StatefulWidget {
  final Snippet snippet;
  const _VariablesDialog({required this.snippet});
  @override
  State<_VariablesDialog> createState() => _VariablesDialogState();
}

class _VariablesDialogState extends State<_VariablesDialog> {
  late final Map<String, TextEditingController> _ctrls = {
    for (final v in widget.snippet.variables) v: TextEditingController(),
  };

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AlertDialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      title: Text(
        widget.snippet.name,
        style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: c.textBright),
      ),
      content: SizedBox(
        width: MediaQuery.sizeOf(context).width < 460
            ? MediaQuery.sizeOf(context).width - 48
            : 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Fill the variables before inserting:',
              style: GoogleFonts.inter(
                  fontSize: 11.5, color: c.textMuted, height: 1.5),
            ),
            const SizedBox(height: 14),
            for (final v in widget.snippet.variables) ...[
              Text('{{$v}}',
                  style: GoogleFonts.firaCode(
                      fontSize: 11,
                      color: c.purple,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              TextField(
                controller: _ctrls[v],
                autofocus: widget.snippet.variables.first == v,
                style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
                maxLines: null,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: c.bg,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(color: c.border)),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel',
              style:
                  GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(
            context,
            {for (final e in _ctrls.entries) e.key: e.value.text},
          ),
          style: ElevatedButton.styleFrom(
              backgroundColor: c.blue,
              foregroundColor: Colors.white,
              elevation: 0),
          child: Text('Insert',
              style: GoogleFonts.inter(
                  fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

class SnippetEditor {
  /// Open the editor. Returns the saved snippet, or null on cancel.
  static Future<Snippet?> show(BuildContext context, [Snippet? existing]) {
    return showDialog<Snippet>(
      context: context,
      builder: (_) => _EditorDialog(existing: existing),
    );
  }
}

class _EditorDialog extends StatefulWidget {
  final Snippet? existing;
  const _EditorDialog({this.existing});
  @override
  State<_EditorDialog> createState() => _EditorDialogState();
}

class _EditorDialogState extends State<_EditorDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _body = TextEditingController(text: widget.existing?.body ?? '');
  late final _desc =
      TextEditingController(text: widget.existing?.description ?? '');

  @override
  void dispose() {
    _name.dispose();
    _body.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final s = Snippet(
      id: widget.existing?.id ?? SnippetsService.newId(),
      name: _name.text.trim(),
      body: _body.text,
      description: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
    );
    await SnippetsService().upsert(s);
    if (mounted) Navigator.pop(context, s);
  }

  Future<void> _delete() async {
    if (widget.existing == null) return;
    await SnippetsService().delete(widget.existing!.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isNew = widget.existing == null;
    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.bookmark_outlined, size: 16, color: c.text),
                  const SizedBox(width: 8),
                  Text(isNew ? 'New snippet' : 'Edit snippet',
                      style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: c.textBright)),
                  const Spacer(),
                  IconButton(
                    iconSize: 16,
                    icon: Icon(Icons.close_rounded, color: c.textMuted),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _label(c, 'Name'),
              const SizedBox(height: 4),
              TextField(
                controller: _name,
                autofocus: isNew,
                style: GoogleFonts.inter(fontSize: 13, color: c.text),
                decoration: _decoration(c, 'Code review'),
              ),
              const SizedBox(height: 12),
              _label(c, 'Description (optional)'),
              const SizedBox(height: 4),
              TextField(
                controller: _desc,
                style: GoogleFonts.inter(fontSize: 12, color: c.text),
                decoration: _decoration(
                    c, 'When to use this snippet'),
              ),
              const SizedBox(height: 12),
              _label(c, 'Body · use {{variable}} for placeholders'),
              const SizedBox(height: 4),
              TextField(
                controller: _body,
                minLines: 6,
                maxLines: 14,
                style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
                decoration: _decoration(
                    c, 'Review the following {{language}} code…'),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  if (!isNew)
                    TextButton.icon(
                      onPressed: _delete,
                      icon: Icon(Icons.delete_outline_rounded,
                          size: 14, color: c.red),
                      label: Text('Delete',
                          style:
                              GoogleFonts.inter(fontSize: 12, color: c.red)),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('Cancel',
                        style: GoogleFonts.inter(
                            fontSize: 12, color: c.textMuted)),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton(
                    onPressed: _save,
                    style: ElevatedButton.styleFrom(
                        backgroundColor: c.blue,
                        foregroundColor: Colors.white,
                        elevation: 0),
                    child: Text(isNew ? 'Create' : 'Save',
                        style: GoogleFonts.inter(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(AppColors c, String text) => Text(
        text,
        style: GoogleFonts.inter(
            fontSize: 11, color: c.textBright, fontWeight: FontWeight.w600),
      );

  InputDecoration _decoration(AppColors c, String hint) => InputDecoration(
        isDense: true,
        filled: true,
        fillColor: c.bg,
        hintText: hint,
        hintStyle: GoogleFonts.inter(fontSize: 12, color: c.textDim),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: c.border)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: c.border)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: c.blue)),
      );
}
