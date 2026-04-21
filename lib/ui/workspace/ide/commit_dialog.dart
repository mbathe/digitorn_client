/// Commit dialog — ships approved workspace files through the daemon
/// via `POST /workspace/commit`.
///
/// UI:
///   * Commit message (required, autofocus)
///   * List of approved files (checkboxes — all selected by default)
///   * Push to remote toggle (off by default)
///   * Commit button — calls [FileActionsService.commit] and surfaces
///     the daemon's error message (e.g. "workspace is not a git repo")
///     when present.
///
/// Scout-verified contract — 33/33 PASS on the full validation scout.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/api_client.dart';
import '../../../services/file_actions_service.dart';
import '../../../services/workspace_module.dart';
import '../../../theme/app_theme.dart';
import '../../chat/chat_bubbles.dart' show showToast;

Future<void> showCommitDialog(BuildContext context) async {
  final approved = WorkspaceModule()
      .files
      .values
      .where((f) => f.isApproved)
      .map((f) => f.path)
      .toList()
    ..sort();
  if (approved.isEmpty) {
    showToast(context, 'No approved files to commit.');
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (_) => _CommitDialog(initialFiles: approved),
  );
}

class _CommitDialog extends StatefulWidget {
  final List<String> initialFiles;
  const _CommitDialog({required this.initialFiles});

  @override
  State<_CommitDialog> createState() => _CommitDialogState();
}

class _CommitDialogState extends State<_CommitDialog> {
  final TextEditingController _message = TextEditingController();
  late final Set<String> _selected;
  bool _push = false;
  bool _busy = false;
  String? _error;
  CommitOutcome? _lastOutcome;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialFiles.toSet();
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_message.text.trim().isEmpty) {
      setState(() => _error = 'Commit message cannot be empty.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final outcome = await FileActionsService().commit(
      message: _message.text.trim(),
      files: _selected.toList()..sort(),
      push: _push,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _lastOutcome = outcome;
      _error = outcome == null
          ? 'Commit request failed (transport).'
          : (outcome.ok ? null : outcome.error);
    });
    if (outcome?.ok == true) {
      final sha = outcome!.commitSha ?? '';
      final short = sha.length >= 7 ? sha.substring(0, 7) : sha;
      showToast(
        context,
        'Committed $short · ${outcome.filesCommitted.length} file(s)'
        '${outcome.pushed ? ' · pushed' : ''}',
      );
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: c.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.commit_rounded,
                      size: 16, color: c.accentPrimary),
                  const SizedBox(width: 8),
                  Text(
                    'Commit session',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: c.text,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    iconSize: 14,
                    padding: EdgeInsets.zero,
                    onPressed: _busy
                        ? null
                        : () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close_rounded, color: c.textDim),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _message,
                autofocus: true,
                maxLines: 3,
                minLines: 2,
                decoration: InputDecoration(
                  hintText: 'feat: add …',
                  hintStyle: GoogleFonts.firaCode(
                      fontSize: 12, color: c.textDim),
                  filled: true,
                  fillColor: c.bg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: c.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: c.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: c.accentPrimary),
                  ),
                ),
                style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
              ),
              const SizedBox(height: 12),
              Text(
                'Files (${_selected.length}/${widget.initialFiles.length})',
                style: GoogleFonts.inter(
                    fontSize: 11,
                    color: c.textMuted,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Container(
                constraints: const BoxConstraints(maxHeight: 180),
                decoration: BoxDecoration(
                  color: c.bg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: c.border),
                ),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final path in widget.initialFiles)
                      InkWell(
                        onTap: () => setState(() {
                          if (_selected.contains(path)) {
                            _selected.remove(path);
                          } else {
                            _selected.add(path);
                          }
                        }),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 18,
                                height: 18,
                                child: Checkbox(
                                  value: _selected.contains(path),
                                  onChanged: (v) => setState(() {
                                    if (v == true) {
                                      _selected.add(path);
                                    } else {
                                      _selected.remove(path);
                                    }
                                  }),
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  path,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.firaCode(
                                      fontSize: 11, color: c.text),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: Checkbox(
                      value: _push,
                      onChanged: (v) =>
                          setState(() => _push = v == true),
                      materialTapTargetSize:
                          MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Push to remote',
                    style: GoogleFonts.inter(
                        fontSize: 11.5, color: c.text),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: c.red.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                    border:
                        Border.all(color: c.red.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    _error!,
                    style: GoogleFonts.firaCode(
                        fontSize: 10.5, color: c.red),
                  ),
                ),
              ],
              if (_lastOutcome?.ok == true &&
                  (_lastOutcome?.commitStdout?.isNotEmpty ?? false)) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: c.bg,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _lastOutcome!.commitStdout ?? '',
                    style: GoogleFonts.firaCode(
                        fontSize: 10, color: c.textDim),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed:
                        _busy || _selected.isEmpty ? null : _submit,
                    icon: _busy
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                                strokeWidth: 2))
                        : const Icon(Icons.check_rounded, size: 14),
                    label: Text(_busy ? 'Committing…' : 'Commit'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
