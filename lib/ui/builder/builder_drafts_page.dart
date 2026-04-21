/// Minimal App Builder drafts dashboard. Lists every in-progress
/// app the user is assembling, with create / rename / delete wired
/// to the daemon's `/api/builder/drafts` routes. The full builder
/// editor lives in a separate surface — this page is the recovery
/// point that lets the user pick one back up.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/builder_drafts_service.dart';
import '../../theme/app_theme.dart';
import '../common/themed_dialogs.dart';

class BuilderDraftsPage extends StatefulWidget {
  const BuilderDraftsPage({super.key});

  @override
  State<BuilderDraftsPage> createState() => _BuilderDraftsPageState();
}

class _BuilderDraftsPageState extends State<BuilderDraftsPage> {
  final _svc = BuilderDraftsService();

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChange);
    _svc.refresh();
  }

  @override
  void dispose() {
    _svc.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.surface,
        elevation: 0,
        foregroundColor: c.text,
        title: Text('App Builder · drafts',
            style: GoogleFonts.inter(
                fontSize: 14,
                color: c.textBright,
                fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh_rounded, size: 18, color: c.textMuted),
            onPressed: _svc.loading ? null : () => _svc.refresh(),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: Icon(Icons.add_rounded, size: 20, color: c.blue),
            tooltip: 'New draft',
            onPressed: _createDraft,
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: _svc.loading && _svc.drafts.isEmpty
          ? Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: c.textMuted),
              ),
            )
          : _svc.error != null && _svc.drafts.isEmpty
              ? _buildError(c)
              : _svc.drafts.isEmpty
                  ? _buildEmpty(c)
                  : _buildList(c),
    );
  }

  Widget _buildEmpty(AppColors c) => Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.architecture_outlined, size: 48, color: c.blue),
              const SizedBox(height: 14),
              Text('No drafts yet',
                  style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: c.textBright)),
              const SizedBox(height: 6),
              Text(
                'Start a new draft to bootstrap an app. Every save syncs to the daemon so you can continue on another device.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                    fontSize: 12, color: c.textMuted, height: 1.5),
              ),
              const SizedBox(height: 18),
              ElevatedButton.icon(
                onPressed: _createDraft,
                icon: const Icon(Icons.add_rounded, size: 14),
                label: Text('New draft',
                    style: GoogleFonts.inter(fontSize: 12)),
              ),
            ],
          ),
        ),
      );

  Widget _buildError(AppColors c) => Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 36, color: c.red),
              const SizedBox(height: 12),
              Text(_svc.error!,
                  style:
                      GoogleFonts.firaCode(fontSize: 11, color: c.textMuted)),
              const SizedBox(height: 14),
              ElevatedButton(
                onPressed: () => _svc.refresh(),
                child: Text('Retry', style: GoogleFonts.inter(fontSize: 12)),
              ),
            ],
          ),
        ),
      );

  Widget _buildList(AppColors c) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(40, 28, 40, 60),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('App Builder drafts',
                  style: GoogleFonts.inter(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: c.textBright,
                  )),
              const SizedBox(height: 5),
              Text(
                '${_svc.drafts.length} draft${_svc.drafts.length == 1 ? '' : 's'} in progress. Newest first.',
                style: GoogleFonts.inter(
                    fontSize: 13.5, color: c.textMuted, height: 1.5),
              ),
              const SizedBox(height: 22),
              Container(
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: c.border),
                ),
                child: Column(
                  children: [
                    for (var i = 0; i < _svc.drafts.length; i++) ...[
                      _DraftRow(
                        draft: _svc.drafts[i],
                        onRename: () => _rename(_svc.drafts[i]),
                        onDelete: () => _confirmDelete(_svc.drafts[i]),
                      ),
                      if (i < _svc.drafts.length - 1)
                        Divider(height: 1, color: c.border),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _createDraft() async {
    final name = await _promptText(
      context,
      title: 'New draft',
      hint: 'e.g. Daily standup writer',
    );
    if (name == null || name.isEmpty) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final draft = await _svc.create(name: name);
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(draft != null ? 'Draft created' : 'Create failed',
            style: GoogleFonts.inter(fontSize: 12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _rename(BuilderDraft draft) async {
    final value = await _promptText(
      context,
      title: 'Rename draft',
      hint: draft.name,
      initial: draft.name,
    );
    if (value == null || value.isEmpty) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await _svc.update(draft.id, name: value);
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(ok ? 'Renamed' : 'Rename failed',
            style: GoogleFonts.inter(fontSize: 12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _confirmDelete(BuilderDraft draft) async {
    final ok = await showThemedConfirmDialog(
      context,
      title: 'Delete draft?',
      body: '${draft.name} will be permanently removed.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (ok != true) return;
    await _svc.delete(draft.id);
  }

  Future<String?> _promptText(
    BuildContext context, {
    required String title,
    required String hint,
    String initial = '',
  }) {
    return showThemedPromptDialog(
      context,
      title: title,
      hint: hint,
      initial: initial,
    );
  }
}

class _DraftRow extends StatelessWidget {
  final BuilderDraft draft;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  const _DraftRow({
    required this.draft,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.blue.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.blue.withValues(alpha: 0.35)),
            ),
            child: Icon(Icons.architecture_outlined, size: 16, color: c.blue),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(draft.name,
                        style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: c.textBright)),
                    if (draft.mode != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: c.surfaceAlt,
                          borderRadius: BorderRadius.circular(3),
                          border: Border.all(color: c.border),
                        ),
                        child: Text(draft.mode!.toUpperCase(),
                            style: GoogleFonts.firaCode(
                                fontSize: 8.5,
                                color: c.textMuted,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.4)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  draft.description ?? 'No description',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                      fontSize: 11.5, color: c.textMuted, height: 1.4),
                ),
                if (draft.updatedAt != null) ...[
                  const SizedBox(height: 3),
                  Text('Updated ${_ago(draft.updatedAt!)}',
                      style: GoogleFonts.firaCode(
                          fontSize: 10, color: c.textDim)),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: 'Rename',
            iconSize: 14,
            icon: Icon(Icons.edit_outlined, color: c.textMuted),
            onPressed: onRename,
          ),
          IconButton(
            tooltip: 'Delete',
            iconSize: 14,
            icon: Icon(Icons.delete_outline_rounded, color: c.red),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}
