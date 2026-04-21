import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../design/tokens.dart';
import '../../theme/app_theme.dart';

/// Open a workspace picker appropriate for the runtime:
///
///   * **desktop** — native folder picker (`file_selector`).
///   * **web** — themed dialog with an input field and the last
///     recently-used paths for one-tap reuse.
///
/// Returns the absolute path, or `null` when the user cancels.
/// A successful pick is automatically remembered via
/// [saveRecentWorkspace] — callers only need to act on the return
/// value.
Future<String?> pickWorkspace(BuildContext context) async {
  if (!kIsWeb) {
    final picked =
        await getDirectoryPath(confirmButtonText: 'Select Workspace');
    if (picked != null && picked.isNotEmpty) {
      await saveRecentWorkspace(picked);
    }
    return picked;
  }
  final prefs = await SharedPreferences.getInstance();
  final recents = prefs.getStringList(_kRecentWorkspaces) ?? <String>[];
  if (!context.mounted) return null;

  final picked = await showDialog<String>(
    context: context,
    builder: (ctx) => _WorkspacePickerDialog(recents: recents),
  );
  if (picked != null && picked.isNotEmpty) {
    await saveRecentWorkspace(picked);
  }
  return picked;
}

/// Push [path] to the front of the "recent workspaces" list and
/// trim to 10 entries. No-op when [path] is empty.
Future<void> saveRecentWorkspace(String path) async {
  if (path.isEmpty) return;
  final prefs = await SharedPreferences.getInstance();
  final recents = prefs.getStringList(_kRecentWorkspaces) ?? <String>[];
  recents.remove(path);
  recents.insert(0, path);
  if (recents.length > 10) recents.removeRange(10, recents.length);
  await prefs.setStringList(_kRecentWorkspaces, recents);
}

/// Read the list of recently-used workspace paths (most-recent first,
/// up to 10). Used by the drawer's "Add project" dropdown.
Future<List<String>> loadRecentWorkspaces() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getStringList(_kRecentWorkspaces) ?? const <String>[];
}

const _kRecentWorkspaces = 'recent_workspaces';

class _WorkspacePickerDialog extends StatefulWidget {
  final List<String> recents;
  const _WorkspacePickerDialog({required this.recents});

  @override
  State<_WorkspacePickerDialog> createState() => _WorkspacePickerDialogState();
}

class _WorkspacePickerDialogState extends State<_WorkspacePickerDialog> {
  final _ctrl = TextEditingController();
  String _value = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Dialog(
      backgroundColor: c.surface,
      insetPadding: const EdgeInsets.all(DsSpacing.x6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DsRadius.modal),
        side: BorderSide(color: c.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(DsSpacing.x7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: c.accentPrimary.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(DsRadius.input),
                    ),
                    child: Icon(Icons.folder_outlined,
                        size: 18, color: c.accentPrimary),
                  ),
                  const SizedBox(width: DsSpacing.x4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Pick a project folder',
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: c.textBright,
                            )),
                        const SizedBox(height: 2),
                        Text('Absolute path on the daemon host',
                            style: GoogleFonts.inter(
                                fontSize: 12, color: c.textMuted)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: DsSpacing.x6),
              TextField(
                controller: _ctrl,
                autofocus: true,
                onChanged: (v) => setState(() => _value = v),
                style: GoogleFonts.firaCode(fontSize: 13, color: c.textBright),
                decoration: InputDecoration(
                  hintText: '/home/user/project  ·  C:\\Users\\me\\project',
                  hintStyle:
                      GoogleFonts.firaCode(fontSize: 12.5, color: c.textDim),
                  filled: true,
                  fillColor: c.bg,
                  prefixIcon: Icon(Icons.terminal_rounded,
                      size: 16, color: c.textDim),
                  prefixIconConstraints:
                      const BoxConstraints(minWidth: 38, minHeight: 38),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(DsRadius.input),
                    borderSide: BorderSide(color: c.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(DsRadius.input),
                    borderSide: BorderSide(color: c.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(DsRadius.input),
                    borderSide: BorderSide(color: c.accentPrimary, width: 1.4),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: DsSpacing.x4, vertical: DsSpacing.x4),
                ),
                onSubmitted: (v) {
                  final trimmed = v.trim();
                  if (trimmed.isNotEmpty) Navigator.pop(context, trimmed);
                },
              ),
              if (widget.recents.isNotEmpty) ...[
                const SizedBox(height: DsSpacing.x6),
                Text('Recent projects',
                    style: GoogleFonts.inter(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                      color: c.textDim,
                    )),
                const SizedBox(height: DsSpacing.x3),
                for (final r in widget.recents.take(6))
                  _RecentRow(
                    path: r,
                    onTap: () => Navigator.pop(context, r),
                  ),
              ],
              const SizedBox(height: DsSpacing.x6),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('Cancel',
                        style: GoogleFonts.inter(
                            fontSize: 12.5, color: c.textMuted)),
                  ),
                  const SizedBox(width: DsSpacing.x3),
                  ElevatedButton(
                    onPressed: _value.trim().isEmpty
                        ? null
                        : () => Navigator.pop(context, _value.trim()),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: c.accentPrimary,
                      foregroundColor: c.onAccent,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                          horizontal: DsSpacing.x6, vertical: DsSpacing.x3),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(DsRadius.input)),
                    ),
                    child: Text('Select',
                        style: GoogleFonts.inter(
                            fontSize: 12.5, fontWeight: FontWeight.w600)),
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

class _RecentRow extends StatefulWidget {
  final String path;
  final VoidCallback onTap;
  const _RecentRow({required this.path, required this.onTap});

  @override
  State<_RecentRow> createState() => _RecentRowState();
}

class _RecentRowState extends State<_RecentRow> {
  bool _h = false;

  String _basename(String p) {
    final n = p.replaceAll('\\', '/');
    final i = n.lastIndexOf('/');
    return (i < 0 || i == n.length - 1) ? n : n.substring(i + 1);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final name = _basename(widget.path);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DsDuration.fast,
          margin: const EdgeInsets.only(bottom: DsSpacing.x2),
          padding: const EdgeInsets.symmetric(
              horizontal: DsSpacing.x4, vertical: DsSpacing.x3),
          decoration: BoxDecoration(
            color: _h ? c.surfaceAlt : c.bg,
            borderRadius: BorderRadius.circular(DsRadius.xs),
            border: Border.all(
                color: _h ? c.borderHover : c.border.withValues(alpha: 0.6)),
          ),
          child: Row(
            children: [
              Icon(Icons.folder_outlined,
                  size: 14, color: _h ? c.accentPrimary : c.textMuted),
              const SizedBox(width: DsSpacing.x3),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(name,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: c.textBright)),
                    Text(widget.path,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.firaCode(
                            fontSize: 10.5, color: c.textMuted)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
