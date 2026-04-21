/// Git-conflict resolution pane.
///
/// Parses the active file for `<<<<<<<`/`=======`/`>>>>>>>` markers
/// and surfaces each conflict as a card with three choices:
///   * Use ours   (local HEAD / current branch)
///   * Use theirs (incoming branch)
///   * Use both   (concatenate ours then theirs — fits most "added
///     a new import" style conflicts)
///
/// When every block has a choice, the "Resolve & save" button PUTs
/// the merged content back via [FileActionsService.writeback] with
/// `autoApprove: true` (per brief §4: conflict resolution is an
/// explicit user action — no need for a second approve step).
///
/// Replaces the legacy implementation that called `approve()` on a
/// conflict-marked file — that would have baseline-snapshotted the
/// markers themselves, which is never what the user wants.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../models/conflict_block.dart';
import '../../../services/file_actions_service.dart';
import '../../../services/file_content_service.dart';
import '../../../theme/app_theme.dart';
import '../../chat/chat_bubbles.dart' show showToast;

class ConflictPane extends StatefulWidget {
  final String path;
  /// Optional source override — when not provided, the pane fetches
  /// the latest content via [FileContentService]. Passing the source
  /// directly lets the editor avoid a second round-trip when it
  /// already has a fresh copy.
  final String? source;
  final VoidCallback? onResolved;
  const ConflictPane({
    super.key,
    required this.path,
    this.source,
    this.onResolved,
  });

  @override
  State<ConflictPane> createState() => _ConflictPaneState();
}

class _ConflictPaneState extends State<ConflictPane> {
  final Map<int, ConflictResolution> _choices = {};
  bool _busy = false;
  bool _loading = false;
  String? _error;
  String _source = '';
  ConflictParseResult _parsed =
      const ConflictParseResult(lines: [], blocks: []);

  @override
  void initState() {
    super.initState();
    if (widget.source != null) {
      _setSource(widget.source!);
    } else {
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant ConflictPane old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _choices.clear();
      if (widget.source != null) {
        _setSource(widget.source!);
      } else {
        _load();
      }
    } else if (widget.source != null && widget.source != _source) {
      _setSource(widget.source!);
    }
  }

  void _setSource(String s) {
    setState(() {
      _source = s;
      _parsed = parseConflicts(s);
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await FileContentService().load(widget.path);
    if (!mounted) return;
    if (res == null) {
      setState(() {
        _loading = false;
        _error = 'Could not load file content.';
      });
      return;
    }
    setState(() {
      _loading = false;
      _source = res.file.content;
      _parsed = parseConflicts(_source);
      _choices.clear();
    });
  }

  Future<void> _save() async {
    if (_choices.length != _parsed.blocks.length) {
      setState(() => _error = 'Resolve every block before saving.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final merged = applyResolutions(_parsed, _choices);
    // auto_approve: true — the user explicitly resolved every block,
    // baseline-snapshotting immediately saves them the second round-
    // trip through the approve button (brief §4).
    final ok = await FileActionsService()
        .writeback(widget.path, merged, autoApprove: true);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      showToast(context,
          'Resolved ${_parsed.blocks.length} conflict(s) in ${widget.path}.');
      widget.onResolved?.call();
    } else {
      setState(() => _error = 'Writeback failed — check connection.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(
            strokeWidth: 1.5, color: c.textMuted),
      );
    }
    if (!_parsed.hasConflicts) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline,
                size: 26, color: c.green),
            const SizedBox(height: 10),
            Text('No conflicts in this file.',
                style:
                    GoogleFonts.inter(fontSize: 12, color: c.textDim)),
          ],
        ),
      );
    }
    final resolvedCount = _choices.length;
    final total = _parsed.blocks.length;
    return Container(
      color: c.bg,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: c.surface,
              border: Border(bottom: BorderSide(color: c.border)),
            ),
            child: Row(
              children: [
                Icon(Icons.call_merge_rounded,
                    size: 14, color: c.orange),
                const SizedBox(width: 6),
                Text(
                  'Conflicts',
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: c.text),
                ),
                const SizedBox(width: 8),
                Text(
                  '$resolvedCount / $total resolved',
                  style: GoogleFonts.firaCode(
                      fontSize: 10, color: c.textDim),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed:
                      _busy || resolvedCount != total ? null : _save,
                  icon: _busy
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                              strokeWidth: 2))
                      : const Icon(Icons.check_rounded, size: 14),
                  label: Text(_busy ? 'Saving…' : 'Resolve & save'),
                ),
              ],
            ),
          ),
          if (_error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 6),
              color: c.red.withValues(alpha: 0.08),
              child: Text(
                _error!,
                style:
                    GoogleFonts.firaCode(fontSize: 10.5, color: c.red),
              ),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(10),
              itemCount: _parsed.blocks.length,
              itemBuilder: (_, i) => _ConflictCard(
                index: i,
                block: _parsed.blocks[i],
                choice: _choices[i],
                onChoose: (r) => setState(() {
                  if (r == null) {
                    _choices.remove(i);
                  } else {
                    _choices[i] = r;
                  }
                  _error = null;
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConflictCard extends StatelessWidget {
  final int index;
  final ConflictBlock block;
  final ConflictResolution? choice;
  final void Function(ConflictResolution? r) onChoose;

  const _ConflictCard({
    required this.index,
    required this.block,
    required this.choice,
    required this.onChoose,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: choice == null
              ? c.border
              : c.green.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
            child: Row(
              children: [
                Text(
                  'Conflict #${index + 1}',
                  style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: c.text,
                      letterSpacing: 0.3),
                ),
                const SizedBox(width: 6),
                Text(
                  'line ${block.startLine + 1} → ${block.endLine + 1}',
                  style: GoogleFonts.firaCode(
                      fontSize: 10, color: c.textDim),
                ),
                const Spacer(),
                if (choice != null)
                  TextButton(
                    onPressed: () => onChoose(null),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      minimumSize: Size.zero,
                      tapTargetSize:
                          MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      'clear',
                      style: GoogleFonts.inter(
                          fontSize: 10, color: c.textDim),
                    ),
                  ),
              ],
            ),
          ),
          _Side(
            label: 'Ours'
                '${block.oursLabel.isNotEmpty ? " (${block.oursLabel})" : ""}',
            lines: block.ours,
            color: c.blue,
            selected: choice == ConflictResolution.ours,
            onSelect: () => onChoose(ConflictResolution.ours),
          ),
          _Side(
            label: 'Theirs'
                '${block.theirsLabel.isNotEmpty ? " (${block.theirsLabel})" : ""}',
            lines: block.theirs,
            color: c.orange,
            selected: choice == ConflictResolution.theirs,
            onSelect: () => onChoose(ConflictResolution.theirs),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Row(
              children: [
                _ChoiceButton(
                  label: 'Use ours',
                  color: c.blue,
                  active: choice == ConflictResolution.ours,
                  onTap: () => onChoose(ConflictResolution.ours),
                ),
                const SizedBox(width: 6),
                _ChoiceButton(
                  label: 'Use theirs',
                  color: c.orange,
                  active: choice == ConflictResolution.theirs,
                  onTap: () => onChoose(ConflictResolution.theirs),
                ),
                const SizedBox(width: 6),
                _ChoiceButton(
                  label: 'Keep both',
                  color: c.accentPrimary,
                  active: choice == ConflictResolution.both,
                  onTap: () => onChoose(ConflictResolution.both),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Side extends StatelessWidget {
  final String label;
  final List<String> lines;
  final Color color;
  final bool selected;
  final VoidCallback onSelect;

  const _Side({
    required this.label,
    required this.lines,
    required this.color,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onSelect,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        decoration: BoxDecoration(
          color: selected
              ? color.withValues(alpha: 0.08)
              : c.surfaceAlt,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: selected
                ? color.withValues(alpha: 0.55)
                : c.border,
          ),
        ),
        padding: const EdgeInsets.symmetric(
            horizontal: 10, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (lines.isEmpty)
              Text(
                '(empty)',
                style: GoogleFonts.firaCode(
                    fontSize: 10,
                    color: c.textDim,
                    fontStyle: FontStyle.italic),
              )
            else
              ...lines.take(8).map(
                    (l) => Text(
                      l,
                      style: GoogleFonts.firaCode(
                          fontSize: 10.5, color: c.text),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
            if (lines.length > 8)
              Text(
                '… ${lines.length - 8} more line(s)',
                style: GoogleFonts.firaCode(
                    fontSize: 10, color: c.textDim),
              ),
          ],
        ),
      ),
    );
  }
}

class _ChoiceButton extends StatelessWidget {
  final String label;
  final Color color;
  final bool active;
  final VoidCallback onTap;
  const _ChoiceButton({
    required this.label,
    required this.color,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active
              ? color.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: active
                ? color.withValues(alpha: 0.6)
                : color.withValues(alpha: 0.3),
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: color,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}
