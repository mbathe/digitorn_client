import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../services/background_app_service.dart';
import '../../theme/app_theme.dart';

class ActivationsPage extends StatefulWidget {
  final String appId;
  final String appName;
  final List<Trigger> triggers;

  /// When non-null, the page shows only activations whose
  /// `sessionId` matches. Rendered as a filter pill the user can
  /// remove — clearing it falls back to the full activations list.
  final String? sessionId;
  final String? sessionName;

  const ActivationsPage({
    super.key,
    required this.appId,
    required this.appName,
    this.triggers = const [],
    this.sessionId,
    this.sessionName,
  });

  @override
  State<ActivationsPage> createState() => _ActivationsPageState();
}

class _ActivationsPageState extends State<ActivationsPage> {
  final _svc = BackgroundAppService();
  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  List<Activation> _activations = [];
  ActivationStats? _stats;
  bool _loading = true;
  bool _loadingMore = false;
  int _offset = 0;
  int _total = 0;
  String? _filterTrigger;
  String? _filterStatus;
  String? _filterSessionId;
  String _searchQuery = '';
  String? _expandedId;

  @override
  void initState() {
    super.initState();
    _filterSessionId = widget.sessionId;
    _load();
    _scroll.addListener(_onScroll);
  }

  /// Apply the client-side filters on top of the already daemon-
  /// filtered list: session id + text query. The session filter is
  /// also purely client-side because the daemon's `/activations`
  /// endpoint doesn't accept a session filter yet.
  List<Activation> get _visibleActivations {
    Iterable<Activation> list = _activations;
    if (_filterSessionId != null && _filterSessionId!.isNotEmpty) {
      list = list.where((a) => a.sessionId == _filterSessionId);
    }
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((a) {
        return a.message.toLowerCase().contains(q) ||
            a.response.toLowerCase().contains(q) ||
            (a.error?.toLowerCase().contains(q) ?? false) ||
            a.status.toLowerCase().contains(q) ||
            a.triggerType.toLowerCase().contains(q) ||
            a.id.toLowerCase().contains(q);
      });
    }
    return list.toList(growable: false);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _offset = 0; });
    await Future.wait([
      _loadActivations(reset: true),
      _loadStats(),
    ]);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadActivations({bool reset = false}) async {
    if (reset) _offset = 0;
    await _svc.loadActivations(
      widget.appId,
      limit: 20,
      offset: _offset,
      triggerId: _filterTrigger,
      status: _filterStatus,
    );
    _activations = reset ? List.from(_svc.activations) : _activations + _svc.activations;
    // Estimate total from loaded count (actual total comes from stats)
    _total = _stats?.total ?? _activations.length + 20;
  }

  Future<void> _loadStats() async {
    _stats = await _svc.loadStats(widget.appId);
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 200 &&
        !_loadingMore && _activations.length < _total) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    _offset = _activations.length;
    await _loadActivations();
    if (mounted) setState(() => _loadingMore = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return Scaffold(
      backgroundColor: c.bg,
      body: Column(
        children: [
          // Header
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: c.surface,
              border: Border(bottom: BorderSide(color: c.border)),
            ),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Icon(Icons.arrow_back_rounded, size: 18, color: c.textMuted),
                ),
                const SizedBox(width: 14),
                Text(
                    widget.sessionId != null ? 'Session runs' : 'Activations',
                    style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: c.textBright)),
                const SizedBox(width: 6),
                Text(
                    widget.sessionId != null
                        ? (widget.sessionName ?? widget.sessionId!.substring(0, 8))
                        : widget.appName,
                    style: GoogleFonts.inter(
                        fontSize: 13, color: c.textMuted)),
                const Spacer(),
                GestureDetector(
                  onTap: _load,
                  child: Icon(Icons.refresh_rounded, size: 17, color: c.textMuted),
                ),
              ],
            ),
          ),

          // Stats bar
          if (_stats != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: c.surface,
                border: Border(bottom: BorderSide(color: c.border)),
              ),
              child: Row(
                children: [
                  _MiniStat(label: 'Total', value: '${_stats!.total}', c: c),
                  _MiniStat(
                    label: 'Success',
                    value: '${_stats!.successRate.toStringAsFixed(0)}%',
                    color: _stats!.successRate > 90 ? c.green : c.orange,
                    c: c,
                  ),
                  _MiniStat(
                    label: 'Avg',
                    value: _stats!.avgDurationMs < 1000
                        ? '${_stats!.avgDurationMs.round()}ms'
                        : '${(_stats!.avgDurationMs / 1000).toStringAsFixed(1)}s',
                    c: c,
                  ),
                  _MiniStat(
                    label: 'Failed',
                    value: '${_stats!.failed}',
                    color: _stats!.failed > 0 ? c.red : null,
                    c: c,
                  ),
                ],
              ),
            ),

          // Filters + search
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Column(
              children: [
                Row(
                  children: [
                    // Trigger filter
                    _FilterChip(
                      label: _filterTrigger ?? 'All triggers',
                      active: _filterTrigger != null,
                      onTap: () => _showTriggerFilter(context),
                    ),
                    const SizedBox(width: 8),
                    // Status filter
                    _FilterChip(
                      label: _filterStatus ?? 'All status',
                      active: _filterStatus != null,
                      onTap: () => _showStatusFilter(context),
                    ),
                    if (_filterSessionId != null) ...[
                      const SizedBox(width: 8),
                      _FilterChip(
                        label:
                            'Session: ${widget.sessionName?.isNotEmpty == true ? widget.sessionName : _filterSessionId!.substring(0, 6)}',
                        active: true,
                        onTap: () =>
                            setState(() => _filterSessionId = null),
                      ),
                    ],
                    if (_filterTrigger != null ||
                        _filterStatus != null ||
                        _filterSessionId != null ||
                        _searchQuery.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _filterTrigger = null;
                            _filterStatus = null;
                            _filterSessionId = null;
                            _searchQuery = '';
                            _searchCtrl.clear();
                          });
                          _load();
                        },
                        child: Text('Clear',
                            style: GoogleFonts.inter(
                                fontSize: 11, color: c.blue)),
                      ),
                    ],
                    const Spacer(),
                    Text(
                      _searchQuery.isNotEmpty
                          ? '${_visibleActivations.length} / ${_activations.length}'
                          : '${_activations.length} / $_total',
                      style: GoogleFonts.firaCode(
                          fontSize: 10, color: c.textDim),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Search bar — filters loaded rows client-side on
                // message / response / error / trigger / id.
                Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: c.border),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.search_rounded, size: 13, color: c.textMuted),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _searchCtrl,
                          onChanged: (v) =>
                              setState(() => _searchQuery = v.trim()),
                          style: GoogleFonts.inter(
                              fontSize: 12, color: c.textBright),
                          decoration: InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            hintText:
                                'Search in messages, responses, errors…',
                            hintStyle: GoogleFonts.inter(
                                fontSize: 12, color: c.textMuted),
                          ),
                        ),
                      ),
                      if (_searchQuery.isNotEmpty)
                        GestureDetector(
                          onTap: () => setState(() {
                            _searchQuery = '';
                            _searchCtrl.clear();
                          }),
                          child: Icon(Icons.close_rounded,
                              size: 13, color: c.textMuted),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Activations list
          Expanded(
            child: _loading
                ? Center(child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: c.textMuted))
                : _visibleActivations.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                                _searchQuery.isNotEmpty
                                    ? Icons.search_off_rounded
                                    : Icons.history_rounded,
                                size: 32,
                                color: c.textDim),
                            const SizedBox(height: 12),
                            Text(
                                _searchQuery.isNotEmpty
                                    ? 'No activation matches "$_searchQuery"'
                                    : 'No activations found',
                                style: GoogleFonts.inter(
                                    fontSize: 13, color: c.textMuted)),
                          ],
                        ),
                      )
                    : Builder(builder: (_) {
                        final visible = _visibleActivations;
                        return ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                        itemCount: visible.length + (_loadingMore ? 1 : 0),
                        itemBuilder: (_, i) {
                          if (i >= visible.length) {
                            return Padding(
                              padding: const EdgeInsets.all(16),
                              child: Center(child: CircularProgressIndicator(
                                  strokeWidth: 1.5, color: c.textMuted)),
                            );
                          }

                          final a = visible[i];
                          final isExpanded = _expandedId == a.id;

                          // Date separator
                          Widget? separator;
                          if (i == 0 || _dayLabel(a) != _dayLabel(visible[i - 1])) {
                            separator = Padding(
                              padding: const EdgeInsets.only(top: 16, bottom: 8),
                              child: Text(_dayLabel(a),
                                style: GoogleFonts.inter(
                                  fontSize: 11, fontWeight: FontWeight.w600,
                                  color: c.textDim, letterSpacing: 0.5)),
                            );
                          }

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ?separator,
                              _FullActivationTile(
                                activation: a,
                                isExpanded: isExpanded,
                                onTap: () => setState(() {
                                  _expandedId = isExpanded ? null : a.id;
                                }),
                              ),
                            ],
                          );
                        },
                      );
                      }),
          ),
        ],
      ),
    );
  }

  String _dayLabel(Activation a) {
    final dt = a.startedAt ?? DateTime.now();
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return 'TODAY';
    }
    final yesterday = now.subtract(const Duration(days: 1));
    if (dt.year == yesterday.year && dt.month == yesterday.month && dt.day == yesterday.day) {
      return 'YESTERDAY';
    }
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  void _showTriggerFilter(BuildContext context) {
    final c = context.colors;
    final options = [null, ...widget.triggers.map((t) => t.id)];
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        children: options.map((id) => SimpleDialogOption(
          onPressed: () {
            Navigator.pop(ctx);
            setState(() => _filterTrigger = id);
            _load();
          },
          child: Text(id ?? 'All triggers',
            style: GoogleFonts.inter(
              fontSize: 13,
              color: _filterTrigger == id ? c.blue : c.text,
              fontWeight: _filterTrigger == id ? FontWeight.w600 : FontWeight.w400,
            )),
        )).toList(),
      ),
    );
  }

  void _showStatusFilter(BuildContext context) {
    final c = context.colors;
    final options = [null, 'completed', 'failed', 'running'];
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        children: options.map((s) => SimpleDialogOption(
          onPressed: () {
            Navigator.pop(ctx);
            setState(() => _filterStatus = s);
            _load();
          },
          child: Text(s ?? 'All status',
            style: GoogleFonts.inter(
              fontSize: 13,
              color: _filterStatus == s ? c.blue : c.text,
              fontWeight: _filterStatus == s ? FontWeight.w600 : FontWeight.w400,
            )),
        )).toList(),
      ),
    );
  }
}

// ─── Full Activation Tile (expandable) ──────────────────────────────────────

class _FullActivationTile extends StatelessWidget {
  final Activation activation;
  final bool isExpanded;
  final VoidCallback onTap;
  const _FullActivationTile({
    required this.activation, required this.isExpanded, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final a = activation;

    final statusColor = a.isCompleted ? c.green : a.isFailed ? c.red : c.blue;
    final statusIcon = a.isCompleted
        ? Icons.check_circle_rounded
        : a.isFailed
            ? Icons.error_rounded
            : Icons.sync_rounded;
    final triggerIcon = switch (a.triggerType) {
      'cron' => Icons.schedule_rounded,
      'http' => Icons.language_rounded,
      _ => Icons.bolt_rounded,
    };

    final time = a.startedAt != null
        ? '${a.startedAt!.hour.toString().padLeft(2, '0')}:${a.startedAt!.minute.toString().padLeft(2, '0')}'
        : '';

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isExpanded ? c.surfaceAlt : c.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: isExpanded ? c.borderHover : c.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Summary row
            Row(
              children: [
                Icon(triggerIcon, size: 14, color: c.textDim),
                const SizedBox(width: 6),
                Text(time,
                  style: GoogleFonts.firaCode(fontSize: 11, color: c.textMuted)),
                const SizedBox(width: 10),
                Icon(statusIcon, size: 14, color: statusColor),
                const SizedBox(width: 6),
                Text(a.durationDisplay,
                  style: GoogleFonts.firaCode(fontSize: 11, color: c.textDim)),
                const SizedBox(width: 6),
                if (a.triggerId.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: c.border.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(a.triggerId,
                      style: GoogleFonts.firaCode(fontSize: 9, color: c.textDim)),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    a.isFailed ? (a.error ?? 'Failed') : a.response,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: a.isFailed ? c.red : c.textMuted,
                    ),
                  ),
                ),
                Icon(isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 16, color: c.textDim),
              ],
            ),

            // Expanded detail
            if (isExpanded) ...[
              const SizedBox(height: 14),
              Container(height: 0.5, color: c.border),
              const SizedBox(height: 14),

              // Input message
              if (a.message.isNotEmpty) ...[
                Text('Input',
                  style: GoogleFonts.inter(
                    fontSize: 10, fontWeight: FontWeight.w600, color: c.textDim)),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: c.bg,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(a.message,
                    style: GoogleFonts.inter(fontSize: 12, color: c.text, height: 1.5)),
                ),
                const SizedBox(height: 14),
              ],

              // Response (rendered as markdown)
              if (a.response.isNotEmpty) ...[
                Text('Response',
                  style: GoogleFonts.inter(
                    fontSize: 10, fontWeight: FontWeight.w600, color: c.textDim)),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: c.bg,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: MarkdownBody(
                    data: a.response,
                    selectable: true,
                    styleSheet: MarkdownStyleSheet(
                      p: GoogleFonts.inter(fontSize: 12, color: c.text, height: 1.5),
                      code: GoogleFonts.firaCode(fontSize: 11, color: c.purple,
                          backgroundColor: c.codeBg),
                      strong: GoogleFonts.inter(
                          fontSize: 12, fontWeight: FontWeight.w600, color: c.textBright),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],

              // Error
              if (a.error != null && a.error!.isNotEmpty) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: c.red.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: c.red.withValues(alpha: 0.2)),
                  ),
                  child: Text(a.error!,
                    style: GoogleFonts.firaCode(fontSize: 11, color: c.red, height: 1.4)),
                ),
                const SizedBox(height: 14),
              ],

              // Metrics row
              Wrap(
                spacing: 16,
                children: [
                  _MetricLabel(icon: Icons.build_outlined, label: '${a.toolCallsCount} tools', c: c),
                  _MetricLabel(icon: Icons.replay_rounded, label: '${a.turnsUsed} turns', c: c),
                  _MetricLabel(icon: Icons.bolt_rounded, label: '${a.totalTokens} tokens', c: c),
                  _MetricLabel(icon: Icons.timer_outlined, label: a.durationDisplay, c: c),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── Helper Widgets ─────────────────────────────────────────────────────────

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  final AppColors c;
  const _MiniStat({required this.label, required this.value, this.color, required this.c});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(value,
            style: GoogleFonts.inter(
              fontSize: 16, fontWeight: FontWeight.w700,
              color: color ?? c.textBright)),
          const SizedBox(height: 2),
          Text(label,
            style: GoogleFonts.inter(fontSize: 10, color: c.textMuted)),
        ],
      ),
    );
  }
}

class _FilterChip extends StatefulWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _FilterChip({required this.label, required this.active, required this.onTap});

  @override
  State<_FilterChip> createState() => _FilterChipState();
}

class _FilterChipState extends State<_FilterChip> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: widget.active
                ? c.blue.withValues(alpha: 0.1)
                : _h ? c.surfaceAlt : c.surface,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: widget.active
                  ? c.blue.withValues(alpha: 0.3)
                  : c.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.label,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: widget.active ? c.blue : c.textMuted,
                )),
              const SizedBox(width: 4),
              Icon(Icons.expand_more, size: 12,
                  color: widget.active ? c.blue : c.textDim),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  final AppColors c;
  const _MetricLabel({required this.icon, required this.label, required this.c});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: c.textDim),
        const SizedBox(width: 4),
        Text(label, style: GoogleFonts.firaCode(fontSize: 10, color: c.textDim)),
      ],
    );
  }
}
