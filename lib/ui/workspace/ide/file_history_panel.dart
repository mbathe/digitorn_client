/// Compact approval-history list for a single workspace file.
///
/// Reads `GET /workspace/files/{path}/history` through
/// [FileHistoryService] (TTL-cached 30s per the daemon contract).
/// Each row: revision #, approved_by (user / auto), relative time,
/// token delta, size. Auto entries are marked with a gray "AUTO"
/// badge so the user can tell when the file was staged by the
/// module vs explicitly by them.
///
/// Surfaced from the editor pane as a popover / side sheet — not
/// always visible, to keep the IDE focused.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../models/file_revision.dart';
import '../../../services/file_history_service.dart';
import '../../../services/session_service.dart';
import '../../../theme/app_theme.dart';

class FileHistoryPanel extends StatefulWidget {
  final String path;
  const FileHistoryPanel({super.key, required this.path});

  @override
  State<FileHistoryPanel> createState() => _FileHistoryPanelState();
}

class _FileHistoryPanelState extends State<FileHistoryPanel> {
  @override
  void initState() {
    super.initState();
    _refresh();
    FileHistoryService().addListener(_onChanged);
  }

  @override
  void didUpdateWidget(covariant FileHistoryPanel old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _refresh();
  }

  @override
  void dispose() {
    FileHistoryService().removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    scheduleMicrotask(() {
      if (mounted) setState(() {});
    });
  }

  void _refresh() {
    final session = SessionService().activeSession;
    if (session == null) return;
    FileHistoryService()
        .ensure(session.appId, session.sessionId, widget.path);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final session = SessionService().activeSession;
    final revs = session == null
        ? <FileRevision>[]
        : (FileHistoryService().cached(
                session.appId, session.sessionId, widget.path) ??
            const []);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
            child: Row(
              children: [
                Icon(Icons.history_rounded,
                    size: 13, color: c.textMuted),
                const SizedBox(width: 6),
                Text(
                  'Approval history',
                  style: GoogleFonts.inter(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: c.textMuted,
                      letterSpacing: 0.3),
                ),
                const Spacer(),
                Text(
                  '${revs.length}',
                  style: GoogleFonts.firaCode(
                      fontSize: 10, color: c.textDim),
                ),
              ],
            ),
          ),
          if (revs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              child: Text(
                'No revisions yet — approve the file to start the history.',
                style: GoogleFonts.inter(
                    fontSize: 10.5,
                    color: c.textDim,
                    fontStyle: FontStyle.italic),
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: revs.length,
                itemBuilder: (_, i) => _RevisionRow(rev: revs[i]),
              ),
            ),
        ],
      ),
    );
  }
}

class _RevisionRow extends StatelessWidget {
  final FileRevision rev;
  const _RevisionRow({required this.rev});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final when = _formatAgo(rev.approvedAt);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Container(
            width: 28,
            alignment: Alignment.centerLeft,
            child: Text(
              '#${rev.revision}',
              style: GoogleFonts.firaCode(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: c.accentPrimary),
            ),
          ),
          if (rev.isAutoApproved) ...[
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: c.border),
              ),
              child: Text('AUTO',
                  style: GoogleFonts.firaCode(
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: c.textDim)),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              when ?? 'just now',
              style: GoogleFonts.inter(fontSize: 10.5, color: c.textDim),
            ),
          ),
          if (rev.tokensDeltaIns > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text('+${rev.tokensDeltaIns}',
                  style: GoogleFonts.firaCode(
                      fontSize: 10, color: c.green)),
            ),
          if (rev.tokensDeltaDel > 0)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text('-${rev.tokensDeltaDel}',
                  style: GoogleFonts.firaCode(
                      fontSize: 10, color: c.red)),
            ),
          Text(
            _formatBytes(rev.bytes),
            style: GoogleFonts.firaCode(fontSize: 10, color: c.textDim),
          ),
        ],
      ),
    );
  }

  static String _formatBytes(int b) {
    if (b < 1024) return '${b}B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)}KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  static String? _formatAgo(DateTime? when) {
    if (when == null) return null;
    final diff = DateTime.now().difference(when);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
