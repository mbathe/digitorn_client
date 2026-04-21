import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/background_app_service.dart';
import '../../theme/app_theme.dart';
import 'artifact_preview.dart';

/// Slide-in drawer (520px from the right) showing everything about
/// one activation:
///
/// 1. **Meta overview** — duration, tokens, cost, started_at.
/// 2. **Timeline** — every event (trigger, tool_call, thinking,
///    artifact, channel_send, error) rendered as a vertical log with
///    connector dots.
/// 3. **Artifacts** — clickable list, tap → download + open in the
///    appropriate viewer via [ArtifactPreviewPage].
/// 4. **Channels sent** — outbound messages with status.
/// 5. **Error trace** — selectable stack if the run failed.
///
/// Opened from [BackgroundDashboard] when the user taps a row in the
/// activations list. Close via the top-left back chevron, the scrim,
/// or pressing Escape.
class ActivationDrawer extends StatefulWidget {
  final String appId;
  final Activation activation;

  const ActivationDrawer({
    super.key,
    required this.appId,
    required this.activation,
  });

  @override
  State<ActivationDrawer> createState() => _ActivationDrawerState();
}

class _ActivationDrawerState extends State<ActivationDrawer> {
  final _svc = BackgroundAppService();

  bool _loading = true;
  String? _error;
  Activation? _meta;
  List<ActivationEvent> _events = const [];
  List<ActivationArtifact> _artifacts = const [];

  @override
  void initState() {
    super.initState();
    _meta = widget.activation;
    _load();
  }

  Future<void> _load() async {
    try {
      // Parallel: fresh meta + full event list. Artifacts are derived
      // from the events list on the client, so we don't double-fetch.
      final results = await Future.wait([
        _svc.getActivation(widget.appId, widget.activation.id),
        _svc.loadActivationEvents(widget.appId, widget.activation.id),
      ]);
      if (!mounted) return;
      final meta = results[0] as Activation?;
      final events = (results[1] as List<ActivationEvent>);
      final artifacts = events
          .where((e) => e.eventType == 'artifact')
          .map((e) => ActivationArtifact.fromEvent({
                'id': e.id,
                'sequence': e.sequence,
                'timestamp': e.timestamp.toIso8601String(),
                'data': e.data,
              }))
          .toList();
      setState(() {
        _meta = meta ?? widget.activation;
        _events = events;
        _artifacts = artifacts;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // ── Artifact download + preview flow ────────────────────────────────

  Future<void> _openArtifact(ActivationArtifact artifact) async {
    // Size confirmation for large files (> 10 MB).
    if (artifact.sizeBytes != null && artifact.sizeBytes! > 10 * 1024 * 1024) {
      final proceed = await _confirmLargeDownload(artifact);
      if (proceed != true || !mounted) return;
    }

    // Blocking loader during the download.
    unawaited(showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _BlockingLoader(),
    ));

    final download = await _svc.downloadArtifact(
      appId: widget.appId,
      eventId: artifact.eventId,
    );

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // dismiss loader

    if (download == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Failed to download ${artifact.filename}'),
        backgroundColor: context.colors.red.withValues(alpha: 0.9),
      ));
      return;
    }

    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ArtifactPreviewPage(download: download),
    ));
  }

  Future<bool?> _confirmLargeDownload(ActivationArtifact a) {
    final c = context.colors;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c.border),
        ),
        title: Text('Large file',
            style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: c.textBright)),
        content: Text(
          'This file is ${a.sizeDisplay}. Downloading may take a moment.',
          style: GoogleFonts.inter(fontSize: 12, color: c.text, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel',
                style: GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: c.blue,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6)),
            ),
            child: Text('Download',
                style: GoogleFonts.inter(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // The drawer is opened as a modal route — the outer widget is a
    // full-screen Material. We use a Row so the scrim covers everything
    // that's not the panel.
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        behavior: HitTestBehavior.opaque,
        child: Row(
          children: [
            const Expanded(child: SizedBox.shrink()),
            GestureDetector(
              onTap: () {}, // swallow taps inside the panel
              child: _DrawerPanel(
                color: c,
                header: _buildHeader(c),
                body: _loading
                    ? Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: c.textMuted),
                        ),
                      )
                    : _error != null
                        ? _buildError(c, _error!)
                        : _buildContent(c),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(AppColors c) {
    final m = _meta ?? widget.activation;
    final (color, label, icon) = switch (m.status) {
      'failed' => (c.red, 'FAILED', Icons.error_outline_rounded),
      'running' => (c.orange, 'RUNNING', Icons.hourglass_empty_rounded),
      _ => (c.green, 'SUCCESS', Icons.check_circle_outline_rounded),
    };
    return Container(
      height: 56,
      padding: const EdgeInsets.fromLTRB(10, 0, 14, 0),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Close',
            icon: Icon(Icons.close_rounded, size: 18, color: c.textMuted),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 4),
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withValues(alpha: 0.3)),
            ),
            child: Icon(icon, size: 15, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Activation ${m.id.length > 8 ? m.id.substring(0, 8) : m.id}',
                  style: GoogleFonts.firaCode(
                      fontSize: 12,
                      color: c.text,
                      fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    _PillTag(label: label, color: color),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        m.triggerType.isNotEmpty
                            ? '${m.triggerType} · ${m.timeDisplay}'
                            : m.timeDisplay,
                        style: GoogleFonts.firaCode(
                            fontSize: 10, color: c.textMuted),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Copy id',
            icon: Icon(Icons.copy_rounded, size: 15, color: c.textMuted),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: m.id));
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Activation id copied'),
                duration: Duration(seconds: 2),
              ));
            },
          ),
        ],
      ),
    );
  }

  Widget _buildContent(AppColors c) {
    final m = _meta ?? widget.activation;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
      children: [
        _SectionLabel('OVERVIEW'),
        const SizedBox(height: 10),
        _OverviewGrid(meta: m),
        const SizedBox(height: 26),

        _SectionLabel('TIMELINE', count: _events.length),
        const SizedBox(height: 10),
        if (_events.isEmpty)
          _EmptySlot(
              icon: Icons.timeline_rounded,
              text: 'No events recorded for this run'),
        for (var i = 0; i < _events.length; i++)
          _TimelineRow(
            event: _events[i],
            isFirst: i == 0,
            isLast: i == _events.length - 1,
          ),
        const SizedBox(height: 26),

        if (_artifacts.isNotEmpty) ...[
          _SectionLabel('ARTIFACTS', count: _artifacts.length),
          const SizedBox(height: 10),
          for (final a in _artifacts)
            _ArtifactCard(artifact: a, onTap: () => _openArtifact(a)),
          const SizedBox(height: 26),
        ],

        _buildChannelsSentSection(c),

        if (m.isFailed && (m.error ?? '').isNotEmpty) ...[
          const SizedBox(height: 26),
          _SectionLabel('ERROR', color: c.red),
          const SizedBox(height: 10),
          _ErrorTrace(error: m.error!),
        ],
      ],
    );
  }

  Widget _buildChannelsSentSection(AppColors c) {
    final sends = _events
        .where((e) =>
            e.eventType == 'channel_send' || e.eventType == 'channel_sent')
        .toList();
    if (sends.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel('CHANNELS SENT', count: sends.length),
        const SizedBox(height: 10),
        for (final e in sends)
          _ChannelSendRow(
            type: e.channelType ?? 'unknown',
            target: e.channelTarget ?? '',
            status: e.data['status'] as String? ?? 'delivered',
          ),
      ],
    );
  }

  Widget _buildError(AppColors c, String error) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline_rounded, size: 32, color: c.red),
          const SizedBox(height: 10),
          Text('Could not load activation',
              style: GoogleFonts.inter(
                  fontSize: 13,
                  color: c.textBright,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(error,
              textAlign: TextAlign.center,
              style: GoogleFonts.firaCode(
                  fontSize: 11, color: c.textMuted, height: 1.45)),
        ],
      ),
    );
  }
}

// ─── Drawer panel chrome ───────────────────────────────────────────────────

class _DrawerPanel extends StatelessWidget {
  final AppColors color;
  final Widget header;
  final Widget body;
  const _DrawerPanel({
    required this.color,
    required this.header,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (_, v, child) => Transform.translate(
        offset: Offset(80 * (1 - v), 0),
        child: Opacity(opacity: v, child: child),
      ),
      child: Container(
        width: MediaQuery.sizeOf(context).width < 560
            ? MediaQuery.sizeOf(context).width
            : 520,
        height: double.infinity,
        decoration: BoxDecoration(
          color: color.bg,
          border: Border(left: BorderSide(color: color.border)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 40,
              offset: const Offset(-8, 0),
            ),
          ],
        ),
        child: Column(
          children: [
            header,
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

// ─── Section label + reusable bits ────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String label;
  final int? count;
  final Color? color;
  const _SectionLabel(this.label, {this.count, this.color});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final baseColor = color ?? c.textDim;
    return Row(
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 10,
            color: baseColor,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4,
          ),
        ),
        if (count != null) ...[
          const SizedBox(width: 8),
          Text(
            '$count',
            style: GoogleFonts.firaCode(
                fontSize: 10, color: c.textMuted, fontWeight: FontWeight.w600),
          ),
        ],
        const SizedBox(width: 10),
        Expanded(child: Container(height: 1, color: c.border)),
      ],
    );
  }
}

class _PillTag extends StatelessWidget {
  final String label;
  final Color color;
  const _PillTag({required this.label, required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(label,
          style: GoogleFonts.firaCode(
              fontSize: 8,
              color: color,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5)),
    );
  }
}

class _EmptySlot extends StatelessWidget {
  final IconData icon;
  final String text;
  const _EmptySlot({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: c.textMuted),
          const SizedBox(width: 8),
          Text(text,
              style: GoogleFonts.inter(fontSize: 11.5, color: c.textMuted)),
        ],
      ),
    );
  }
}

// ─── Overview grid ─────────────────────────────────────────────────────────

class _OverviewGrid extends StatelessWidget {
  final Activation meta;
  const _OverviewGrid({required this.meta});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final in_ = meta.promptTokens;
    final out = meta.completionTokens;
    final total = meta.totalTokens;
    final toolCalls = meta.toolCallsCount;
    final startedLabel = meta.startedAt != null
        ? _formatTs(meta.startedAt!)
        : '—';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          _row(c, 'Started', startedLabel),
          _divider(c),
          _row(c, 'Duration', meta.durationDisplay),
          _divider(c),
          _row(c, 'Tool calls', '$toolCalls'),
          _divider(c),
          _row(c, 'Prompt tokens', _fmt(in_)),
          _divider(c),
          _row(c, 'Completion tokens', _fmt(out)),
          _divider(c),
          _row(c, 'Total tokens', _fmt(total), bold: true),
        ],
      ),
    );
  }

  Widget _row(AppColors c, String key, String value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(key,
                style: GoogleFonts.inter(
                    fontSize: 11,
                    color: c.textMuted,
                    fontWeight: FontWeight.w500)),
          ),
          Text(value,
              style: GoogleFonts.firaCode(
                  fontSize: 11.5,
                  color: bold ? c.textBright : c.text,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }

  Widget _divider(AppColors c) => Divider(height: 1, color: c.border);

  static String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(2)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }

  static String _formatTs(DateTime t) {
    final y = t.year.toString().padLeft(4, '0');
    final m = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    final h = t.hour.toString().padLeft(2, '0');
    final mi = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$mi:$s';
  }
}

// ─── Timeline row ──────────────────────────────────────────────────────────

class _TimelineRow extends StatefulWidget {
  final ActivationEvent event;
  final bool isFirst;
  final bool isLast;
  const _TimelineRow({
    required this.event,
    required this.isFirst,
    required this.isLast,
  });

  @override
  State<_TimelineRow> createState() => _TimelineRowState();
}

class _TimelineRowState extends State<_TimelineRow> {
  bool _expanded = false;

  /// Depth in the parent/child tree — read from `parent_id` when the
  /// daemon emits it. Top-level events are 0, sub-agent calls get an
  /// indent offset per level. We can't know the full ancestor chain
  /// without the entire list so we default to 1 whenever a parent_id
  /// is present — good enough to visually distinguish nested calls.
  int get _indent =>
      (widget.event.data['parent_id'] as String?)?.isNotEmpty == true ? 1 : 0;

  double? get _durationMs {
    final v = widget.event.data['duration_ms'] ?? widget.event.data['durationMs'];
    if (v is num) return v.toDouble();
    return null;
  }

  (int, int)? get _costTokens {
    final v = widget.event.data['cost_tokens'];
    if (v is Map) {
      final p = (v['prompt'] as num?)?.toInt() ?? 0;
      final c = (v['completion'] as num?)?.toInt() ?? 0;
      if (p == 0 && c == 0) return null;
      return (p, c);
    }
    return null;
  }

  String? get _argsPreview {
    final args = widget.event.data['args'] ??
        widget.event.data['params'] ??
        widget.event.data['arguments'];
    if (args == null) return null;
    final s = args is String ? args : args.toString();
    return s.isEmpty ? null : s;
  }

  String? get _resultPreview {
    final r = widget.event.data['result'] ?? widget.event.data['output'];
    if (r == null) return null;
    final s = r is String ? r : r.toString();
    return s.isEmpty ? null : s;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (icon, tint, title, subtitle) =
        _TimelineRowState._renderEvent(c, widget.event);
    final ts = _TimelineRowState._timeOfDay(widget.event.timestamp);
    final dur = _durationMs;
    final tokens = _costTokens;
    final args = _argsPreview;
    final result = _resultPreview;

    // A row is expandable when it has args, a result, or a text
    // payload that overflows 4 lines — otherwise the chevron is
    // hidden to keep the timeline visually clean.
    final expandable = args != null || result != null;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Timestamp gutter
          SizedBox(
            width: 56,
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                ts,
                textAlign: TextAlign.right,
                style: GoogleFonts.firaCode(fontSize: 10, color: c.textDim),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Connector column
          SizedBox(
            width: 22,
            child: Column(
              children: [
                Container(
                  width: 2,
                  height: widget.isFirst ? 6 : 10,
                  color: widget.isFirst ? Colors.transparent : c.border,
                ),
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: tint.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                    border: Border.all(color: tint, width: 1.5),
                  ),
                ),
                Expanded(
                  child: Container(
                    width: 2,
                    color: widget.isLast ? Colors.transparent : c.border,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (_indent > 0) SizedBox(width: 16.0 * _indent),
          // Content
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: MouseRegion(
                cursor: expandable
                    ? SystemMouseCursors.click
                    : SystemMouseCursors.basic,
                child: GestureDetector(
                  onTap: expandable
                      ? () => setState(() => _expanded = !_expanded)
                      : null,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: _expanded ? tint.withValues(alpha: 0.5) : c.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(icon, size: 12, color: tint),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(
                                    fontSize: 11.5,
                                    color: c.textBright,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                            if (dur != null) ...[
                              const SizedBox(width: 6),
                              _MiniChip(
                                label: _fmtDuration(dur),
                                fg: c.textMuted,
                                bg: c.surfaceAlt,
                              ),
                            ],
                            if (tokens != null) ...[
                              const SizedBox(width: 4),
                              _MiniChip(
                                label:
                                    '${tokens.$1 + tokens.$2} tok',
                                fg: c.cyan,
                                bg: c.cyan.withValues(alpha: 0.08),
                              ),
                            ],
                            if (expandable) ...[
                              const SizedBox(width: 4),
                              Icon(
                                _expanded
                                    ? Icons.expand_less_rounded
                                    : Icons.expand_more_rounded,
                                size: 14,
                                color: c.textMuted,
                              ),
                            ],
                          ],
                        ),
                        if (subtitle != null && subtitle.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            subtitle,
                            maxLines: _expanded ? 40 : 3,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.firaCode(
                                fontSize: 10.5,
                                color: c.textMuted,
                                height: 1.5),
                          ),
                        ],
                        if (_expanded && args != null) ...[
                          const SizedBox(height: 8),
                          _PayloadBlock(label: 'args', body: args),
                        ],
                        if (_expanded && result != null) ...[
                          const SizedBox(height: 6),
                          _PayloadBlock(label: 'result', body: result),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _fmtDuration(double ms) {
    if (ms < 1000) return '${ms.round()}ms';
    if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
    return '${(ms / 60000).toStringAsFixed(1)}m';
  }

  static String _timeOfDay(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${ms.substring(0, 1)}';
  }

  /// Returns `(icon, tint, title, subtitle?)` for an event type.
  static (IconData, Color, String, String?) _renderEvent(
      AppColors c, ActivationEvent e) {
    switch (e.eventType) {
      case 'trigger':
        return (
          Icons.flash_on_rounded,
          c.orange,
          'Trigger fired',
          (e.data['name'] ?? e.data['trigger_id']) as String?,
        );
      case 'agent_start':
        return (Icons.smart_toy_outlined, c.blue, 'Agent started', null);
      case 'agent_end':
      case 'agent_done':
        return (Icons.check_circle_outline_rounded, c.green, 'Agent done', null);
      case 'tool_call':
        return (
          Icons.build_rounded,
          c.cyan,
          'Tool · ${e.toolName ?? '?'}',
          _shortenToolDetail(e.data),
        );
      case 'thinking':
        return (Icons.psychology_outlined, c.purple, 'Thinking',
            e.text?.trim());
      case 'artifact':
        final path = e.data['path'] as String? ?? '';
        return (
          Icons.description_rounded,
          c.green,
          'Artifact · ${path.split('/').last}',
          path.isEmpty ? null : path,
        );
      case 'channel_send':
      case 'channel_sent':
        final type = e.channelType ?? '';
        final target = e.channelTarget ?? '';
        return (
          Icons.send_rounded,
          c.blue,
          'Channel · $type',
          target.isEmpty ? null : target,
        );
      case 'error':
        return (Icons.error_outline_rounded, c.red, 'Error', e.text);
      default:
        return (Icons.circle_outlined, c.textMuted, e.eventType, e.text);
    }
  }

  static String? _shortenToolDetail(Map<String, dynamic> data) {
    final params = data['params'];
    if (params is Map) {
      final path = params['path'] ?? params['file'] ?? params['command'];
      if (path is String && path.isNotEmpty) return path;
    }
    final detail = data['detail'];
    if (detail is String && detail.isNotEmpty) return detail;
    return null;
  }
}

/// Compact chip used in the timeline row header for duration / token
/// counts. Not exported — intentionally private to this file to keep
/// the drawer's visual language consistent.
class _MiniChip extends StatelessWidget {
  final String label;
  final Color fg;
  final Color bg;
  const _MiniChip({required this.label, required this.fg, required this.bg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: GoogleFonts.firaCode(
          fontSize: 9,
          color: fg,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Code-style block used for expandable `args` / `result` payloads in
/// an expanded timeline row. Shows the raw JSON-ish text with
/// monospace font + scroll + copy button.
class _PayloadBlock extends StatelessWidget {
  final String label;
  final String body;
  const _PayloadBlock({required this.label, required this.body});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: GoogleFonts.firaCode(
                  fontSize: 9,
                  color: c.textMuted,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => Clipboard.setData(ClipboardData(text: body)),
                child: Icon(Icons.copy_rounded, size: 11, color: c.textDim),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(
            body,
            style: GoogleFonts.firaCode(
              fontSize: 10,
              color: c.text,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Artifact card ─────────────────────────────────────────────────────────

class _ArtifactCard extends StatefulWidget {
  final ActivationArtifact artifact;
  final VoidCallback onTap;
  const _ArtifactCard({required this.artifact, required this.onTap});

  @override
  State<_ArtifactCard> createState() => _ArtifactCardState();
}

class _ArtifactCardState extends State<_ArtifactCard> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final a = widget.artifact;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _h ? c.surfaceAlt : c.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: _h ? c.borderHover : c.border),
              boxShadow: _h
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.blue.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(color: c.blue.withValues(alpha: 0.3)),
                  ),
                  child: Icon(_iconForExt(a.extension),
                      size: 16, color: c.blue),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(a.filename,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                              fontSize: 12.5,
                              color: c.textBright,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(
                        '${a.sizeDisplay} · ${a.action}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.firaCode(
                            fontSize: 10, color: c.textMuted),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.open_in_new_rounded, size: 14, color: c.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static IconData _iconForExt(String ext) => switch (ext) {
        'pdf' => Icons.picture_as_pdf_rounded,
        'csv' || 'tsv' => Icons.table_chart_outlined,
        'json' || 'jsonc' => Icons.data_object_rounded,
        'yaml' || 'yml' => Icons.integration_instructions_outlined,
        'md' || 'markdown' => Icons.description_rounded,
        'log' => Icons.receipt_long_outlined,
        'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' =>
          Icons.image_outlined,
        _ => Icons.insert_drive_file_outlined,
      };
}

// ─── Channel send row ─────────────────────────────────────────────────────

class _ChannelSendRow extends StatelessWidget {
  final String type;
  final String target;
  final String status;
  const _ChannelSendRow({
    required this.type,
    required this.target,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ok = status == 'delivered' ||
        status == 'sent' ||
        status == 'ok' ||
        status == '200';
    final color = ok ? c.green : c.orange;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            Icon(_iconForChannel(type), size: 14, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(type,
                      style: GoogleFonts.inter(
                          fontSize: 11.5,
                          color: c.textBright,
                          fontWeight: FontWeight.w600)),
                  if (target.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(target,
                        style: GoogleFonts.firaCode(
                            fontSize: 10, color: c.textMuted)),
                  ],
                ],
              ),
            ),
            _PillTag(label: status.toUpperCase(), color: color),
          ],
        ),
      ),
    );
  }

  static IconData _iconForChannel(String t) => switch (t) {
        'email' => Icons.mail_outline_rounded,
        'slack' => Icons.tag_rounded,
        'webhook' => Icons.link_rounded,
        'telegram' => Icons.send_rounded,
        'log' => Icons.receipt_long_outlined,
        _ => Icons.outbox_rounded,
      };
}

// ─── Error trace ──────────────────────────────────────────────────────────

class _ErrorTrace extends StatelessWidget {
  final String error;
  const _ErrorTrace({required this.error});
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.red.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.red.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 14, color: c.red),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              error,
              style: GoogleFonts.firaCode(
                  fontSize: 11, color: c.text, height: 1.5),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'Copy error',
            icon: Icon(Icons.copy_rounded, size: 14, color: c.textMuted),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: error));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Error copied'),
                duration: Duration(seconds: 2),
              ));
            },
          ),
        ],
      ),
    );
  }
}

// ─── Blocking loader ──────────────────────────────────────────────────────

class _BlockingLoader extends StatelessWidget {
  const _BlockingLoader();
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: c.textMuted),
            ),
            const SizedBox(height: 12),
            Text('Downloading…',
                style: GoogleFonts.inter(fontSize: 11.5, color: c.textMuted)),
          ],
        ),
      ),
    );
  }
}

