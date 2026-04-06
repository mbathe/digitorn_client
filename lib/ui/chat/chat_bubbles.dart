import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';
import '../../models/chat_message.dart';
import '../../theme/app_theme.dart';

// ─── Action button (message actions) ──────────────────────────────────────────

class _ActionBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _ActionBtn({required this.icon, required this.tooltip, required this.onTap});

  @override
  State<_ActionBtn> createState() => _ActionBtnState();
}

class _ActionBtnState extends State<_ActionBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: widget.tooltip,
    child: MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: _h ? context.colors.surfaceAlt : context.colors.surface,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: context.colors.border),
          ),
          child: Icon(widget.icon,
            size: 13,
            color: _h ? context.colors.text : context.colors.textMuted),
        ),
      ),
    ),
  );
}

// ─── Toast helper ─────────────────────────────────────────────────────────────

void showToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message,
        style: GoogleFonts.inter(fontSize: 13, color: context.colors.textBright)),
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? context.colors.surfaceAlt : context.colors.borderHover,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      margin: const EdgeInsets.all(16),
      duration: const Duration(seconds: 2),
    ),
  );
}

// All colors now come from context.colors (AppColors ThemeExtension)

// ─── Message Bubble ──────────────────────────────────────────────────────────

class ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final VoidCallback? onRetry;
  const ChatBubble({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: message,
      builder: (_, __) => message.role == MessageRole.user
          ? _UserBubble(message: message)
          : _AssistantBubble(message: message, onRetry: onRetry),
    );
  }
}

// ─── User Bubble ─────────────────────────────────────────────────────────────

class _UserBubble extends StatelessWidget {
  final ChatMessage message;
  const _UserBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isSmall = MediaQuery.of(context).size.width < 600;
    final time = '${message.createdAt.hour.toString().padLeft(2, '0')}:${message.createdAt.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: isSmall
          ? const EdgeInsets.fromLTRB(48, 4, 12, 4)
          : const EdgeInsets.fromLTRB(80, 4, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Flexible(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
                  decoration: BoxDecoration(
                    color: c.userBubbleBg,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(16),
                      topRight: Radius.circular(16),
                      bottomLeft: Radius.circular(16),
                      bottomRight: Radius.circular(4),
                    ),
                    border: Border.all(color: c.userBubbleBorder),
                  ),
                  child: SelectableText(
                    message.text,
                    style: GoogleFonts.inter(
                        fontSize: 14, color: c.text, height: 1.6),
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 3, right: 4),
            child: Text(time,
              style: GoogleFonts.firaCode(fontSize: 9, color: context.colors.textDim),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Assistant Bubble ─────────────────────────────────────────────────────────

class _AssistantBubble extends StatefulWidget {
  final ChatMessage message;
  final VoidCallback? onRetry;
  const _AssistantBubble({required this.message, this.onRetry});

  @override
  State<_AssistantBubble> createState() => _AssistantBubbleState();
}

class _AssistantBubbleState extends State<_AssistantBubble> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final isActive = message.isStreaming || message.isThinking ||
        message.toolCalls.any((t) => t.status == 'started');
    final collapsed = !isActive;
    final isSmall = MediaQuery.of(context).size.width < 600;
    final hasError = message.text.contains('**Error:**');

    // ── Build children chronologically from the timeline ───────────────
    final children = <Widget>[];

    // Group adjacent tool calls together for visual grouping
    final timeline = message.timeline;
    int i = 0;
    while (i < timeline.length) {
      final block = timeline[i];
      switch (block.type) {
        case ContentBlockType.thinking:
          if (block.thinkingActive || block.textContent.isNotEmpty) {
            children.add(_ThinkingBlock(
              text: block.textContent,
              isActive: block.thinkingActive,
              collapsed: collapsed,
            ));
          }
          i++;
          break;

        case ContentBlockType.toolCall:
          // Collect adjacent tool call blocks into a group
          final group = <ToolCall>[];
          while (i < timeline.length &&
              timeline[i].type == ContentBlockType.toolCall &&
              timeline[i].toolCall != null) {
            group.add(timeline[i].toolCall!);
            i++;
          }
          if (group.isNotEmpty) {
            children.add(_ToolCallSection(
              toolCalls: group,
              collapsed: collapsed,
            ));
            children.add(const SizedBox(height: 4));
          }
          break;

        case ContentBlockType.agentEvent:
          // Collect adjacent agent events into a group
          final events = <AgentEventData>[];
          while (i < timeline.length &&
              timeline[i].type == ContentBlockType.agentEvent &&
              timeline[i].agentEvent != null) {
            events.add(timeline[i].agentEvent!);
            i++;
          }
          if (events.isNotEmpty) {
            children.add(_AgentGroup(
              events: events,
              collapsed: collapsed,
            ));
          }
          break;

        case ContentBlockType.text:
          if (block.textContent.isNotEmpty) {
            // Add spacing before text if it follows a non-text block
            if (children.isNotEmpty) {
              children.add(const SizedBox(height: 8));
            }
            children.add(_MarkdownBody(text: block.textContent));
          }
          i++;
          break;

        case ContentBlockType.hookEvent:
          // Hook events are not rendered visually for now
          i++;
          break;
      }
    }

    // ── Streaming cursor (only when no content yet) ────────────────────
    if (message.isStreaming && message.text.isEmpty && !message.isThinking) {
      children.add(const _BlinkCursor());
    }

    // ── Token badge ────────────────────────────────────────────────────
    if (!message.isStreaming && message.outTokens > 0) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: _TokenBadge(out: message.outTokens, inT: message.inTokens),
      ));
    }

    // ── Action bar (hover to show) ───────────────────────────────────
    if (!isActive && message.text.isNotEmpty) {
      children.add(
        AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: _hovered ? 1.0 : 0.0,
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ActionBtn(
                  icon: Icons.copy_rounded,
                  tooltip: 'Copy message',
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: message.text));
                    if (context.mounted) showToast(context, 'Copied to clipboard');
                  },
                ),
                if (hasError && widget.onRetry != null) ...[
                  const SizedBox(width: 4),
                  _ActionBtn(
                    icon: Icons.refresh_rounded,
                    tooltip: 'Retry',
                    onTap: widget.onRetry!,
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: isSmall
            ? const EdgeInsets.fromLTRB(12, 4, 24, 4)
            : const EdgeInsets.fromLTRB(16, 4, 60, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}

// ─── Thinking block ──────────────────────────────────────────────────────────

class _ThinkingBlock extends StatefulWidget {
  final String text;
  final bool isActive;
  final bool collapsed;
  const _ThinkingBlock(
      {required this.text,
      required this.isActive,
      required this.collapsed});

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock> {
  bool _open = true;

  @override
  void didUpdateWidget(_ThinkingBlock old) {
    super.didUpdateWidget(old);
    if (!old.collapsed && widget.collapsed) {
      setState(() => _open = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // header row
          GestureDetector(
            onTap: () => setState(() => _open = !_open),
            child: Row(
              children: [
                if (widget.isActive)
                  SizedBox(
                    width: 10, height: 10,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: c.textDim),
                  )
                else
                  Icon(Icons.auto_awesome_outlined,
                      size: 11, color: c.textDim),
                const SizedBox(width: 7),
                Text(
                  widget.isActive ? 'Thinking…' : 'Thinking',
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      color: c.textDim,
                      fontStyle: FontStyle.italic),
                ),
                const SizedBox(width: 4),
                Icon(
                  _open ? Icons.expand_less : Icons.expand_more,
                  size: 12,
                  color: c.textDim,
                ),
              ],
            ),
          ),
          // content
          AnimatedSize(
            duration: const Duration(milliseconds: 150),
            alignment: Alignment.topCenter,
            child: _open && widget.text.isNotEmpty
                ? Container(
                    margin: const EdgeInsets.only(top: 4, left: 4),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: c.border),
                    ),
                    child: Text(
                      widget.text,
                      style: GoogleFonts.inter(
                        fontSize: 12.5,
                        color: c.textMuted,
                        height: 1.6,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

// ─── Tool Call Section (tree-based hierarchy) ───────────────────────────────

class _ToolCallSection extends StatefulWidget {
  final List<ToolCall> toolCalls;
  final bool collapsed;
  const _ToolCallSection(
      {required this.toolCalls, required this.collapsed});

  @override
  State<_ToolCallSection> createState() => _ToolCallSectionState();
}

class _ToolCallSectionState extends State<_ToolCallSection> {
  bool _showAll = false;
  final _expandedTools = <String>{};
  final _seenCompleted = <String>{};
  bool _wasCollapsed = false;

  @override
  void didUpdateWidget(_ToolCallSection old) {
    super.didUpdateWidget(old);
    // When the group transitions to collapsed (all done), close all previews
    if (widget.collapsed && !_wasCollapsed) {
      _expandedTools.clear();
    }
    _wasCollapsed = widget.collapsed;

    // Auto-expand tools that just completed (not seen before)
    if (!widget.collapsed) {
      for (final t in widget.toolCalls) {
        if (t.status != 'started' && !_seenCompleted.contains(t.id)) {
          _seenCompleted.add(t.id);
          _expandedTools.add(t.id);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tools = widget.toolCalls;
    if (tools.isEmpty) return const SizedBox.shrink();

    final hasRunning = tools.any((t) => t.status == 'started');
    final hasFailed = tools.any((t) => t.status == 'failed');
    final isDone = !hasRunning;
    final isSingle = tools.length == 1;

    // Status color for the group tree line
    final groupColor = hasRunning
        ? c.blue
        : hasFailed
            ? c.red
            : c.green;

    final summary = _buildGroupSummary(tools);
    final maxVisible = _showAll ? tools.length : 3;
    final visibleTools = tools.take(maxVisible).toList();
    final hidden = tools.length - maxVisible;

    // Tree line width
    const double lineX = 6; // X position of vertical line from left edge
    const double contentLeft = 20; // left padding for content after tree

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Summary header ──────────────────────────────────────────
        if (!isSingle)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                if (hasRunning)
                  SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.2, color: c.blue),
                  )
                else if (hasFailed)
                  Text('✗', style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700, color: c.red))
                else
                  Text('✓', style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700, color: c.green)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(summary,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isDone ? c.textMuted : c.text,
                    ),
                  ),
                ),
              ],
            ),
          ),

        // ── Tree-connected tool rows with continuous vertical line ──
        if (!isSingle)
          for (int i = 0; i < visibleTools.length; i++)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Tree gutter: vertical line + branch
                  CustomPaint(
                    size: const Size(contentLeft, double.infinity),
                    painter: _TreeLinePainter(
                      isFirst: i == 0,
                      isLast: i == visibleTools.length - 1 && hidden <= 0,
                      lineX: lineX,
                      color: groupColor.withValues(alpha: 0.5),
                    ),
                  ),
                  // Tool content
                  Expanded(
                    child: _buildToolContent(
                      context,
                      tool: visibleTools[i],
                      c: c,
                    ),
                  ),
                ],
              ),
            ),

        // Single tool (no tree)
        if (isSingle)
          for (int i = 0; i < visibleTools.length; i++)
            _buildToolContent(context, tool: visibleTools[i], c: c),

        // ── "Show N more" link ──────────────────────────────────────
        if (hidden > 0 && !_showAll)
          Padding(
            padding: EdgeInsets.only(left: isSingle ? 0 : contentLeft, top: 4, bottom: 2),
            child: GestureDetector(
              onTap: () => setState(() => _showAll = true),
              child: Text(
                'Show $hidden more',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: c.blue,
                  decoration: TextDecoration.underline,
                  decorationColor: c.blue,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildToolContent(
    BuildContext context, {
    required ToolCall tool,
    required AppColors c,
  }) {
    final isRunning = tool.status == 'started';
    final isError = tool.status == 'failed';
    final isDone = !isRunning;
    final isExpanded = _expandedTools.contains(tool.id);

    final label = tool.displayLabel;
    final detail = tool.displayDetail;
    final preview = isDone ? _buildPreview(tool) : null;
    final hasPreview = preview != null && preview.isNotEmpty;

    final textColor = isRunning ? c.text : c.text;
    final detailColor = isRunning ? c.textMuted : c.textMuted;
    final brief = isDone ? _briefResult(tool) : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Tool label row ──────────────────────────────────────────
        GestureDetector(
          onTap: hasPreview
              ? () => setState(() {
                    if (isExpanded) {
                      _expandedTools.remove(tool.id);
                    } else {
                      _expandedTools.add(tool.id);
                    }
                  })
              : null,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                // Status icon
                if (isRunning)
                  SizedBox(
                    width: 12, height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.2, color: c.blue),
                  )
                else
                  Icon(
                    isError ? Icons.close_rounded : Icons.check_rounded,
                    size: 12,
                    color: isError ? c.red : c.green,
                  ),
                const SizedBox(width: 6),
                // Label
                Text(label,
                  style: GoogleFonts.inter(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  )),
                // Detail (path, command, etc.)
                if (detail.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(detail,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: GoogleFonts.firaCode(
                        fontSize: 11, color: detailColor)),
                  ),
                ],
                // Brief result badge (lines, exit code, matches, etc.)
                if (brief.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(brief,
                    style: GoogleFonts.firaCode(
                      fontSize: 10, color: c.textMuted)),
                ],
              ],
            ),
          ),
        ),

        // ── Preview (expanded) — fine line aligned with status icon ──
        AnimatedSize(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: isExpanded && hasPreview
              ? Padding(
                  // left: 6px = center of the 12px status icon
                  padding: const EdgeInsets.only(left: 6, top: 1, bottom: 4),
                  child: Container(
                    padding: const EdgeInsets.only(left: 14),
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(
                          color: isError
                              ? c.red.withValues(alpha: 0.4)
                              : c.border,
                          width: 1,
                        ),
                      ),
                    ),
                    child: _PreviewTree(lines: preview!),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  /// Build a Claude Code-style summary: "Read 3 files" / "Ran 5 commands"
  String _buildGroupSummary(List<ToolCall> tools) {
    final counts = <String, int>{};
    for (final t in tools) {
      final verb = t.displayLabel;
      counts[verb] = (counts[verb] ?? 0) + 1;
    }

    final parts = counts.entries.map((e) {
      final verb = e.key;
      final n = e.value;
      if (n == 1) return verb;

      // Natural pluralization based on verb type
      final lower = verb.toLowerCase();
      if (lower == 'bash' || lower == 'shell' || lower == 'execute') {
        return 'Ran $n commands';
      }
      if (lower == 'read') return 'Read $n files';
      if (lower == 'write') return 'Wrote $n files';
      if (lower == 'edit') return 'Edited $n files';
      if (lower == 'list' || lower == 'glob') return 'Listed $n directories';
      if (lower == 'grep' || lower == 'search') return '$n searches';
      return '$verb x$n';
    });
    return parts.join(', ');
  }
}

// ─── Agent group (like CLI: ● 3 Sub agents ├ ● Agent ├ ● Agent └ ● Agent) ───

class _AgentGroup extends StatefulWidget {
  final List<AgentEventData> events;
  final bool collapsed;
  const _AgentGroup({required this.events, required this.collapsed});

  @override
  State<_AgentGroup> createState() => _AgentGroupState();
}

class _AgentGroupState extends State<_AgentGroup> {
  bool _open = true;

  @override
  void didUpdateWidget(_AgentGroup old) {
    super.didUpdateWidget(old);
    if (!old.collapsed && widget.collapsed) setState(() => _open = false);
  }

  @override
  Widget build(BuildContext context) {
    final events = widget.events;
    final running = events.where((e) => e.status == 'spawned' || e.status == 'running').length;
    final done    = events.where((e) => e.status == 'completed').length;
    final failed  = events.where((e) => e.status == 'failed').length;
    final isActive = running > 0;

    final c = context.colors;

    // Header text (like CLI)
    final Color headerColor;
    final String headerText;
    if (isActive) {
      headerColor = c.cyan;
      final parts = <String>[];
      if (done > 0) parts.add('$done done');
      if (failed > 0) parts.add('$failed failed');
      headerText = 'Running $running sub-agent${running > 1 ? 's' : ''}…'
          '${parts.isNotEmpty ? ' (${parts.join(', ')})' : ''}';
    } else if (failed > 0 && done == 0) {
      headerColor = c.red;
      headerText = '${events.length} sub-agent${events.length > 1 ? 's' : ''} failed';
    } else if (failed > 0) {
      headerColor = c.orange;
      headerText = '${events.length} sub-agents ($done done, $failed failed)';
    } else {
      headerColor = c.green;
      headerText = '${events.length} sub-agent${events.length > 1 ? 's' : ''} completed';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          GestureDetector(
            onTap: () => setState(() => _open = !_open),
            child: Row(
              children: [
                _BulletDot(
                  color: headerColor,
                  running: isActive,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(headerText,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: headerColor,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  _open ? Icons.expand_less : Icons.expand_more,
                  size: 13, color: c.textDim,
                ),
              ],
            ),
          ),
          // Agent rows with tree connectors
          AnimatedSize(
            duration: const Duration(milliseconds: 150),
            alignment: Alignment.topCenter,
            child: _open
                ? Padding(
                    padding: const EdgeInsets.only(left: 3, top: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (int i = 0; i < events.length; i++)
                          _AgentRow(
                            event: events[i],
                            connector: i == events.length - 1 ? '╰─' : '├─',
                          ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _AgentRow extends StatelessWidget {
  final AgentEventData event;
  final String connector;
  const _AgentRow({required this.event, this.connector = '├─'});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final statusColor = _agentColorFromTheme(event.status, colors);
    final icon = _agentIcon(event.status);
    final name = event.specialist.isNotEmpty
        ? event.specialist
        : event.agentId.isNotEmpty
            ? event.agentId
            : 'Agent';

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Tree connector
          SizedBox(
            width: 24,
            child: Text(connector,
              style: GoogleFonts.firaCode(
                fontSize: 12, color: colors.textDim, height: 1.3)),
          ),
          // Status icon
          Text(icon, style: TextStyle(
            fontSize: 11, color: statusColor, fontWeight: FontWeight.bold)),
          const SizedBox(width: 5),
          // Agent name
          Text(name,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: statusColor,
            ),
          ),
          // Task description
          if (event.task.isNotEmpty) ...[
            Text(': ', style: GoogleFonts.inter(fontSize: 12, color: colors.textDim)),
            Expanded(
              child: Text(
                event.task,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: GoogleFonts.inter(fontSize: 12, color: colors.textMuted),
              ),
            ),
          ] else
            const Spacer(),
          // Duration
          if (event.duration > 0)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                '${event.duration.toStringAsFixed(1)}s',
                style: GoogleFonts.firaCode(fontSize: 10, color: colors.textDim),
              ),
            ),
          // Preview snippet
          if (event.preview.isNotEmpty && event.status == 'completed') ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                event.preview,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: GoogleFonts.inter(fontSize: 10, color: colors.textDim),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _agentIcon(String status) => switch (status) {
      'spawned'   => '◌',
      'running'   => '●',
      'completed' => '✓',
      'failed'    => '✗',
      'cancelled' => '○',
      _           => '●',
    };

Color _agentColorFromTheme(String status, AppColors c) => switch (status) {
      'spawned'   => c.orange,
      'running'   => c.cyan,
      'completed' => c.green,
      'failed'    => c.red,
      'cancelled' => c.textDim,
      _           => c.blue,
    };

// ─── Markdown body ────────────────────────────────────────────────────────────

class _MarkdownBody extends StatelessWidget {
  final String text;
  const _MarkdownBody({required this.text});

  @override
  Widget build(BuildContext context) {
    // Convert single \n to hard break (two trailing spaces + \n)
    // but preserve \n\n as paragraph break and code blocks
    final data = _convertLineBreaks(text);

    return MarkdownBody(
      data: data,
      selectable: true,
      onTapLink: (text, href, title) {
        // Handle file links or URLs
        if (href != null && href.startsWith('http')) {
          // Could open in browser
        }
      },
      builders: {
        'code': _CodeBlockBuilder(),
      },
      styleSheet: MarkdownStyleSheet(
        p: GoogleFonts.inter(fontSize: 14, color: context.colors.text, height: 1.65),
        h1: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700, color: context.colors.textBright),
        h2: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600, color: context.colors.textBright),
        h3: GoogleFonts.inter(fontSize: 14.5, fontWeight: FontWeight.w600, color: context.colors.text),
        code: GoogleFonts.firaCode(
            fontSize: 12.5, color: context.colors.purple,
            backgroundColor: context.colors.codeBg),
        codeblockDecoration: BoxDecoration(),
        codeblockPadding: EdgeInsets.zero,
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: context.colors.border, width: 2.5)),
          color: context.colors.surface,
        ),
        blockquotePadding: const EdgeInsets.only(left: 14, top: 2, bottom: 2),
        blockquote: GoogleFonts.inter(
            fontSize: 13.5, color: context.colors.textMuted,
            fontStyle: FontStyle.italic),
        strong: GoogleFonts.inter(
            fontSize: 14, fontWeight: FontWeight.w600, color: context.colors.textBright),
        listBullet: GoogleFonts.inter(fontSize: 14, color: context.colors.textMuted),
      ),
    );
  }
}

// ─── Code block with copy button + language header ───────────────────────────

class _CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    // Only handle fenced code blocks (not inline code)
    if (element.tag != 'code') return null;
    final parent = element.attributes['class'];
    // Inline code → skip (let default handle it)
    if (parent == null && !element.textContent.contains('\n')) return null;

    final lang = parent?.replaceFirst('language-', '') ?? '';
    final code = element.textContent.trimRight();

    return _CodeBlock(language: lang, code: code);
  }
}

class _CodeBlock extends StatefulWidget {
  final String language;
  final String code;
  const _CodeBlock({required this.language, required this.code});

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  bool _copied = false;

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.code));
    if (context.mounted) showToast(context, 'Copied to clipboard');
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: c.codeBlockBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header: language + copy button
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: c.codeBlockHeader,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(7),
                topRight: Radius.circular(7),
              ),
            ),
            child: Row(
              children: [
                if (widget.language.isNotEmpty)
                  Text(widget.language,
                    style: GoogleFonts.firaCode(
                      fontSize: 11, color: context.colors.textMuted),
                  ),
                const Spacer(),
                GestureDetector(
                  onTap: _copy,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _copied ? Icons.check_rounded : Icons.copy_rounded,
                        size: 13,
                        color: _copied ? c.green : c.textMuted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _copied ? 'Copied' : 'Copy',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: _copied ? c.green : c.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Code content with syntax highlighting
          Padding(
            padding: const EdgeInsets.all(12),
            child: Builder(builder: (context) {
              final isDark = Theme.of(context).brightness == Brightness.dark;
              // Use theme-appropriate syntax colors, override background to transparent
              final syntaxTheme = Map<String, TextStyle>.from(
                isDark ? atomOneDarkTheme : atomOneLightTheme,
              );
              syntaxTheme['root'] = (syntaxTheme['root'] ?? const TextStyle())
                  .copyWith(backgroundColor: Colors.transparent);
              return HighlightView(
                widget.code,
                language: widget.language.isNotEmpty ? widget.language : 'plaintext',
                theme: syntaxTheme,
                textStyle: GoogleFonts.firaCode(fontSize: 12.5, height: 1.5),
                padding: EdgeInsets.zero,
              );
            }),
          ),
        ],
      ),
    );
  }
}

/// Convert single newlines to Markdown hard breaks (trailing `  \n`)
/// while preserving code blocks and paragraph breaks (`\n\n`).
String _convertLineBreaks(String text) {
  final buf = StringBuffer();
  final lines = text.split('\n');
  bool inCodeBlock = false;

  for (int i = 0; i < lines.length; i++) {
    final line = lines[i];

    // Track code block fences
    if (line.trimLeft().startsWith('```')) {
      inCodeBlock = !inCodeBlock;
      buf.writeln(line);
      continue;
    }

    // Inside code blocks — preserve as-is
    if (inCodeBlock) {
      buf.writeln(line);
      continue;
    }

    // Last line — no trailing newline
    if (i == lines.length - 1) {
      buf.write(line);
      continue;
    }

    // Next line is empty → paragraph break (keep \n\n)
    if (i + 1 < lines.length && lines[i + 1].trim().isEmpty) {
      buf.writeln(line);
      continue;
    }

    // Empty line itself → preserve
    if (line.trim().isEmpty) {
      buf.writeln(line);
      continue;
    }

    // List items, headers, etc. → preserve normal newline
    if (line.trimLeft().startsWith('- ') ||
        line.trimLeft().startsWith('* ') ||
        line.trimLeft().startsWith('#') ||
        RegExp(r'^\d+\.\s').hasMatch(line.trimLeft())) {
      buf.writeln(line);
      continue;
    }

    // Normal line followed by content → add hard break (two spaces)
    buf.writeln('$line  ');
  }

  return buf.toString();
}

// ─── Preview tree ─────────────────────────────────────────────────────────────
// The old client's ⎿ tree block

class _PreviewLine {
  final String text;
  final String type; // 'add' 'del' 'context' 'output' 'error' 'summary'
  final int lineNo; // 0 = no line number
  const _PreviewLine(this.text, this.type, {this.lineNo = 0});
}

class _PreviewTree extends StatelessWidget {
  final List<_PreviewLine> lines;
  const _PreviewTree({required this.lines});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final maxLines = lines.length > 20 ? 20 : lines.length;
    // Check if this preview has diff or code lines (for IDE-style rendering)
    final hasDiff = lines.any((l) => l.type == 'add' || l.type == 'del');
    final hasCode = lines.any((l) => l.type == 'code');
    final hasLineNos = hasDiff || hasCode;
    // Max line number width
    final maxLineNo = lines.where((l) => l.lineNo > 0).fold<int>(0,
        (m, l) => l.lineNo > m ? l.lineNo : m);
    final lineNoWidth = maxLineNo > 0 ? '${maxLineNo}'.length : 0;

    if (hasLineNos) {
      // IDE-style rendering with line numbers
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (int i = 0; i < maxLines; i++)
              _buildDiffLine(c, lines[i], lineNoWidth),
          ],
        ),
      );
    }

    // Standard output rendering (no diff)
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < maxLines; i++)
          _buildOutputLine(c, lines[i]),
      ],
    );
  }

  /// IDE-style line with optional colored background, gutter, line number
  Widget _buildDiffLine(AppColors c, _PreviewLine line, int lineNoWidth) {
    final isDiff = line.type == 'add' || line.type == 'del';
    final isAdd = line.type == 'add';
    final isDel = line.type == 'del';
    final isCode = line.type == 'code';
    final isSummary = line.type == 'summary';

    // Background color: full row colored for add/del, transparent for code/context
    final bgColor = isAdd
        ? c.green.withValues(alpha: 0.10)
        : isDel
            ? c.red.withValues(alpha: 0.10)
            : Colors.transparent;

    // Text color
    final textColor = isAdd
        ? c.green
        : isDel
            ? c.red
            : isSummary
                ? c.textMuted
                : c.text;

    // Clean text: remove leading +/- if present (we show it in gutter)
    var displayText = line.text;
    if (isDiff && displayText.isNotEmpty && (displayText[0] == '+' || displayText[0] == '-')) {
      displayText = displayText.substring(1);
    }

    if (isSummary) {
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          line.text,
          style: GoogleFonts.firaCode(fontSize: 11, color: c.textMuted, height: 1.5),
        ),
      );
    }

    return Container(
      color: bgColor,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Line number
          if (line.lineNo > 0)
            SizedBox(
              width: (lineNoWidth * 8.0) + 8,
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  '${line.lineNo}'.padLeft(lineNoWidth),
                  textAlign: TextAlign.right,
                  style: GoogleFonts.firaCode(
                    fontSize: 10.5, height: 1.6,
                    color: isDiff ? textColor.withValues(alpha: 0.5) : c.textDim,
                  ),
                ),
              ),
            ),
          // Gutter sign (+/-) — only for diff lines, not for plain code
          if (isDiff)
            Container(
              width: 16,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border(
                  right: BorderSide(
                    color: (isAdd ? c.green : c.red).withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
              ),
              child: Text(
                isAdd ? '+' : '-',
                style: GoogleFonts.firaCode(
                  fontSize: 11, height: 1.6,
                  fontWeight: FontWeight.w700,
                  color: isAdd ? c.green : c.red,
                ),
              ),
            )
          else if (!isCode)
            Container(
              width: 16,
              decoration: BoxDecoration(
                border: Border(
                  right: BorderSide(color: c.border.withValues(alpha: 0.3), width: 1),
                ),
              ),
            ),
          // Separator between gutter and code
          SizedBox(width: isCode ? 8 : 6),
          // Code content
          Expanded(
            child: Text(
              displayText,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.firaCode(
                fontSize: 11, height: 1.6,
                color: textColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Standard output line (non-diff)
  Widget _buildOutputLine(AppColors c, _PreviewLine line) {
    final color = switch (line.type) {
      'error'   => c.red,
      'summary' => c.textMuted,
      'output'  => c.text,
      _ => c.textMuted,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 0.5),
      child: Text(
        line.text,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.firaCode(fontSize: 11, height: 1.5, color: color),
      ),
    );
  }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Strip daemon-injected line numbers like "  1│code" from content strings
String _stripLineNos(String text) {
  if (text.isEmpty) return text;
  final lines = text.split('\n');
  final pattern = RegExp(r'^\s*\d+│');
  final hasLineNos = lines.where((l) => l.trim().isNotEmpty).take(3)
      .every((l) => pattern.hasMatch(l));
  if (!hasLineNos) return text;
  return lines.map((l) {
    final match = RegExp(r'^\s*\d+│(.*)$').firstMatch(l);
    return match != null ? match.group(1)! : l;
  }).join('\n');
}

/// Brief result summary (like TUI: "3 lines", "exit 0 · first line", "5 matches")
String _briefResult(ToolCall t) {
  if (t.result == null) return '';
  final r = t.result;
  if (r is! Map) return r is String && r.length < 60 ? r : '';

  final data = r;

  // Parallel results: "3 done, 1 failed"
  if (data.containsKey('results') && data['results'] is List) {
    final results = data['results'] as List;
    final ok = results.where((r) => r is Map && r['success'] == true).length;
    final fail = results.length - ok;
    if (fail > 0 && ok > 0) return '$ok done, $fail failed';
    if (fail > 0 && ok == 0) return '$fail failed';
    return '${results.length} done';
  }

  // Read: total_lines or lines count
  if (data.containsKey('total_lines')) return '${data['total_lines']} lines';
  if (data.containsKey('lines_written')) return '${data['lines_written']} lines written';

  // Bash/shell: exit_code + first output line
  if (data.containsKey('exit_code')) {
    final code = data['exit_code'];
    final out = (data['output'] as String? ?? '').trim();
    final first = out.isNotEmpty ? out.split('\n').first : '';
    final preview = first.length > 40 ? '${first.substring(0, 40)}…' : first;
    return preview.isNotEmpty ? 'exit $code · $preview' : 'exit $code';
  }

  // Grep/search: match count
  if (data.containsKey('count') && data.containsKey('matches')) {
    final count = data['count'];
    final matches = data['matches'];
    if (matches is List) {
      final files = <String>{};
      for (final m in matches) {
        if (m is Map && m['file'] != null) files.add(m['file'].toString());
      }
      return files.length > 1 ? '$count matches in ${files.length} files' : '$count matches';
    }
    return '$count matches';
  }
  if (data.containsKey('count')) return '${data['count']} results';

  // Glob/find: files list
  if (data.containsKey('files')) {
    final files = data['files'];
    if (files is List) return '${files.length} files';
  }

  // Lines / rows
  for (final k in ['lines', 'rows']) {
    if (data.containsKey(k)) return '${data[k]} $k';
  }

  // Success/error
  if (data['success'] == true) return '✓';
  if (data['success'] == false) {
    final err = data['error']?.toString() ?? 'failed';
    return err.length > 40 ? '${err.substring(0, 40)}…' : err;
  }

  return '';
}

/// Build preview lines for tool result — generic, adapts to any module.
/// Format matches Claude Code:
///   ⎿  Summary line (e.g. "Wrote 495 lines to path")
///        1  first line of content
///        2  second line
///      … +N lines
List<_PreviewLine>? _buildPreview(ToolCall t) {
  if (t.result == null && t.error == null) return null;

  // ── Error ──────────────────────────────────────────────────────────
  if (t.status == 'failed') {
    final msg = t.error ?? (t.result is Map ? t.result['error']?.toString() : null) ?? 'Error';
    return msg.split('\n').take(5).map((l) => _PreviewLine(l, 'error')).toList();
  }

  final r = t.result;
  if (r == null) return null;

  // ── Parallel sub-results (run_parallel) ────────────────────────────
  if (r is Map && r.containsKey('results') && r['results'] is List) {
    final results = r['results'] as List;
    final lines = <_PreviewLine>[];
    for (int i = 0; i < results.length && i < 10; i++) {
      final sub = results[i];
      if (sub is! Map) continue;
      final ok = sub['success'] == true;
      final icon = ok ? '✓' : '✗';
      final label = sub['label'] as String? ?? sub['name'] as String? ?? 'action';
      final detail = sub['detail'] as String? ?? '';
      final err = sub['error'] as String? ?? '';
      final brief = ok ? _subBrief(sub) : err;
      final text = detail.isNotEmpty
          ? '$icon $label($detail)${brief.isNotEmpty ? '  $brief' : ''}'
          : '$icon $label${brief.isNotEmpty ? '  $brief' : ''}';
      lines.add(_PreviewLine(text, ok ? 'output' : 'error'));
    }
    if (results.length > 10) {
      lines.add(_PreviewLine('… +${results.length - 10} more', 'summary'));
    }
    return lines.isEmpty ? null : lines;
  }

  // String result → show directly
  if (r is String) {
    if (r.isEmpty) return null;
    return _truncatedLines(r, 'output');
  }

  if (r is! Map) return null;
  final data = r as Map;
  final lines = <_PreviewLine>[];

  // ── Summary line first (like Claude Code "Wrote N lines to path") ──
  final summary = _buildSummaryLine(t, data);
  if (summary != null) lines.add(_PreviewLine(summary, 'summary'));

  // ── Diff (edit) with line numbers ───────────────────────────────────
  if (data.containsKey('diff')) {
    final diff = _stripLineNos((data['diff'] as String? ?? '').trim());
    if (diff.isNotEmpty) {
      final allLines = diff.split('\n');
      int addLineNo = 1;
      int delLineNo = 1;
      for (final l in allLines.take(14)) {
        if (l.startsWith('+')) {
          lines.add(_PreviewLine(l, 'add', lineNo: addLineNo++));
        } else if (l.startsWith('-')) {
          lines.add(_PreviewLine(l, 'del', lineNo: delLineNo++));
        } else {
          lines.add(_PreviewLine(l, 'context', lineNo: addLineNo++));
          delLineNo++;
        }
      }
      if (allLines.length > 14) {
        lines.add(_PreviewLine('… +${allLines.length - 14} lines', 'summary'));
      }
      return lines;
    }
  }

  // ── Content (write/read) — IDE-style with line numbers ─────────────
  final lower = t.name.toLowerCase();
  final isWrite = lower.contains('write') || lower.contains('create');
  final isRead = lower.contains('read') || lower.contains('glob') || lower.contains('find');
  if (data.containsKey('content')) {
    final content = _stripLineNos((data['content'] as String? ?? '').trim());
    if (content.isNotEmpty) {
      final allLines = content.split('\n');
      final maxPreview = 12;
      for (int i = 0; i < allLines.length && i < maxPreview; i++) {
        if (isWrite) {
          lines.add(_PreviewLine('+${allLines[i]}', 'add', lineNo: i + 1));
        } else {
          lines.add(_PreviewLine(allLines[i], 'code', lineNo: i + 1));
        }
      }
      if (allLines.length > maxPreview) {
        lines.add(_PreviewLine('… +${allLines.length - maxPreview} lines', 'summary'));
      }
      return lines.isEmpty ? null : lines;
    }
  }

  // ── Output (bash, shell, any command) — IDE-style with line numbers ─
  if (data.containsKey('output') || data.containsKey('stderr')) {
    final out = _stripLineNos((data['output'] as String? ?? '').trim());
    final stderr = (data['stderr'] as String? ?? '').trim();

    // Stdout lines with line numbers
    if (out.isNotEmpty) {
      final allLines = out.split('\n');
      final maxPreview = 12;
      for (int i = 0; i < allLines.length && i < maxPreview; i++) {
        lines.add(_PreviewLine(allLines[i], 'code', lineNo: i + 1));
      }
      if (allLines.length > maxPreview) {
        lines.add(_PreviewLine('… +${allLines.length - maxPreview} lines', 'summary'));
      }
    }

    // Stderr lines (red, no line numbers)
    if (stderr.isNotEmpty) {
      for (final l in stderr.split('\n').take(6)) {
        lines.add(_PreviewLine(l, 'error'));
      }
    }

    return lines.isEmpty ? null : lines;
  }

  // ── Stderr only ───────────────────────────────────────────────────
  if (data.containsKey('stderr')) {
    final err = (data['stderr'] as String? ?? '').trim();
    if (err.isNotEmpty) {
      for (final l in err.split('\n').take(4)) {
        lines.add(_PreviewLine(l, 'error'));
      }
    }
  }

  // ── Matches (grep, search) ─────────────────────────────────────────
  if (data.containsKey('matches')) {
    final matches = data['matches'];
    if (matches is List && matches.isNotEmpty) {
      for (final m in matches.take(6)) {
        if (m is Map) {
          lines.add(_PreviewLine(
            '${m['file'] ?? ''}:${m['line'] ?? ''}  ${m['text'] ?? ''}', 'output'));
        } else {
          lines.add(_PreviewLine(m.toString(), 'output'));
        }
      }
      if (matches.length > 6) {
        lines.add(_PreviewLine('… +${matches.length - 6} more', 'summary'));
      }
    }
  }

  // ── Files list (glob, find) ────────────────────────────────────────
  if (data.containsKey('files')) {
    final files = data['files'];
    if (files is List && files.isNotEmpty) {
      for (final f in files.take(6)) {
        lines.add(_PreviewLine(f.toString(), 'output'));
      }
      if (files.length > 6) {
        lines.add(_PreviewLine('… +${files.length - 6} more', 'summary'));
      }
    }
  }

  // ── Results list (web search, etc.) ────────────────────────────────
  if (data.containsKey('results')) {
    final results = data['results'];
    if (results is List && results.isNotEmpty) {
      for (final r in results.take(6)) {
        if (r is Map) {
          final title = r['title'] ?? r['name'] ?? r['url'] ?? '';
          lines.add(_PreviewLine(title.toString(), 'output'));
        } else {
          lines.add(_PreviewLine(r.toString(), 'output'));
        }
      }
      if (results.length > 6) {
        lines.add(_PreviewLine('… +${results.length - 6} more', 'summary'));
      }
    }
  }

  // ── Error field inside result ──────────────────────────────────────
  if (lines.isEmpty && data.containsKey('error') && data['error'] != null) {
    final err = data['error'].toString();
    return err.split('\n').take(4).map((l) => _PreviewLine(l, 'error')).toList();
  }

  // ── Generic: any remaining string values ───────────────────────────
  if (lines.isEmpty) {
    // Try to show something useful from any string field
    for (final key in ['message', 'text', 'data', 'body', 'response']) {
      if (data.containsKey(key) && data[key] is String) {
        final v = (data[key] as String).trim();
        if (v.isNotEmpty) return _truncatedLines(v, 'output');
      }
    }
  }

  return lines.isEmpty ? null : lines;
}

/// Build a summary line for the tool result (like "Wrote 495 lines to path")
String? _buildSummaryLine(ToolCall t, Map data) {
  final path = data['path'] as String? ?? t.params['path'] as String? ?? '';
  final shortPath = path.length > 50
      ? '…/${path.replaceAll('\\', '/').split('/').last}'
      : path;

  // Write
  if (data.containsKey('lines_written')) {
    return 'Wrote ${data['lines_written']} lines${shortPath.isNotEmpty ? ' to $shortPath' : ''}';
  }
  if (data.containsKey('chars_written')) {
    return 'Wrote ${data['chars_written']} chars${shortPath.isNotEmpty ? ' to $shortPath' : ''}';
  }

  // Read
  if (data.containsKey('total_lines')) {
    return 'Read ${data['total_lines']} lines${shortPath.isNotEmpty ? ' from $shortPath' : ''}';
  }

  // Edit
  if (data.containsKey('diff') && data.containsKey('path')) {
    return 'Edited $shortPath';
  }

  // Bash
  if (data.containsKey('exit_code')) {
    final code = data['exit_code'];
    return 'Exit code $code';
  }

  return null;
}

/// Brief for a parallel sub-result
String _subBrief(Map sub) {
  final data = sub['data'] ?? sub['result'];
  if (data is Map) {
    if (data.containsKey('total_lines')) return '${data['total_lines']} lines';
    if (data.containsKey('count')) return '${data['count']} results';
    if (data.containsKey('exit_code')) return 'exit ${data['exit_code']}';
    if (data.containsKey('lines_written')) return '${data['lines_written']} written';
  }
  return '';
}

List<_PreviewLine> _truncatedLines(String text, String type, {int max = 6}) {
  final allLines = text.split('\n');
  final lines = allLines.take(max).map((l) => _PreviewLine(l, type)).toList();
  if (allLines.length > max) {
    lines.add(_PreviewLine('… +${allLines.length - max} lines', 'summary'));
  }
  return lines;
}

// ─── Primitive widgets ────────────────────────────────────────────────────────

/// Paints a continuous vertical tree line with a horizontal branch.
/// For the first item: line goes from center to bottom + branch right.
/// For middle items: line goes top to bottom + branch right.
/// For the last item: line goes top to center + branch right.
class _TreeLinePainter extends CustomPainter {
  final bool isFirst;
  final bool isLast;
  final double lineX;
  final Color color;

  _TreeLinePainter({
    required this.isFirst,
    required this.isLast,
    required this.lineX,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final midY = 12.0; // Vertical center of the tool label row

    // Vertical line segment
    final topY = isFirst ? midY : 0.0;
    final bottomY = isLast ? midY : size.height;
    canvas.drawLine(Offset(lineX, topY), Offset(lineX, bottomY), paint);

    // Horizontal branch from vertical line to content
    canvas.drawLine(Offset(lineX, midY), Offset(lineX + 10, midY), paint);
  }

  @override
  bool shouldRepaint(_TreeLinePainter old) =>
      isFirst != old.isFirst || isLast != old.isLast || color != old.color;
}

class _BulletDot extends StatefulWidget {
  final Color color;
  final bool running;
  const _BulletDot({required this.color, required this.running});

  @override
  State<_BulletDot> createState() => _BulletDotState();
}

class _BulletDotState extends State<_BulletDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));
    if (widget.running) _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_BulletDot old) {
    super.didUpdateWidget(old);
    if (widget.running && !_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    } else if (!widget.running && _ctrl.isAnimating) {
      _ctrl.stop();
      _ctrl.value = 1;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: widget.running
          ? Tween(begin: 0.3, end: 1.0).animate(_ctrl)
          : const AlwaysStoppedAnimation(1.0),
      child: Text(
        '●',
        style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: widget.color,
            height: 1.4),
      ),
    );
  }
}

class _BlinkCursor extends StatefulWidget {
  const _BlinkCursor();

  @override
  State<_BlinkCursor> createState() => _BlinkCursorState();
}

class _BlinkCursorState extends State<_BlinkCursor>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = context.colors.textMuted;
    return SizedBox(
      height: 18,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          return AnimatedBuilder(
            animation: _ctrl,
            builder: (context, child) {
              // Each dot is offset by 0.2 in the animation cycle (0.0, 0.2, 0.4)
              // giving a sequential wave pattern.
              final delay = i * 0.2;
              final t = (_ctrl.value - delay) % 1.0;
              // Bounce up during the first third of each dot's local cycle
              final bounce = t < 0.33 ? math.sin(t / 0.33 * math.pi) * 4.0 : 0.0;
              final opacity = t < 0.33 ? 0.4 + 0.5 * math.sin(t / 0.33 * math.pi) : 0.4;
              return Padding(
                padding: EdgeInsets.only(
                  left: i == 0 ? 0 : 3,
                ),
                child: Transform.translate(
                  offset: Offset(0, -bounce),
                  child: Opacity(
                    opacity: opacity,
                    child: child,
                  ),
                ),
              );
            },
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _TokenBadge extends StatelessWidget {
  final int out;
  final int inT;
  const _TokenBadge({required this.out, required this.inT});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bolt, size: 10, color: c.textMuted),
          const SizedBox(width: 4),
          Text(
            inT > 0 ? '$inT → $out tokens' : '$out tokens',
            style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted),
          ),
        ],
      ),
    );
  }
}

// Extension helper
extension _IterableExtension<T> on Iterable<T> {
  List<T> takeLast(int n) {
    final list = toList();
    return list.sublist(list.length > n ? list.length - n : 0);
  }
}
