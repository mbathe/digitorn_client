import 'dart:async';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';
import '../../main.dart' show AppState;
import '../../models/chat_message.dart';
import '../../services/session_service.dart';
import '../../services/workspace_module.dart';
import '../../services/workspace_service.dart';
import '../../theme/app_theme.dart';
import '../workspace/diff/line_diff.dart' as diff_lib;
import '../workspace/diff/unified_diff.dart';
import '../../widgets_v1/dispatcher.dart' as widgets_disp;
import '../../widgets_v1/host.dart' as widgets_host;
import '../../widgets_v1/service.dart' as widgets_service;
import 'package:provider/provider.dart';

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
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _h ? c.surfaceAlt : c.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _h ? c.borderHover : c.border,
              ),
            ),
            child: Icon(
              widget.icon,
              size: 16,
              color: _h ? c.textBright : c.text,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Toast helper ─────────────────────────────────────────────────────────────

void showToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message,
        style: GoogleFonts.inter(fontSize: 13, color: context.colors.textBright)),
      backgroundColor: context.colors.surfaceAlt,
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

  /// True when the previous message in the list has the same role —
  /// enables visual message-grouping (Claude / ChatGPT style) by
  /// tightening the vertical spacing between adjacent turns from
  /// the same author. False at the start of a turn, on role switch,
  /// and on the very first message of a session.
  final bool isGroupedWithPrev;

  const ChatBubble({
    super.key,
    required this.message,
    this.onRetry,
    this.isGroupedWithPrev = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: message,
      builder: (_, _) => switch (message.role) {
        MessageRole.user => _UserBubble(
            message: message,
            isGroupedWithPrev: isGroupedWithPrev,
          ),
        MessageRole.system => _SystemMessage(message: message),
        _ => _AssistantBubble(
            message: message,
            onRetry: onRetry,
            isGroupedWithPrev: isGroupedWithPrev,
          ),
      },
    );
  }
}

// ─── System Message (compact centered line) ────────────────────────────────

class _SystemMessage extends StatelessWidget {
  final ChatMessage message;
  const _SystemMessage({required this.message});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isSmall = MediaQuery.sizeOf(context).width < 500;
    // Empty-text markers carry no visual — they exist in the timeline
    // as silent anchors for things like the inline approval banner
    // (which is rendered upstream by the itemBuilder against the
    // marker's id). Without this short-circuit we'd draw the divider
    // lines around an invisible line of text.
    if (message.text.isEmpty && !message.isStreaming) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 6, horizontal: isSmall ? 8 : 24),
      child: Row(
        children: [
          Expanded(child: Container(height: 0.5, color: c.border)),
          Flexible(
            flex: 3,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: isSmall ? 6 : 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Leading spinner for in-progress system events
                  // (e.g. ``Compacting context…``). The marker's
                  // ``isStreaming`` flag is flipped to false by the
                  // matching terminal event, which hides the spinner.
                  if (message.isStreaming) ...[
                    SizedBox(
                      width: 11,
                      height: 11,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.4,
                        color: c.textMuted,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      message.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 12.5,
                        color: c.text,
                        fontStyle: FontStyle.italic,
                        letterSpacing: 0.1,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(child: Container(height: 0.5, color: c.border)),
        ],
      ),
    );
  }
}

// ─── User Bubble ─────────────────────────────────────────────────────────────

class _UserBubble extends StatefulWidget {
  final ChatMessage message;
  final bool isGroupedWithPrev;
  const _UserBubble({
    required this.message,
    this.isGroupedWithPrev = false,
  });

  @override
  State<_UserBubble> createState() => _UserBubbleState();
}

class _UserBubbleState extends State<_UserBubble> {
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    widget.message.addListener(_onMessageChanged);
  }

  @override
  void didUpdateWidget(_UserBubble old) {
    super.didUpdateWidget(old);
    if (old.message != widget.message) {
      old.message.removeListener(_onMessageChanged);
      widget.message.addListener(_onMessageChanged);
    }
  }

  @override
  void dispose() {
    widget.message.removeListener(_onMessageChanged);
    super.dispose();
  }

  void _onMessageChanged() {
    // `pending` flips from true→false when the daemon dispatches the
    // turn; rebuild so the dimming / queued label goes away.
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final c = context.colors;
    // `manifest`/`accent` removed — the toned-down user bubble no
    // longer reads from the per-app accent for its bg/border.
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmall = screenWidth < 600;
    final maxBubbleWidth = isSmall
        ? screenWidth * 0.85
        : (screenWidth * 0.72).clamp(320.0, 720.0);
    // Grouping: when the previous message was also from the user,
    // collapse the vertical gap so consecutive turns read as a
    // single thread (à la Claude / ChatGPT / WhatsApp).
    final topGap = widget.isGroupedWithPrev
        ? 2.0
        : (isSmall ? 12.0 : 18.0);
    final bottomGap = isSmall ? 8.0 : 10.0;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onSecondaryTapUp: (details) => _showMenu(context, details, c),
        child: Padding(
          padding: isSmall
              ? EdgeInsets.fromLTRB(40, topGap, 14, bottomGap)
              : EdgeInsets.fromLTRB(80, topGap, 24, bottomGap),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                opacity: message.pending ? 0.55 : 1.0,
                child: ConstrainedBox(
                  constraints:
                      BoxConstraints(maxWidth: maxBubbleWidth),
                  // ChatGPT / Claude style — barely-tinted surface
                  // panel, NO border, NO shadow. Right alignment +
                  // slight bg tint is enough to identify the speaker;
                  // the bordered "CTA" look made every message feel
                  // like a button. Corners are uniform 18 px (no
                  // tail) — both ChatGPT and Claude use equal-radius
                  // bubbles. Matches the web `UserBubble`.
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                    decoration: BoxDecoration(
                      color: Color.lerp(c.surface, c.bg, 0.30) ?? c.surface,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: SelectableText(
                      message.text,
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        color: c.textBright,
                        height: 1.6,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (message.pending) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: c.orange.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: c.orange.withValues(alpha: 0.45),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.schedule_rounded,
                                size: 11, color: c.orange),
                            const SizedBox(width: 5),
                            Text(
                              'QUEUED',
                              style: GoogleFonts.inter(
                                fontSize: 10,
                                color: c.orange,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 150),
                      opacity: _hovered ? 1.0 : 0.0,
                      child: IgnorePointer(
                        ignoring: !_hovered,
                        child: _UserCopyButton(
                          onTap: () {
                            Clipboard.setData(
                                ClipboardData(text: message.text));
                            if (context.mounted) {
                              showToast(context, 'chat.copied'.tr());
                            }
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showMenu(
      BuildContext ctx, TapUpDetails details, AppColors c) {
    showMenu(
      context: ctx,
      position: RelativeRect.fromLTRB(
        details.globalPosition.dx,
        details.globalPosition.dy,
        details.globalPosition.dx,
        details.globalPosition.dy,
      ),
      color: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: c.border),
      ),
      items: [
        PopupMenuItem(
          height: 36,
          onTap: () {
            Clipboard.setData(ClipboardData(text: widget.message.text));
            if (ctx.mounted) showToast(ctx, 'chat.copied'.tr());
          },
          child: Row(
            children: [
              Icon(Icons.copy_rounded, size: 14, color: c.textMuted),
              const SizedBox(width: 8),
              Text('Copy',
                  style: GoogleFonts.inter(fontSize: 12, color: c.text)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Compact copy button shown under the user bubble on hover. Sized
/// to meet the 32x32 touch-target guideline without cluttering the
/// meta row.
class _UserCopyButton extends StatefulWidget {
  final VoidCallback onTap;
  const _UserCopyButton({required this.onTap});

  @override
  State<_UserCopyButton> createState() => _UserCopyButtonState();
}

class _UserCopyButtonState extends State<_UserCopyButton> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: 'chat.copy_message'.tr(),
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _h ? c.surfaceAlt : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _h ? c.borderHover : Colors.transparent,
              ),
            ),
            child: Icon(
              Icons.copy_rounded,
              size: 14,
              color: _h ? c.textBright : c.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Assistant Bubble ─────────────────────────────────────────────────────────

class _AssistantBubble extends StatefulWidget {
  final ChatMessage message;
  final VoidCallback? onRetry;
  final bool isGroupedWithPrev;
  const _AssistantBubble({
    required this.message,
    this.onRetry,
    this.isGroupedWithPrev = false,
  });

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
            // ObjectKey(block) — each ContentBlock instance gets its
            // own State so toggling/opening one never accidentally
            // travels to another via Flutter's positional diff. Was
            // happening with multi-iteration agents (builder
            // coordinator): opening the latest thought re-opened
            // every prior thought because keyless widgets shared the
            // `_open` flag through State-reuse.
            children.add(_ThinkingBlock(
              key: ObjectKey(block),
              text: block.textContent,
              isActive: block.thinkingActive,
              collapsed: collapsed,
              outTokens: block.thinkingTokens,
            ));
          }
          i++;
          break;

        case ContentBlockType.toolCall:
        case ContentBlockType.toolCallStreaming:
          // Collect adjacent tool blocks (real calls + the trailing
          // streaming placeholder, if any) into a single group so the
          // live chip for a call being composed sits in the same
          // section as the calls already finished — no visual break
          // between completed calls and the one being generated.
          final group = <ToolCall>[];
          ContentBlock? trailer;
          while (i < timeline.length) {
            final b = timeline[i];
            if (b.type == ContentBlockType.toolCall && b.toolCall != null) {
              group.add(b.toolCall!);
              i++;
              continue;
            }
            if (b.type == ContentBlockType.toolCallStreaming) {
              if (trailer != null) break; // close on a second chip
              trailer = b;
              i++;
              continue;
            }
            break;
          }
          if (group.isNotEmpty || trailer != null) {
            if (children.isNotEmpty) {
              children.add(const SizedBox(height: 5));
            }
            children.add(_ToolCallSection(
              toolCalls: group,
              streamingTrailer: trailer,
              collapsed: collapsed,
            ));
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
            if (children.isNotEmpty) {
              children.add(const SizedBox(height: 5));
            }
            children.add(ChatMarkdown(text: block.textContent));
          }
          i++;
          break;

        case ContentBlockType.hookEvent:
          // Hook events are not rendered visually for now
          i++;
          break;

        case ContentBlockType.widget:
          // Inline widgets v1 — render the pane spec directly into
          // the bubble. Each gets a bit of vertical breathing room
          // so consecutive widgets don't look glued together.
          final payload = block.widget;
          if (payload != null) {
            if (children.isNotEmpty) {
              children.add(const SizedBox(height: 5));
            }
            children.add(_InlineWidgetBlock(payload: payload));
          }
          i++;
          break;
      }
    }

    // In-bubble typing skeleton removed — the "agent is thinking"
    // cue is now a standalone row at the bottom of the chat list,
    // driven by ``_awaitingAgentResponse`` in ChatPanel. The in-bubble
    // version leaked onto ghost bubbles spawned by replay-drained
    // status events on long-finished turns, even after every guard
    // we added. One indicator, one owner, one flag — easier to keep
    // correct.

    // Token footer removed: the bottom-bar context indicator already
    // shows cumulative session usage, repeating per-turn `↓N in ·
    // ↑M out` on every assistant bubble adds chrome without
    // information the user can't get more globally.

    // ── Action bar ─────────────────────────────────────────────────────
    // Hidden by default, fades in on hover. Matches the user-bubble
    // behaviour and keeps the transcript clean — the copy affordance
    // is still discoverable via hover and via the right-click menu.
    // ``IgnorePointer`` when hidden so ghost hits below the row
    // don't block scroll / selection when the opacity is 0.
    if (message.text.isNotEmpty && !isActive) {
      children.add(
        AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: _hovered ? 1.0 : 0.0,
          child: IgnorePointer(
            ignoring: !_hovered,
            child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ActionBtn(
                  icon: Icons.copy_rounded,
                  tooltip: 'chat.copy_message'.tr(),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: message.text));
                    if (context.mounted) showToast(context, 'Copied to clipboard');
                  },
                ),
                const SizedBox(width: 4),
                _ActionBtn(
                  icon: Icons.text_snippet_outlined,
                  tooltip: 'Copy as Markdown',
                  onTap: () {
                    final md = messageToMarkdown(message);
                    Clipboard.setData(ClipboardData(text: md));
                    if (context.mounted) {
                      showToast(context, 'Copied as Markdown');
                    }
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
        ),
      );
    }

    final topGap = widget.isGroupedWithPrev ? 2.0 : (isSmall ? 12.0 : 18.0);
    final bottomGap = isSmall ? 10.0 : 14.0;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onSecondaryTapUp: (details) => _showContextMenu(context, details),
        child: Padding(
          padding: isSmall
              ? EdgeInsets.fromLTRB(12, topGap, 24, bottomGap)
              : EdgeInsets.fromLTRB(16, topGap, 60, bottomGap),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ),
    );
  }

  void _showContextMenu(BuildContext context, TapUpDetails details) {
    final c = context.colors;
    final msg = widget.message;
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        details.globalPosition.dx, details.globalPosition.dy,
        details.globalPosition.dx, details.globalPosition.dy,
      ),
      color: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: c.border),
      ),
      items: [
        PopupMenuItem(
          height: 36,
          onTap: () {
            Clipboard.setData(ClipboardData(text: msg.text));
            showToast(context, 'chat.copied'.tr());
          },
          child: Row(
            children: [
              Icon(Icons.copy_rounded, size: 14, color: c.textMuted),
              const SizedBox(width: 8),
              Text('Copy message', style: GoogleFonts.inter(fontSize: 12, color: c.text)),
            ],
          ),
        ),
        if (msg.toolCalls.isNotEmpty)
          PopupMenuItem(
            height: 36,
            onTap: () {
              final toolText = msg.toolCalls.map((t) =>
                '${t.displayLabel} ${t.displayDetail}').join('\n');
              Clipboard.setData(ClipboardData(text: '$toolText\n\n${msg.text}'));
              showToast(context, 'chat.copied'.tr());
            },
            child: Row(
              children: [
                Icon(Icons.content_copy_rounded, size: 14, color: c.textMuted),
                const SizedBox(width: 8),
                Text('Copy all', style: GoogleFonts.inter(fontSize: 12, color: c.text)),
              ],
            ),
          ),
      ],
    );
  }
}

// ─── Tool-call-streaming placeholder ──────────────────────────────────────────

/// Live chip shown while the LLM is composing a tool call's args
/// JSON (between `tool_call_streaming` and the matching `tool_start`).
/// Pulses + shows the per-call litellm token count climbing so the
/// user knows the agent is working on a long Write/Edit instead of
/// staring at an empty bubble during multi-second arg generation.
class _ToolCallStreamingChip extends StatefulWidget {
  final String name;
  final int tokenCount;
  const _ToolCallStreamingChip({
    super.key,
    required this.name,
    required this.tokenCount,
  });

  @override
  State<_ToolCallStreamingChip> createState() =>
      _ToolCallStreamingChipState();
}

class _ToolCallStreamingChipState extends State<_ToolCallStreamingChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Mirror `_buildToolContent`'s row geometry (vertical=3 padding,
    // 13-px leading icon, fontSize 12.5 bold label) so when the
    // chip is swapped in-place for the real tool card by
    // ChatMessage.addOrUpdateToolCall, the layout doesn't shift even
    // by a pixel. The "still streaming" signal is colour-only —
    // muted text + a faintly pulsing wrench icon. Once tool_start
    // lands the same row position is occupied by the real card with
    // full status colour (green check / red cross / blue spinner).
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (_, _) => Icon(
              Icons.build_rounded,
              size: 13,
              color: c.textDim.withValues(alpha: 0.5 + 0.4 * _pulse.value),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            widget.name,
            style: GoogleFonts.inter(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: c.textDim,
            ),
          ),
          if (widget.tokenCount > 0) ...[
            const SizedBox(width: 8),
            Text(
              '· ${widget.tokenCount} tokens',
              style: GoogleFonts.firaCode(
                fontSize: 11,
                color: c.textDim.withValues(alpha: 0.7),
                fontFeatures: const [FontFeature.tabularFigures()],
                letterSpacing: 0.2,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Thinking block ──────────────────────────────────────────────────────────

class _ThinkingBlock extends StatefulWidget {
  final String text;
  final bool isActive;
  final bool collapsed;
  /// Live cumulative completion-token count for the assistant message
  /// owning this block — fed by the SSE `token` event's `payload.count`
  /// (litellm-tokenized). Shown next to the label as `· 142 tokens`.
  final int outTokens;
  const _ThinkingBlock({
    super.key,
    required this.text,
    required this.isActive,
    required this.collapsed,
    required this.outTokens,
  });

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock>
    with SingleTickerProviderStateMixin {
  // Always collapsed by default — even during active streaming. The
  // user gets progress feedback through the live token counter next
  // to the label and the pulsing coral dot, and can expand on demand.
  bool _open = false;
  bool _hover = false;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.isActive) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_ThinkingBlock old) {
    super.didUpdateWidget(old);
    // Session-wide collapse still forces closure (e.g. on a new
    // user turn). Otherwise we leave `_open` alone — the user is
    // the only one who toggles the panel now.
    if (!old.collapsed && widget.collapsed) {
      setState(() => _open = false);
    }
    if (widget.isActive && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!widget.isActive && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() {
          _open = !_open;
        }),
        child: Padding(
          // Minimal vertical rhythm — the block is a plain text
          // affordance ("▸ Thoughts · 142 tokens"), no container,
          // no border. Streaming gets a pulsing coral dot.
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedRotation(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      turns: _open ? 0.25 : 0,
                      child: Icon(
                        Icons.chevron_right_rounded,
                        size: 13,
                        color: _hover ? c.textMuted : c.textDim,
                      ),
                    ),
                    const SizedBox(width: 4),
                    // Active streaming: small pulsing coral dot before
                    // the label, the only accent that remains.
                    if (widget.isActive) ...[
                      AnimatedBuilder(
                        animation: _pulse,
                        builder: (_, _) {
                          final t = _pulse.value;
                          return Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: c.accentPrimary
                                  .withValues(alpha: 0.55 + 0.4 * t),
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      widget.isActive ? 'Thinking…' : 'Thoughts',
                      style: GoogleFonts.inter(
                        fontSize: 11.5,
                        color: _hover ? c.textMuted : c.textDim,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.1,
                      ),
                    ),
                    if (widget.outTokens > 0) ...[
                      const SizedBox(width: 6),
                      Text(
                        '· ${widget.outTokens} tokens',
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 10.5,
                          color: c.textDim,
                          fontFeatures: const [
                            FontFeature.tabularFigures(),
                          ],
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ],
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topLeft,
                  clipBehavior: Clip.hardEdge,
                  child: _open && widget.text.isNotEmpty
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(17, 8, 0, 4),
                          child: SelectableText(
                            widget.text,
                            style: GoogleFonts.inter(
                              fontSize: 12.5,
                              color: c.textDim,
                              height: 1.6,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      );
  }
}

// ─── Tool Call Section (tree-based hierarchy) ───────────────────────────────

class _ToolCallSection extends StatefulWidget {
  final List<ToolCall> toolCalls;
  /// Optional live placeholder for the trailing tool call whose
  /// args are still being composed by the LLM. Slots in as the last
  /// row of the section so the user sees a continuous sequence
  /// (no visual break between completed calls and the live one).
  final ContentBlock? streamingTrailer;
  final bool collapsed;
  const _ToolCallSection({
    required this.toolCalls,
    required this.collapsed,
    this.streamingTrailer,
  });

  @override
  State<_ToolCallSection> createState() => _ToolCallSectionState();
}

class _ToolCallSectionState extends State<_ToolCallSection> {
  bool _showAll = false;
  final _expandedTools = <String>{};
  final _fullyExpandedPreviews = <String>{};
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

    // Tool results stay COLLAPSED by default once a tool finishes —
    // the user opens them on demand by clicking the row. This keeps
    // long agent turns from exploding the transcript with 20 + tool
    // bodies. We still record `_seenCompleted` so the "flash on
    // first sight" logic elsewhere can differentiate new vs. seen
    // tools, but we no longer auto-push ids into `_expandedTools`.
    if (!widget.collapsed) {
      for (final t in widget.toolCalls) {
        if (t.status != 'started') {
          _seenCompleted.add(t.id);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tools = widget.toolCalls;
    final hasTrailer = widget.streamingTrailer != null;
    if (tools.isEmpty && !hasTrailer) return const SizedBox.shrink();

    // When the section is JUST a trailing streaming chip (no real
    // calls finished yet), skip the tree/gutter rendering and emit
    // the chip alone — same paddingLeft logic as a single tool call.
    if (tools.isEmpty && hasTrailer) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: _ToolCallStreamingChip(
          key: ObjectKey(widget.streamingTrailer),
          name: widget.streamingTrailer!.streamingToolName ?? 'Tool',
          tokenCount: widget.streamingTrailer!.thinkingTokens,
        ),
      );
    }

    final hasRunning = tools.any((t) => t.status == 'started');
    final hasFailed = tools.any((t) => t.status == 'failed');
    // While the trailer chip is live the section is "still
    // running" too — that signal is what unlocks the blue group
    // colour + spinner so the eye doesn't see the section flip
    // colour at the chip → real-card swap.
    final isDone = !hasRunning && !hasTrailer;
    // Count the trailer chip as another item — keeps tree-line
    // rendering on (N tools + chip) pairs so when the chip is
    // swapped in-place for a real call the layout stays in tree
    // mode without re-flowing.
    final totalItems = tools.length + (hasTrailer ? 1 : 0);
    final isSingle = totalItems == 1;

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

    return ClipRect(
      child: Column(
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
                      isLast: i == visibleTools.length - 1 &&
                          hidden <= 0 &&
                          !hasTrailer,
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
        if (isSingle && tools.isNotEmpty)
          for (int i = 0; i < visibleTools.length; i++)
            _buildToolContent(context, tool: visibleTools[i], c: c),

        // ── "Show N more" link ──────────────────────────────────────
        if (hidden > 0 && !_showAll)
          Padding(
            padding: EdgeInsets.only(left: isSingle ? 0 : contentLeft, top: 4, bottom: 2),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
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
          ),

        // ── Streaming trailer (LLM still composing the next call) ──
        // Rendered as another tree-line row so the chip → real-card
        // swap (via ChatMessage.addOrUpdateToolCall) keeps the same
        // gutter, padding, and overall row geometry. Zero layout shift
        // when the swap happens.
        if (hasTrailer)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CustomPaint(
                  size: const Size(contentLeft, double.infinity),
                  painter: _TreeLinePainter(
                    isFirst: tools.isEmpty,
                    isLast: true,
                    lineX: lineX,
                    color: groupColor.withValues(alpha: 0.5),
                  ),
                ),
                Expanded(
                  child: _ToolCallStreamingChip(
                    key: ObjectKey(widget.streamingTrailer),
                    name: widget.streamingTrailer!.streamingToolName ?? 'Tool',
                    tokenCount: widget.streamingTrailer!.thinkingTokens,
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
    );
  }

  Widget _buildToolContent(
    BuildContext context, {
    required ToolCall tool,
    required AppColors c,
  }) {
    // ``started`` (legacy) and ``running`` (newer) both mean in-flight.
    // ``pending_approval`` means the daemon is waiting on a user
    // approval — surface that as its own state so the chip shows the
    // waiting-on-you signal rather than "done" styling.
    final isRunning =
        tool.status == 'started' || tool.status == 'running';
    final isPendingApproval = tool.status == 'pending_approval';
    var isError = tool.status == 'failed';
    if (!isError && tool.result is Map) {
      final r = tool.result as Map;
      if (r['success'] == false || (r['error'] != null && r['error'].toString().isNotEmpty)) {
        isError = true;
      } else if (r.containsKey('exit_code') && r['exit_code'] != 0) {
        isError = true;
      }
    }
    // Treat pending_approval as "not done" so the preview/brief paths
    // don't try to render a non-existent result and the chip stays in
    // the hold-up visual state.
    final isDone = !isRunning && !isPendingApproval;
    final isExpanded = _expandedTools.contains(tool.id);
    final isFullyExpanded = _fullyExpandedPreviews.contains(tool.id);

    final label = tool.displayLabel;
    final detail = tool.displayDetail;
    final preview = isDone ? _buildPreview(tool, showAll: isFullyExpanded) : null;
    final hasPreview = preview != null && preview.isNotEmpty;
    final brief = isDone ? _briefResult(tool) : '';
    final durationLabel = isDone ? _formatToolDuration(tool) : '';

    // Color hierarchy:
    // Label = bright/prominent (white in dark, black in light)
    // Detail = blue/cyan tint (clearly distinct from label)
    // Brief = muted pill background
    // pending_approval gets the warning (amber) tint so the user
    // notices the chip is waiting on them rather than the agent.
    final labelColor = isError
        ? c.red
        : (isPendingApproval
            ? c.orange
            : (isRunning ? c.blue : c.textBright));
    final detailColor = isError
        ? c.red.withValues(alpha: 0.7)
        : (isPendingApproval
            ? c.orange.withValues(alpha: 0.7)
            : c.blue.withValues(alpha: 0.7));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Tool label row ──────────────────────────────────────────
        MouseRegion(
          cursor: hasPreview ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: GestureDetector(
          onTap: hasPreview
              ? () => setState(() {
                    if (isExpanded) {
                      _expandedTools.remove(tool.id);
                    } else {
                      _expandedTools.add(tool.id);
                    }
                  })
              : null,
          behavior: HitTestBehavior.translucent,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                // Status icon
                if (isRunning)
                  SizedBox(
                    width: 13, height: 13,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5, color: c.blue),
                  )
                else if (tool.icon.isNotEmpty && !isError)
                  Icon(_semanticIcon(tool.icon), size: 13, color: c.green)
                else
                  Icon(
                    isError ? Icons.close_rounded : Icons.check_rounded,
                    size: 13,
                    color: isError ? c.red : c.green,
                  ),
                const SizedBox(width: 6),
                // Label — bold, prominent
                Flexible(
                  child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: labelColor,
                    )),
                ),
                // Detail (path, command) — monospace, tinted blue
                if (detail.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    flex: 2,
                    child: Text(detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.firaCode(
                        fontSize: 11,
                        color: detailColor,
                      )),
                  ),
                ],
                // Brief result — pill badge, muted
                if (brief.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: (isError ? c.red : c.textMuted).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(brief,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.firaCode(
                        fontSize: 10,
                        color: isError ? c.red : c.textMuted,
                        fontWeight: FontWeight.w500,
                      )),
                  ),
                ],
                // Duration — only shown when the daemon provided it.
                // Mirrors Cursor's "· 245ms" style.
                if (durationLabel.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(durationLabel,
                      style: GoogleFonts.firaCode(
                          fontSize: 9.5, color: c.textDim)),
                ],
                // Expand chevron
                if (hasPreview) ...[
                  const SizedBox(width: 4),
                  Icon(
                    isExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 14,
                    color: c.textDim,
                  ),
                ],
              ],
            ),
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
                    child: _PreviewTree(
                      lines: preview,
                      isFullyExpanded: isFullyExpanded,
                      isGlobalError: isError,
                      onToggleExpand: () => setState(() {
                          if (isFullyExpanded) {
                            _fullyExpandedPreviews.remove(tool.id);
                          } else {
                            _fullyExpandedPreviews.add(tool.id);
                          }
                        }),
                    ),
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
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
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
          ),
          // Agent rows with continuous vertical line
          AnimatedSize(
            duration: const Duration(milliseconds: 150),
            alignment: Alignment.topCenter,
            clipBehavior: Clip.hardEdge,
            child: _open
                ? Padding(
                    padding: const EdgeInsets.only(left: 6, top: 2),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: headerColor.withValues(alpha: 0.3),
                            width: 1.2,
                          ),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (int i = 0; i < events.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(left: 12),
                              child: _AgentRow(event: events[i]),
                            ),
                        ],
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

class _AgentRow extends StatelessWidget {
  final AgentEventData event;
  const _AgentRow({required this.event});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final statusColor = _agentColorFromTheme(event.status, colors);
    final name = event.specialist.isNotEmpty
        ? event.specialist
        : event.agentId.isNotEmpty
            ? event.agentId
            : 'Agent';
    final isRunning =
        event.status == 'running' || event.status == 'spawned';

    final statusBits = <Widget>[];
    if (event.toolCallsCount > 0) {
      statusBits.add(_AgentChip(
        text: '${event.toolCallsCount} tool'
            '${event.toolCallsCount == 1 ? '' : 's'}',
        color: colors.blue,
      ));
    }
    if (event.duration > 0) {
      statusBits.add(Text('${event.duration.toStringAsFixed(1)}s',
          style:
              GoogleFonts.firaCode(fontSize: 10, color: colors.textDim)));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Status indicator — pulsing dot when running
              isRunning
                  ? _PulseDot(color: statusColor)
                  : Text(_agentIcon(event.status),
                      style: TextStyle(
                          fontSize: 11,
                          color: statusColor,
                          fontWeight: FontWeight.bold)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: statusColor,
                  ),
                ),
              ),
              if (event.task.isNotEmpty) ...[
                Text(' · ',
                    style: GoogleFonts.inter(
                        fontSize: 11, color: colors.textDim)),
                Flexible(
                  child: Text(
                    event.task,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                        fontSize: 11, color: colors.textMuted),
                  ),
                ),
              ],
              for (final bit in statusBits) ...[
                const SizedBox(width: 6),
                bit,
              ],
            ],
          ),
          // Live preview — what the agent is currently doing. Shows
          // the last line of its stdout/thinking so parallel runs
          // aren't a black box.
          if (event.preview.isNotEmpty && isRunning)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 18),
              child: Text(
                event.preview,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.firaCode(
                  fontSize: 10.5,
                  color: colors.textDim,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          if (event.resultSummary != null && event.resultSummary!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 18),
              child: Text(
                event.resultSummary!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                    fontSize: 11, color: colors.textMuted, height: 1.35),
              ),
            ),
          if (event.error != null && event.error!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 18),
              child: Text(
                event.error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                    fontSize: 11, color: colors.red, height: 1.35),
              ),
            ),
        ],
      ),
    );
  }
}

/// Tiny pulsing dot — drawn next to a running agent so parallel
/// executions feel alive even when the daemon only emits an
/// occasional progress event.
class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) {
        final a = 0.45 + 0.55 * _ctrl.value;
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: a),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: a * 0.6),
                blurRadius: 4,
                spreadRadius: 1,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AgentChip extends StatelessWidget {
  final String text;
  final Color color;
  const _AgentChip({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(
        text,
        style: GoogleFonts.firaCode(
          fontSize: 9.5,
          color: color,
          fontWeight: FontWeight.w600,
          height: 1.1,
        ),
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

class ChatMarkdown extends StatelessWidget {
  final String text;
  const ChatMarkdown({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    // Convert single \n to hard break (two trailing spaces + \n)
    // but preserve \n\n as paragraph break and code blocks
    final data = _convertLineBreaks(text);

    final c = context.colors;
    return MarkdownBody(
      data: data,
      selectable: false, // Let parent SelectionArea handle cross-widget selection
      onTapLink: (text, href, title) {
        if (href != null && href.startsWith('http')) {
          // Could open in browser
        }
      },
      builders: {
        'code': _CodeBlockBuilder(),
      },
      // Reading-first typography (Claude / ChatGPT tier): 16px body
      // with a 1.72 line-height gives long responses room to
      // breathe, Fraunces on display headings adds an editorial
      // contrast against the Inter-dominant UI, and inline code
      // uses a subtle tint instead of the old purple highlight so
      // it reads as "a word" not "a citation".
      styleSheet: MarkdownStyleSheet(
        p: GoogleFonts.inter(
          fontSize: 13.5,
          color: c.text,
          height: 1.55,
          letterSpacing: -0.05,
          fontWeight: FontWeight.w400,
        ),
        pPadding: const EdgeInsets.symmetric(vertical: 1),
        h1: GoogleFonts.fraunces(
          fontSize: 28,
          fontWeight: FontWeight.w600,
          color: c.textBright,
          letterSpacing: -0.6,
          height: 1.2,
        ),
        h1Padding: const EdgeInsets.only(top: 28, bottom: 8),
        h2: GoogleFonts.fraunces(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: c.textBright,
          letterSpacing: -0.3,
          height: 1.25,
        ),
        h2Padding: const EdgeInsets.only(top: 22, bottom: 6),
        h3: GoogleFonts.inter(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: c.textBright,
          letterSpacing: -0.1,
          height: 1.35,
        ),
        h3Padding: const EdgeInsets.only(top: 18, bottom: 4),
        h4: GoogleFonts.inter(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: c.textBright,
          letterSpacing: 0,
        ),
        h4Padding: const EdgeInsets.only(top: 14, bottom: 2),
        h5: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: c.textBright,
        ),
        h6: GoogleFonts.inter(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: c.textMuted,
          letterSpacing: 0.4,
        ),
        code: GoogleFonts.jetBrainsMono(
          fontSize: 13.5,
          color: c.textBright,
          backgroundColor: c.codeBlockBg,
          fontWeight: FontWeight.w500,
          letterSpacing: 0,
        ),
        // Intentionally empty — _CodeBlockBuilder handles code block styling.
        codeblockDecoration: const BoxDecoration(),
        codeblockPadding: EdgeInsets.zero,
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: c.accentPrimary, width: 3),
          ),
          color: c.surface.withValues(alpha: 0.6),
          borderRadius: const BorderRadius.only(
            topRight: Radius.circular(4),
            bottomRight: Radius.circular(4),
          ),
        ),
        blockquotePadding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        blockquote: GoogleFonts.inter(
          fontSize: 15,
          color: c.textMuted,
          fontStyle: FontStyle.italic,
          height: 1.65,
        ),
        strong: GoogleFonts.inter(
          fontSize: 15.5,
          fontWeight: FontWeight.w700,
          color: c.textBright,
          height: 1.72,
        ),
        em: GoogleFonts.inter(
          fontSize: 15.5,
          fontStyle: FontStyle.italic,
          color: c.text,
          height: 1.72,
        ),
        listBullet: GoogleFonts.inter(
          fontSize: 15.5,
          color: c.accentPrimary,
          fontWeight: FontWeight.w600,
        ),
        listBulletPadding: const EdgeInsets.only(right: 6),
        listIndent: 22,
        a: GoogleFonts.inter(
          fontSize: 15.5,
          color: c.accentPrimary,
          decoration: TextDecoration.underline,
          decorationColor: c.accentPrimary.withValues(alpha: 0.4),
          decorationThickness: 1.5,
        ),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: c.border, width: 1),
          ),
        ),
        tableHead: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: c.textBright,
        ),
        tableBody: GoogleFonts.inter(
          fontSize: 14,
          color: c.text,
          height: 1.5,
        ),
        tableHeadAlign: TextAlign.left,
        tableBorder: TableBorder.all(
          color: c.border,
          width: 1,
          borderRadius: BorderRadius.circular(6),
        ),
        tableCellsPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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

class _CodeHeaderDot extends StatelessWidget {
  final Color color;
  const _CodeHeaderDot({required this.color});

  @override
  Widget build(BuildContext context) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
      );
}

class _CodeBlockState extends State<_CodeBlock> {
  // Collapse inline code blocks beyond this many lines by default
  // — same threshold as the artifact detector's _codeBlockMinLines.
  // Keeps the chat scroll tight while leaving the full content one
  // click away.
  static const int _collapseThreshold = 20;
  static const double _collapsedMaxHeight = 320;

  bool _copied = false;
  bool _expanded = false;
  Timer? _copyResetTimer;

  int get _lineCount {
    if (widget.code.isEmpty) return 0;
    return '\n'.allMatches(widget.code).length + 1;
  }

  bool get _shouldCollapse =>
      _lineCount > _collapseThreshold && !_expanded;

  @override
  void dispose() {
    _copyResetTimer?.cancel();
    super.dispose();
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.code));
    if (context.mounted) showToast(context, 'Copied to clipboard');
    setState(() => _copied = true);
    _copyResetTimer?.cancel();
    _copyResetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hasLang = widget.language.isNotEmpty;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: c.codeBlockBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
        boxShadow: [
          BoxShadow(
            color: c.shadow.withValues(alpha: 0.14),
            blurRadius: 6,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Premium header: 3-dot decorative marks + language + always-visible Copy
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: c.codeBlockHeader,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(9),
                topRight: Radius.circular(9),
              ),
              border: Border(
                bottom: BorderSide(
                    color: c.border.withValues(alpha: 0.7), width: 1),
              ),
            ),
            child: Row(
              children: [
                // Traffic-light-ish dots — classic code-editor chrome.
                _CodeHeaderDot(color: c.red.withValues(alpha: 0.55)),
                const SizedBox(width: 6),
                _CodeHeaderDot(color: c.orange.withValues(alpha: 0.55)),
                const SizedBox(width: 6),
                _CodeHeaderDot(color: c.green.withValues(alpha: 0.55)),
                const SizedBox(width: 14),
                if (hasLang)
                  Text(
                    widget.language.toUpperCase(),
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 10.5,
                      color: c.textMuted,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                  ),
                const Spacer(),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: _copy,
                    behavior: HitTestBehavior.opaque,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: _copied
                            ? c.green.withValues(alpha: 0.14)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: _copied
                              ? c.green.withValues(alpha: 0.45)
                              : c.border,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _copied
                                ? Icons.check_rounded
                                : Icons.copy_rounded,
                            size: 13,
                            color: _copied ? c.green : c.text,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            _copied ? 'Copied' : 'Copy',
                            style: GoogleFonts.inter(
                              fontSize: 11.5,
                              color: _copied ? c.green : c.text,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Code content — larger, calmer typography. Long blocks
          // are collapsed by default with a fade gradient hint; the
          // footer's Show more / Collapse button toggles state.
          _buildCodeBody(c, hasLang),
          if (_lineCount > _collapseThreshold) _buildExpandFooter(c),
        ],
      ),
    );
  }

  Widget _buildCodeBody(AppColors c, bool hasLang) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final syntaxTheme = Map<String, TextStyle>.from(
      isDark ? atomOneDarkTheme : atomOneLightTheme,
    );
    syntaxTheme['root'] = (syntaxTheme['root'] ?? const TextStyle())
        .copyWith(backgroundColor: Colors.transparent);
    final highlight = HighlightView(
      widget.code,
      language: hasLang ? widget.language : 'plaintext',
      theme: syntaxTheme,
      textStyle: GoogleFonts.jetBrainsMono(
        fontSize: 13.5,
        height: 1.55,
        letterSpacing: 0,
      ),
      padding: EdgeInsets.zero,
    );
    final padded = Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: highlight,
    );
    if (!_shouldCollapse) return padded;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: _collapsedMaxHeight),
      child: Stack(
        children: [
          Positioned.fill(
            child: SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
              child: padded,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 56,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      c.codeBlockBg.withValues(alpha: 0.0),
                      c.codeBlockBg,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExpandFooter(AppColors c) {
    final hidden = _lineCount - _collapseThreshold;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _expanded = !_expanded),
        child: Container(
          height: 30,
          decoration: BoxDecoration(
            color: c.codeBlockHeader,
            border: Border(
              top: BorderSide(color: c.border.withValues(alpha: 0.6)),
            ),
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(9),
              bottomRight: Radius.circular(9),
            ),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _expanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 14,
                color: c.accentPrimary,
              ),
              const SizedBox(width: 6),
              Text(
                _expanded
                    ? 'Collapse'
                    : 'Show full · $_lineCount lines'
                        '${hidden > 0 ? '  (+$hidden hidden)' : ''}',
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

/// Map daemon icon names to Flutter IconData.
/// Map a daemon-declared semantic icon key to a Material icon.
/// Covers every canonical value of `display.icon` from the event
/// spec v2. Unknown keys fall back to `build_rounded` (the spec's
/// "tool" default) so the bubble never renders an empty slot.
IconData _semanticIcon(String icon) => switch (icon) {
  // ── Canonical icons from the event-spec v2 ─────────────────────
  'file' => Icons.description_rounded,
  'folder' => Icons.folder_rounded,
  'checklist' => Icons.checklist_rounded,
  'memory' => Icons.psychology_rounded,
  'terminal' => Icons.terminal_rounded,
  'search' => Icons.search_rounded,
  'agent' => Icons.smart_toy_rounded,
  'web' => Icons.language_rounded,
  'database' => Icons.storage_rounded,
  'git' => Icons.account_tree_rounded,
  'tool' => Icons.build_rounded,
  'image' => Icons.image_rounded,
  'network' => Icons.cable_rounded,
  'edit' => Icons.edit_rounded,
  'preview' => Icons.preview_rounded,
  'workspace' => Icons.workspaces_rounded,
  'diagnostics' => Icons.bug_report_rounded,
  'shell' => Icons.terminal_rounded,
  // ── Client-side supplemental icons ─────────────────────────────
  'code' => Icons.code_rounded,
  'download' => Icons.download_rounded,
  'upload' => Icons.upload_rounded,
  'lock' => Icons.lock_rounded,
  'key' => Icons.key_rounded,
  'mail' => Icons.mail_rounded,
  'chat' => Icons.chat_rounded,
  'settings' => Icons.settings_rounded,
  'graph' => Icons.account_tree_rounded,
  // Unknown — render the generic "tool" fallback (spec §Valeurs
  // canoniques: unknown → "tool").
  _ => Icons.build_rounded,
};

class _PreviewLine {
  final String text;
  final String type; // 'add' 'del' 'context' 'output' 'error' 'summary' 'code' 'command' 'bash_output' 'file_link'
  final int lineNo; // 0 = no line number
  /// When non-empty, the preview tree renders this row as a clickable
  /// link that opens the file in the workspace panel.
  final String clickPath;
  /// 1-based line to jump to when clicking (0 = top of file).
  final int clickLine;
  const _PreviewLine(
    this.text,
    this.type, {
    this.lineNo = 0,
    this.clickPath = '',
    this.clickLine = 0,
  });
}

class _PreviewTree extends StatelessWidget {
  final List<_PreviewLine> lines;
  final VoidCallback? onToggleExpand;
  final bool isFullyExpanded;
  final bool isGlobalError;
  const _PreviewTree({required this.lines, this.onToggleExpand, this.isFullyExpanded = false, this.isGlobalError = false});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final maxLines = lines.length;
    // Check if this preview has diff or code lines (for IDE-style rendering)
    final hasDiff = lines.any((l) => l.type == 'add' || l.type == 'del');
    final hasCode = lines.any((l) => l.type == 'code');
    final hasLineNos = hasDiff || hasCode || lines.any((l) => l.lineNo > 0);
    // Max line number width
    final maxLineNo = lines.where((l) => l.lineNo > 0).fold<int>(0,
        (m, l) => l.lineNo > m ? l.lineNo : m);
    final lineNoWidth = maxLineNo > 0 ? '$maxLineNo'.length : 0;

    if (hasLineNos) {
      // IDE-style rendering with line numbers
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (int i = 0; i < maxLines; i++)
              _buildDiffLine(c, lines[i], lineNoWidth, context: context),
          ],
        ),
      );
    }

    // Standard output rendering (no diff)
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < maxLines; i++)
          _buildOutputLine(c, lines[i], context: context),
      ],
    );
  }

  /// IDE-style line with optional colored background, gutter, line number
  Widget _buildDiffLine(AppColors c, _PreviewLine line, int lineNoWidth, {BuildContext? context}) {
    final isDiff = line.type == 'add' || line.type == 'del';
    final isAdd = line.type == 'add';
    final isDel = line.type == 'del';
    final isCode = line.type == 'code' || line.type == 'bash_output';
    final isBashOutput = line.type == 'bash_output';
    final isSummary = line.type == 'summary';
    final isCommand = line.type == 'command';
    final isFileLink = line.type == 'file_link';

    // Background color — git-diff convention: green for additions,
    // red for deletions.
    final bgColor = isAdd
        ? c.green.withValues(alpha: 0.12)
        : isDel
            ? c.red.withValues(alpha: 0.12)
            : Colors.transparent;

    // Text color
    var textColor = isAdd
        ? c.green
        : isDel
            ? c.red
            : isFileLink
                ? c.blue
                : isSummary || isCommand
                    ? c.textMuted
                    : isBashOutput
                        ? c.textDim
                        : c.text;

    if (isGlobalError && !isAdd && !isDel && !isSummary && !isCommand && !isFileLink) {
      textColor = c.red;
    }

    // Clean text: remove leading +/- if present (we show it in gutter)
    var displayText = line.text;
    if (isDiff && displayText.isNotEmpty && (displayText[0] == '+' || displayText[0] == '-')) {
      displayText = displayText.substring(1);
    }

    if (isSummary) {
      final isExpandToggle = line.text.startsWith('…') || line.text == 'Show less';
      Widget textWidget = Text(
        line.text,
        style: GoogleFonts.firaCode(fontSize: 11, color: c.textMuted, height: 1.5),
      );
      if (isExpandToggle && onToggleExpand != null) {
        textWidget = MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onToggleExpand,
            child: textWidget,
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: textWidget,
      );
    }

    if (isCommand) {
      final isLong = line.text.length > 80 || line.text.contains('\n');
      final force1Line = !isFullyExpanded;

      return GestureDetector(
        onTap: isLong ? onToggleExpand : null,
        child: MouseRegion(
          cursor: isLong ? SystemMouseCursors.click : MouseCursor.defer,
          child: Container(
            color: c.textDim.withValues(alpha: 0.08),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            margin: const EdgeInsets.only(bottom: 4, top: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: c.border.withValues(alpha: 0.5)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('\$ ', style: GoogleFonts.firaCode(fontSize: 11, color: c.blue, fontWeight: FontWeight.w600)),
                Expanded(
                  child: Text(
                    line.text,
                    maxLines: force1Line ? 1 : null,
                    overflow: force1Line ? TextOverflow.ellipsis : null,
                    style: GoogleFonts.firaCode(fontSize: 11, color: c.textMuted, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final row = Container(
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
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.firaCode(
                fontSize: 11, height: 1.6,
                color: textColor,
                decoration: isFileLink ? TextDecoration.underline : null,
                decorationColor: isFileLink ? c.blue.withValues(alpha: 0.6) : null,
              ),
            ),
          ),
        ],
      ),
    );
    if (line.clickPath.isNotEmpty && context != null) {
      final ctx = context;
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => _openFileInWorkspace(ctx, line.clickPath, line: line.clickLine),
          child: row,
        ),
      );
    }
    return row;
  }

  /// Standard output line (non-diff)
  Widget _buildOutputLine(AppColors c, _PreviewLine line, {BuildContext? context}) {
    final isFileLink = line.type == 'file_link';
    var color = switch (line.type) {
      'error'   => c.red,
      'summary' => c.textMuted,
      'command' => c.textMuted,
      'bash_output' => c.textDim,
      'file_link' => c.blue,
      'output'  => c.text,
      'param'   => c.textMuted,
      _ => c.textMuted,
    };
    if (isGlobalError && line.type != 'summary' && line.type != 'command' &&
        line.type != 'param' && !isFileLink) {
      color = c.red;
    }
    Widget child = Text(
      line.text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: GoogleFonts.firaCode(
        fontSize: 11,
        height: 1.5,
        color: color,
        decoration: isFileLink ? TextDecoration.underline : null,
        decorationColor: isFileLink ? c.blue.withValues(alpha: 0.6) : null,
      ),
    );
    if (line.type == 'summary' && (line.text.startsWith('…') || line.text == 'Show less') && onToggleExpand != null) {
      child = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onToggleExpand,
          child: child,
        ),
      );
    } else if (line.clickPath.isNotEmpty && context != null) {
      final ctx = context;
      child = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => _openFileInWorkspace(ctx, line.clickPath, line: line.clickLine),
          child: child,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 0.5),
      child: child,
    );
  }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Open [path] in the workspace panel. Tries the in-memory WorkspaceModule
/// first (virtual files from `preview:*` events), then falls back to the
/// workbench (daemon-read files). Ensures the workspace panel is visible.
void _openFileInWorkspace(BuildContext context, String path, {int line = 0}) {
  if (path.isEmpty) return;
  // Surface the workspace panel.
  try {
    final app = context.read<AppState>();
    if (!app.isWorkspaceVisible) app.showWorkspace();
  } catch (_) {
    // Provider not in scope — ignore.
  }
  // Prefer the WorkspaceModule (virtual FS) if the file is already known.
  final wsModule = WorkspaceModule();
  if (wsModule.files.containsKey(path)) {
    wsModule.selectFile(path);
    return;
  }
  // Otherwise ask the workbench to open it. Lands in the "files" tab.
  if (line > 0) {
    WorkspaceService().revealLine(path, line);
  } else {
    WorkspaceService().setActiveBuffer(path);
    WorkspaceService().setActiveTab('files');
  }
}

/// Serialise a whole ChatMessage (text + thinking + tool calls +
/// agent events) into clean Markdown for the clipboard. Rendered so
/// an investor can paste directly into a doc and have it look great.
String messageToMarkdown(ChatMessage message) {
  final role = message.role == MessageRole.user
      ? 'User'
      : message.role == MessageRole.system
          ? 'System'
          : 'Assistant';
  final buf = StringBuffer('## $role\n\n');
  final thinking = message.thinkingText;
  if (thinking.isNotEmpty) {
    buf.writeln('> **Thinking**');
    for (final l in thinking.split('\n')) {
      buf.writeln('> $l');
    }
    buf.writeln();
  }

  for (final block in message.timeline) {
    switch (block.type) {
      case ContentBlockType.text:
        if (block.textContent.isNotEmpty) {
          buf.writeln(block.textContent);
          buf.writeln();
        }
      case ContentBlockType.toolCall:
        final t = block.toolCall;
        if (t == null) continue;
        final label = t.displayLabel;
        final detail = t.displayDetail;
        buf.writeln('### 🔧 $label${detail.isNotEmpty ? " — `$detail`" : ""}');
        if (t.status == 'failed' && t.error != null) {
          buf.writeln('> ❌ ${t.error}');
        } else if (t.result != null) {
          final res = t.result;
          if (res is String && res.isNotEmpty) {
            buf.writeln('```');
            buf.writeln(res.length > 500 ? '${res.substring(0, 500)}…' : res);
            buf.writeln('```');
          } else if (res is Map) {
            final r = res;
            final content = r['content'];
            if (content is String && content.isNotEmpty) {
              buf.writeln('```');
              buf.writeln(content.length > 500
                  ? '${content.substring(0, 500)}…'
                  : content);
              buf.writeln('```');
            } else {
              final keys = r.keys.take(6).join(', ');
              buf.writeln('_Result: {$keys}_');
            }
          }
        }
        buf.writeln();
      case ContentBlockType.agentEvent:
        final e = block.agentEvent;
        if (e == null) continue;
        final bullet = e.status == 'completed'
            ? '✓'
            : e.status == 'failed' ? '✗' : '●';
        buf.writeln(
            '- $bullet **${e.specialist.isNotEmpty ? e.specialist : e.agentId}**'
            '${e.task.isNotEmpty ? ": ${e.task}" : ""}'
            '${e.duration > 0 ? " _(${e.duration.toStringAsFixed(1)}s)_" : ""}');
        if (e.resultSummary != null && e.resultSummary!.isNotEmpty) {
          buf.writeln('  - ${e.resultSummary}');
        }
      case ContentBlockType.thinking:
      case ContentBlockType.toolCallStreaming:
      case ContentBlockType.hookEvent:
      case ContentBlockType.widget:
        // Skip — either already captured above (thinking) or not
        // meaningful in a copy-paste context (toolCallStreaming is
        // an ephemeral live placeholder, swapped for the real
        // toolCall block before serialization matters).
        break;
    }
  }

  if (message.inTokens > 0 || message.outTokens > 0) {
    buf.writeln();
    buf.writeln(
        '_↓ ${message.inTokens} in · ↑ ${message.outTokens} out tokens_');
  }
  return buf.toString().trimRight();
}

/// Extract a formatted duration for a tool call — "245ms", "3.2s",
/// "1m 5s". Prefers the daemon-observed delta `ts(tool_call) −
/// ts(tool_start)` (captured onto [ToolCall.observedDuration]) since
/// that's the authoritative server-side measurement from the event
/// spec. Falls back to any `duration_ms` / `elapsed_ms` field the
/// tool may have put in its result or metadata — useful for older
/// daemons that don't stamp envelope `ts` yet. Returns an empty
/// string when no duration is available.
String _formatToolDuration(ToolCall t) {
  num? ms;

  // 1. Authoritative source: envelope ts delta.
  final observed = t.observedDuration;
  if (observed != null && observed.inMicroseconds > 0) {
    ms = observed.inMicroseconds / 1000.0;
  }

  // 2. Fallbacks: daemon-provided duration fields.
  if (ms == null) {
    num? pick(Object? v) => v is num ? v : null;
    ms ??= pick(t.metadata?['duration_ms']);
    ms ??= pick(t.metadata?['elapsed_ms']);
    ms ??= pick(t.metadata?['latency_ms']);
    if (t.result is Map) {
      final r = t.result as Map;
      ms ??= pick(r['duration_ms']);
      ms ??= pick(r['elapsed_ms']);
      ms ??= pick(r['latency_ms']);
      final secs = pick(r['duration']) ?? pick(r['elapsed']);
      if (ms == null && secs != null) ms = secs * 1000;
    }
  }

  if (ms == null || ms <= 0) return '';
  if (ms < 1000) return '${ms.round()}ms';
  final s = ms / 1000.0;
  if (s < 60) return '${s.toStringAsFixed(s < 10 ? 1 : 0)}s';
  final mins = s ~/ 60;
  final rest = (s - mins * 60).round();
  return rest > 0 ? '${mins}m ${rest}s' : '${mins}m';
}

/// Strip daemon-injected line numbers from content. Supports two
/// separators: `1│code` (legacy TUI format) and `1\tcode` (filesystem /
/// workspace Read format). Also tolerates lines prefixed with `+`/`-`
/// (diff output): `"+  1│code"` / `"+1\tcode"` → stays tagged `+code`.
String _stripLineNos(String text) {
  if (text.isEmpty) return text;
  final hasBar = text.contains('│');
  final hasTab = text.contains('\t');
  if (!hasBar && !hasTab) return text;

  final lines = text.split('\n');
  final nonEmpty = lines.where((l) => l.trim().isNotEmpty).take(6).toList();
  // Regex for either separator.
  final lineRe = RegExp(r'^([+\- ]?)[ ]*\d+(?:│|\t)(.*)$');
  final hits = nonEmpty.where(lineRe.hasMatch).length;
  if (nonEmpty.isNotEmpty && hits < (nonEmpty.length * 0.6)) return text;

  return lines.map((l) {
    final match = lineRe.firstMatch(l);
    if (match != null) {
      final prefix = match.group(1)!;
      final code = match.group(2)!;
      return prefix.trim().isEmpty ? code : '$prefix$code';
    }
    return l;
  }).join('\n');
}

/// Brief result summary (like TUI: "3 lines", "exit 0 · first line", "5 matches")
String _briefResult(ToolCall t) {
  if (t.result == null) return '';
  final r = t.result;
  if (r is! Map) return r is String && r.length < 60 ? r : '';

  final data = r;

  // ask_user / approval: show the user's response or status
  if (t.name.toLowerCase().contains('ask_user') ||
      data.containsKey('user_response')) {
    final status = data['status'] as String? ?? '';
    final response = data['user_response'] as String? ??
        data['raw_response'] as String? ??
        data['answer'] as String? ?? '';
    if (response.isNotEmpty) {
      return response.length > 50
          ? '${response.substring(0, 50)}…'
          : response;
    }
    if (status == 'approved') return 'approved';
    if (status == 'denied' || status == 'rejected') return 'denied';
    return status;
  }

  // HTTP request: compact "200 · 4.6 KB"
  if (data.containsKey('status_code') && data.containsKey('method')) {
    final code = data['status_code'];
    final size = data['size_bytes'] as num?;
    final parts = <String>['$code'];
    if (size != null) {
      if (size > 1024 * 1024) {
        parts.add('${(size / (1024 * 1024)).toStringAsFixed(1)} MB');
      } else if (size > 1024) {
        parts.add('${(size / 1024).toStringAsFixed(1)} KB');
      } else {
        parts.add('$size B');
      }
    }
    return parts.join(' · ');
  }

  // Parallel results: "3 done, 1 failed"
  if (data.containsKey('results') && data['results'] is List) {
    final results = data['results'] as List;
    // Only count as failed if explicitly success==false or has error field
    final fail = results.where((r) => r is Map &&
        (r['success'] == false || (r['error'] != null && r['error'].toString().isNotEmpty))).length;
    final ok = results.length - fail;
    if (fail > 0 && ok > 0) return '$ok done, $fail failed';
    if (fail > 0 && ok == 0) return '$fail failed';
    return '${results.length} done';
  }

  // Read: total_lines or lines count
  if (data.containsKey('total_lines')) {
    final n = data['total_lines'];
    return '$n line${n == 1 ? '' : 's'}';
  }
  if (data.containsKey('lines_written')) {
    final n = data['lines_written'];
    return '$n line${n == 1 ? '' : 's'} written';
  }
  // WsWrite/WsRead result: {path, lines, chars}
  if (data.containsKey('lines') && data.containsKey('chars') &&
      data.containsKey('path') && !data.containsKey('exit_code')) {
    final n = data['lines'];
    return '$n line${n == 1 ? '' : 's'}';
  }
  // WsEdit result: {path, insertions, deletions}
  if (data.containsKey('insertions') && data.containsKey('deletions')) {
    final ins = data['insertions'] as int? ?? 0;
    final del = data['deletions'] as int? ?? 0;
    final parts = <String>[];
    if (ins > 0) parts.add('+$ins');
    if (del > 0) parts.add('-$del');
    if (parts.isNotEmpty) return parts.join(' ');
  }

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

  // Success/error — standardized: success==false OR error non-empty → failed
  final errField = data['error']?.toString() ?? '';
  if (data['success'] == false || errField.isNotEmpty) {
    final err = errField.isNotEmpty ? errField : 'failed';
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
/// Public entry point — prepends the tool's visible params (when
/// the daemon provided a `visible_params` hint) to whatever the
/// per-tool core preview returns. Keeps every per-tool branch
/// focused on its own result shape without needing to remember to
/// merge params in.
List<_PreviewLine>? _buildPreview(ToolCall t, {bool showAll = false}) {
  final prefix = _paramLines(t);
  final core = _buildPreviewCore(t, showAll: showAll);
  if (core == null || core.isEmpty) {
    return prefix.isEmpty ? null : prefix;
  }
  if (prefix.isEmpty) return core;
  return [...prefix, ...core];
}

List<_PreviewLine>? _buildPreviewCore(ToolCall t, {bool showAll = false}) {
  if (t.result == null && t.error == null) return null;

  // ── Error ──────────────────────────────────────────────────────────
  if (t.status == 'failed') {
    final msg = t.error ?? (t.result is Map ? t.result['error']?.toString() : null) ?? 'Error';
    return msg.split('\n').take(showAll ? 9999 : 5).map((l) => _PreviewLine(l, 'error')).toList();
  }

  final r = t.result;
  if (r == null) return null;

  // ── ask_user / approval: show question + answer cleanly ──────────
  if (t.name.toLowerCase().contains('ask_user') ||
      (r is Map && r.containsKey('user_response'))) {
    if (r is Map) {
      final lines = <_PreviewLine>[];
      final status = r['status'] as String? ?? '';
      final question = r['question'] as String? ??
          t.params['question'] as String? ??
          t.displayDetail;
      final response = r['user_response'] as String? ??
          r['raw_response'] as String? ??
          r['answer'] as String? ??
          r['message'] as String? ?? '';

      // Question
      if (question.isNotEmpty) {
        lines.add(_PreviewLine('Q: $question', 'summary'));
      }

      // Choices selected
      final choices = r['choices'] as List? ??
          t.params['choices'] as List?;
      if (choices != null && choices.isNotEmpty && response.isNotEmpty) {
        for (final c in choices) {
          final label = c is String ? c : (c is Map ? c['label'] ?? c.toString() : c.toString());
          final selected = response.contains(label.toString());
          lines.add(_PreviewLine(
            '${selected ? "● " : "○ "}$label',
            selected ? 'add' : 'context',
          ));
        }
      } else if (response.isNotEmpty) {
        // Simple text answer
        lines.add(_PreviewLine('A: $response', 'output'));
      }

      // Form fields
      final form = r['form_data'] as Map? ??
          r['form'] as Map?;
      if (form != null && form.isNotEmpty) {
        for (final entry in form.entries) {
          lines.add(_PreviewLine(
            '${entry.key}: ${entry.value}', 'output'));
        }
      }

      // Content review
      final content = r['content'] as String? ??
          t.params['content'] as String?;
      if (content != null && content.isNotEmpty && lines.length <= 2) {
        final preview = content.length > 100
            ? '${content.substring(0, 100)}…'
            : content;
        lines.add(_PreviewLine(preview, 'context'));
      }

      // Status badge if no response
      if (response.isEmpty && status.isNotEmpty && lines.length <= 1) {
        lines.add(_PreviewLine(
          status == 'approved' ? '✓ Approved' : '✗ Denied',
          status == 'approved' ? 'add' : 'error',
        ));
      }

      return lines.isEmpty ? null : lines;
    }
  }

  // ── HTTP request/response — compact, no duplication with brief ────
  if (r is Map && r.containsKey('status_code') && r.containsKey('method')) {
    // The brief already shows "GET 200 OK · 4.6 KB"
    // Preview only shows extra info not in the brief
    final code = r['status_code'] as num? ?? 0;
    final hint = r['hint'] as String? ?? '';
    final body = r['body'];

    if (code >= 400 || (hint.isNotEmpty && hint != 'Success.')) {
      final lines = <_PreviewLine>[];
      if (hint.isNotEmpty && hint != 'Success.') {
        lines.add(_PreviewLine(hint, code >= 400 ? 'error' : 'output'));
      }
      return lines.isEmpty ? null : lines;
    }

    // For success: only show body keys if interesting
    if (body is Map && body.isNotEmpty) {
      final bodyKeys = body.keys.take(5).join(', ');
      return [_PreviewLine('{$bodyKeys${body.length > 5 ? ", …" : ""}}', 'output')];
    }
    // No extra info needed — brief is enough
    return null;
  }

  // ── Filesystem / Workspace file operations (read/write/edit/glob/grep/delete)
  final filePreview = _filePreview(t, showAll: showAll);
  if (filePreview != null) return filePreview;

  // ── Bash/Shell result: exit_code + output ───────────────────────────
  if (r is Map && r.containsKey('exit_code')) {
    final exitCode = r['exit_code'];
    final output = (r['output'] as String? ?? r['stdout'] as String? ?? '').trim();
    final stderr = (r['stderr'] as String? ?? '').trim();
    final nonZero = exitCode is int && exitCode != 0;
    if (output.isNotEmpty) {
      return _truncatedLines(output, nonZero ? 'error' : 'output',
          showAll: showAll);
    }
    if (stderr.isNotEmpty) {
      return _truncatedLines(stderr, 'error', showAll: showAll);
    }
    return null;
  }

  // ── Parallel sub-results (run_parallel) ────────────────────────────
  if (r is Map && r.containsKey('results') && r['results'] is List) {
    final results = r['results'] as List;
    final lines = <_PreviewLine>[];

    // Header summary line: "3 done, 1 failed" — already shown by brief,
    // but here we add a richer "N parallel actions" header
    final total = results.length;
    final failed = results.where((s) =>
        s is Map && (s['success'] == false ||
            (s['error'] != null && s['error'].toString().isNotEmpty))).length;
    final done = total - failed;
    final summaryParts = <String>[];
    if (done > 0) summaryParts.add('$done done');
    if (failed > 0) summaryParts.add('$failed failed');
    if (summaryParts.isNotEmpty) {
      lines.add(_PreviewLine(
          '$total parallel actions · ${summaryParts.join(", ")}',
          'summary'));
    }

    final limit = showAll ? results.length : 8;
    for (int i = 0; i < results.length && i < limit; i++) {
      final sub = results[i];
      if (sub is! Map) continue;
      final isFailed = sub['success'] == false ||
          (sub['error'] != null && sub['error'].toString().isNotEmpty);
      final icon = isFailed ? '✗' : '✓';
      final label = _prettyActionLabel(sub);
      final detail = _prettyActionDetail(sub);
      final err = sub['error'] as String? ?? '';
      final brief = isFailed
          ? (err.length > 60 ? '${err.substring(0, 60)}…' : err)
          : _subBrief(sub);

      // Line 1: icon + label (+ detail on same line if short)
      final combinedDetail = detail.isNotEmpty ? '  $detail' : '';
      final combinedBrief = brief.isNotEmpty ? '  · $brief' : '';
      lines.add(_PreviewLine(
          '$icon $label$combinedDetail$combinedBrief',
          isFailed ? 'error' : 'output'));
    }
    if (!showAll && results.length > 8) {
      lines.add(_PreviewLine('… +${results.length - 8} more', 'summary'));
    } else if (showAll && results.length > 8) {
      lines.add(_PreviewLine('Show less', 'summary'));
    }
    return lines.isEmpty ? null : lines;
  }

  // String result → show directly
  if (r is String) {
    if (r.isEmpty) return null;
    return _truncatedLines(r, 'output', showAll: showAll);
  }

  if (r is! Map) return null;
  final data = r;
  final lines = <_PreviewLine>[];

  // ── Summary line first (like Claude Code "Wrote N lines to path") ──
  final summary = _buildSummaryLine(t, data);
  if (summary != null) lines.add(_PreviewLine(summary, 'summary'));

  // ── Full diff from previous_content + new_content (daemon v2) ──────
  if (t.hasFullDiff) {
    final oldText = _stripLineNos(t.previousContent!);
    final newText = _stripLineNos(t.newContent!);
    final oldLines = oldText.split('\n');
    final newLines = newText.split('\n');

    // Show changed lines
    int shown = 0;
    final maxShow = showAll ? 999999 : 4;
    int oi = 0, ni = 0;
    while (oi < oldLines.length && ni < newLines.length && shown < maxShow) {
      if (oldLines[oi] == newLines[ni]) {
        oi++; ni++;
        continue;
      }
      // Show deletion then addition
      if (oi < oldLines.length) {
        lines.add(_PreviewLine('-${oldLines[oi]}', 'del', lineNo: oi + 1));
        oi++; shown++;
      }
      if (ni < newLines.length && shown < maxShow) {
        lines.add(_PreviewLine('+${newLines[ni]}', 'add', lineNo: ni + 1));
        ni++; shown++;
      }
    }
    // Remaining additions
    while (ni < newLines.length && shown < maxShow) {
      lines.add(_PreviewLine('+${newLines[ni]}', 'add', lineNo: ni + 1));
      ni++; shown++;
    }
    // Remaining deletions
    while (oi < oldLines.length && shown < maxShow) {
      lines.add(_PreviewLine('-${oldLines[oi]}', 'del', lineNo: oi + 1));
      oi++; shown++;
    }
    // Summary with accurate count
    final remainDel = oldLines.length - oi;
    final remainAdd = newLines.length - ni;
    if (!showAll && (remainDel + remainAdd > 0)) {
      final parts = <String>[];
      if (remainAdd > 0) parts.add('+$remainAdd');
      if (remainDel > 0) parts.add('-$remainDel');
      lines.add(_PreviewLine('… ${parts.join(', ')} lines', 'summary'));
    } else if (showAll && (oldLines.length > 4 || newLines.length > 4)) {
      lines.add(_PreviewLine('Show less', 'summary'));
    }
    return lines.isEmpty ? null : lines;
  }

  // ── Diff (edit) with line numbers — fallback to result.diff ─────────
  if (data.containsKey('diff')) {
    final diff = _stripLineNos((data['diff'] as String? ?? '').trim());
    if (diff.isNotEmpty) {
      final allLines = diff.split('\n');
      int addLineNo = 1;
      int delLineNo = 1;
      final limit = showAll ? allLines.length : 4;
      for (final l in allLines.take(limit)) {
        if (l.startsWith('+')) {
          lines.add(_PreviewLine(l, 'add', lineNo: addLineNo++));
        } else if (l.startsWith('-')) {
          lines.add(_PreviewLine(l, 'del', lineNo: delLineNo++));
        } else {
          lines.add(_PreviewLine(l, 'context', lineNo: addLineNo++));
          delLineNo++;
        }
      }
      if (!showAll && allLines.length > 4) {
        lines.add(_PreviewLine('… +${allLines.length - 4} lines', 'summary'));
      } else if (showAll && allLines.length > 4) {
        lines.add(_PreviewLine('Show less', 'summary'));
      }
      return lines;
    }
  }

  // ── Content (write/read) — IDE-style with line numbers ─────────────
  final lower = t.name.toLowerCase();
  final isWrite = lower.contains('write') || lower.contains('create');
  if (data.containsKey('content')) {
    final content = _stripLineNos((data['content'] as String? ?? '').trim());
    if (content.isNotEmpty) {
      final allLines = content.split('\n');
      final limit = showAll ? allLines.length : 4;
      for (int i = 0; i < allLines.length && i < limit; i++) {
        if (isWrite) {
          lines.add(_PreviewLine('+${allLines[i]}', 'add', lineNo: i + 1));
        } else {
          lines.add(_PreviewLine(allLines[i], 'code', lineNo: i + 1));
        }
      }
      if (!showAll && allLines.length > 4) {
        lines.add(_PreviewLine('… +${allLines.length - 4} lines', 'summary'));
      } else if (showAll && allLines.length > 4) {
        lines.add(_PreviewLine('Show less', 'summary'));
      }
      return lines.isEmpty ? null : lines;
    }
  }

  // ── Output (bash, shell, any command) — IDE-style with line numbers ─
  if (data.containsKey('output') || data.containsKey('stderr') || data.containsKey('stdout')) {
    final commandStr = t.params['command'] as String? ?? data['command'] as String? ?? '';
    // Only surface the command line when the header's `detail`
    // doesn't already show it — avoids the "command in header AND
    // command as first preview line" duplication.
    if (commandStr.isNotEmpty && !_headerShows(t, commandStr)) {
      lines.add(_PreviewLine(commandStr, 'command'));
    }

    final out = _stripLineNos((data['output'] as String? ?? data['stdout'] as String? ?? '').trim());
    final stderr = (data['stderr'] as String? ?? '').trim();

    // Stdout lines with line numbers
    if (out.isNotEmpty) {
      final allLines = out.split('\n');
      final limit = showAll ? allLines.length : 4;
      for (int i = 0; i < allLines.length && i < limit; i++) {
        lines.add(_PreviewLine(allLines[i], 'bash_output', lineNo: i + 1));
      }
      if (!showAll && allLines.length > 4) {
        lines.add(_PreviewLine('… +${allLines.length - 4} lines', 'summary'));
      } else if (showAll && allLines.length > 4) {
        lines.add(_PreviewLine('Show less', 'summary'));
      }
    }

    // Stderr lines (red, no line numbers)
    if (stderr.isNotEmpty) {
      final stderrLines = stderr.split('\n');
      final limit = showAll ? stderrLines.length : 6;
      for (final l in stderrLines.take(limit)) {
        lines.add(_PreviewLine(l, 'error'));
      }
      if (!showAll && stderrLines.length > 6) {
        lines.add(_PreviewLine('… +${stderrLines.length - 6} more', 'summary'));
      } else if (showAll && stderrLines.length > 6) {
        lines.add(_PreviewLine('Show less', 'summary'));
      }
    }

    return lines.isEmpty ? null : lines;
  }

  // ── Stderr only ───────────────────────────────────────────────────
  if (data.containsKey('stderr')) {
    final err = (data['stderr'] as String? ?? '').trim();
    if (err.isNotEmpty) {
      final errLines = err.split('\n');
      final limit = showAll ? errLines.length : 4;
      for (final l in errLines.take(limit)) {
        lines.add(_PreviewLine(l, 'error'));
      }
      if (!showAll && errLines.length > 4) {
        lines.add(_PreviewLine('… +${errLines.length - 4} more', 'summary'));
      } else if (showAll && errLines.length > 4) {
        lines.add(_PreviewLine('Show less', 'summary'));
      }
    }
  }

  // ── Matches (grep, search) ─────────────────────────────────────────
  if (data.containsKey('matches')) {
    final matches = data['matches'];
    if (matches is List && matches.isNotEmpty) {
      final limit = showAll ? matches.length : 6;
      for (final m in matches.take(limit)) {
        if (m is Map) {
          lines.add(_PreviewLine(
            '${m['file'] ?? ''}:${m['line'] ?? ''}  ${m['text'] ?? ''}', 'output'));
        } else {
          lines.add(_PreviewLine(m.toString(), 'output'));
        }
      }
      if (!showAll && matches.length > 6) {
        lines.add(_PreviewLine('… +${matches.length - 6} more', 'summary'));
      } else if (showAll && matches.length > 6) {
        lines.add(_PreviewLine('Show less', 'summary'));
      }
    }
  }

  // ── Files list (glob, find) ────────────────────────────────────────
  if (data.containsKey('files')) {
    final files = data['files'];
    if (files is List && files.isNotEmpty) {
      final limit = showAll ? files.length : 6;
      for (final f in files.take(limit)) {
        lines.add(_PreviewLine(f.toString(), 'output'));
      }
      if (!showAll && files.length > 6) {
        lines.add(_PreviewLine('… +${files.length - 6} more', 'summary'));
      } else if (showAll && files.length > 6) {
        lines.add(_PreviewLine('Show less', 'summary'));
      }
    }
  }

  // ── Results list (web search, etc.) ────────────────────────────────
  if (data.containsKey('results')) {
    final results = data['results'];
    if (results is List && results.isNotEmpty) {
      final limit = showAll ? results.length : 6;
      for (final r in results.take(limit)) {
        if (r is Map) {
          final title = r['title'] ?? r['name'] ?? r['url'] ?? '';
          lines.add(_PreviewLine(title.toString(), 'output'));
        } else {
          lines.add(_PreviewLine(r.toString(), 'output'));
        }
      }
      if (!showAll && results.length > 6) {
        lines.add(_PreviewLine('… +${results.length - 6} more', 'summary'));
      } else if (showAll && results.length > 6) {
        lines.add(_PreviewLine('Show less', 'summary'));
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
        if (v.isNotEmpty) return _truncatedLines(v, 'output', showAll: showAll);
      }
    }
  }

  // ── Final fallback: structured rendering of any Map shape ──────────
  // Catches every unknown tool (rag_query, http_json_api, any MCP tool
  // that returns a custom JSON shape) so the preview is never empty.
  // Pass the tool so the generic pass can honour `visible_params` and
  // skip values already shown in the header.
  if (lines.isEmpty) {
    return _genericPreview(data, showAll: showAll, tool: t);
  }

  return lines.isEmpty ? null : lines;
}

// ───────────────────────────────────────────────────────────────────────────
//  Filesystem / Workspace file-operation previews
// ───────────────────────────────────────────────────────────────────────────

const _fileVerbs = {
  'read', 'write', 'edit', 'glob', 'grep', 'delete',
  'wsread', 'wswrite', 'wsedit', 'wsglob', 'wsgrep', 'wsdelete',
};

/// Normalise tool name → operation verb (read/write/edit/glob/grep/delete)
/// or empty string if this is not a file tool.
String _fileOp(ToolCall t) {
  String norm(String s) => s.toLowerCase().replaceFirst(RegExp(r'^ws'), '');

  // 1. Explicit group
  final g = t.group.toLowerCase();
  final byGroup = g == 'filesystem' || g == 'workbench' || g == 'workspace';

  // 2. Name suffix (`filesystem.read`, `workspace.wsread`, …).
  final nameTail = t.name.toLowerCase().split('.').last;
  final nameOp = norm(nameTail);
  if (byGroup || _fileVerbs.contains(nameTail) || _fileVerbs.contains('ws$nameTail')) {
    if (['read', 'write', 'edit', 'glob', 'grep', 'delete'].contains(nameOp)) {
      return nameOp;
    }
  }

  // 3. Display verb (`Read`, `WsEdit`, …)
  final verb = norm(t.label);
  if (['read', 'write', 'edit', 'glob', 'grep', 'delete'].contains(verb)) {
    return verb;
  }

  // 4. Shape inference — only when we already suspect a file tool
  if (!byGroup) return '';
  final r = t.result;
  if (r is Map) {
    if (r.containsKey('unified_diff') || r.containsKey('diff')) return 'edit';
    if (r.containsKey('matches')) return 'grep';
    if (r.containsKey('files')) return 'glob';
    if (r['deleted'] == true) return 'delete';
    if (r.containsKey('content')) return 'read';
  }
  return '';
}

/// Extract the target file path from either params, result, or metadata.
String _filePath(ToolCall t) {
  for (final k in ['file_path', 'path', 'filename']) {
    final v = t.params[k];
    if (v is String && v.isNotEmpty) return v;
  }
  final r = t.result;
  if (r is Map) {
    for (final k in ['path', 'file_path']) {
      final v = r[k];
      if (v is String && v.isNotEmpty) return v;
    }
  }
  final m = t.metadata;
  if (m != null) {
    for (final k in ['file_path', 'path']) {
      final v = m[k];
      if (v is String && v.isNotEmpty) return v;
    }
  }
  return '';
}

String _shortPath(String p) {
  if (p.isEmpty) return p;
  if (p.length <= 60) return p;
  final norm = p.replaceAll('\\', '/');
  final parts = norm.split('/');
  if (parts.length <= 2) return p;
  return '…/${parts.sublist(parts.length - 2).join('/')}';
}

/// Router — returns null if [t] is not a file-operation tool.
/// Returns `_shortPath(path)` unless the header already shows the
/// path (display.detail / detail_param) — in which case the empty
/// string so callers drop the path from their preview's header
/// line and keep only the bits unique to the preview (line count,
/// bytes written, match count, …). Prevents the "path shown in
/// header AND path shown as first preview line" duplication.
String _dedupPath(ToolCall t, String path) {
  if (path.isEmpty) return '';
  final shortP = _shortPath(path);
  if (_headerShows(t, path) || _headerShows(t, shortP)) return '';
  return shortP;
}

List<_PreviewLine>? _filePreview(ToolCall t, {bool showAll = false}) {
  switch (_fileOp(t)) {
    case 'read':   return _readPreview(t, showAll: showAll);
    case 'write':  return _writePreview(t, showAll: showAll);
    case 'edit':   return _editPreview(t, showAll: showAll);
    case 'glob':   return _globPreview(t, showAll: showAll);
    case 'grep':   return _grepPreview(t, showAll: showAll);
    case 'delete': return _deletePreview(t);
  }
  return null;
}

// ── READ ───────────────────────────────────────────────────────────────────

List<_PreviewLine>? _readPreview(ToolCall t, {bool showAll = false}) {
  final r = t.result is Map ? t.result as Map : const {};
  final path = _filePath(t);
  final content = (r['content'] as String? ?? '').trim();
  final totalLines = (r['total_lines'] as num?)?.toInt();
  final linesRead = (r['lines_read'] as num?)?.toInt();
  final startLine = (r['start_line'] as num?)?.toInt() ?? 1;
  final range = r['range'] as Map?;
  final rangeStart = (range?['start'] as num?)?.toInt() ?? startLine;
  final isImage = r['is_image'] == true;

  final out = <_PreviewLine>[];

  // Header (clickable). Drop the path when the tool row already
  // shows it — keeps the preview focused on what's NEW (line count).
  final rightLabel = totalLines != null
      ? '${linesRead ?? ''}${linesRead != null ? ' of ' : ''}$totalLines lines'
      : (r['lines'] is num ? '${r['lines']} lines' : '');
  final headerPath = _dedupPath(t, path);
  final header = [
    if (headerPath.isNotEmpty) headerPath,
    if (rightLabel.isNotEmpty) rightLabel,
  ].join(' · ');
  if (header.isNotEmpty) {
    out.add(_PreviewLine(header, 'file_link',
        clickPath: path, clickLine: rangeStart));
  }

  if (isImage) {
    final mime = r['metadata'] is Map ? (r['metadata'] as Map)['image_mime'] : null;
    out.add(_PreviewLine('[image ${mime ?? ''}]'.trim(), 'summary'));
    return out;
  }

  if (content.isEmpty) return out.isEmpty ? null : out;

  final stripped = _stripLineNos(content);
  final codeLines = stripped.split('\n');
  final limit = showAll ? codeLines.length : 6;
  for (int i = 0; i < codeLines.length && i < limit; i++) {
    out.add(_PreviewLine(
      codeLines[i],
      'code',
      lineNo: rangeStart + i,
      clickPath: path,
      clickLine: rangeStart + i,
    ));
  }
  if (codeLines.length > limit) {
    out.add(_PreviewLine(
      showAll ? 'Show less' : '… +${codeLines.length - limit} lines',
      'summary',
    ));
  }
  return out;
}

// ── WRITE ──────────────────────────────────────────────────────────────────

List<_PreviewLine>? _writePreview(ToolCall t, {bool showAll = false}) {
  final r = t.result is Map ? t.result as Map : const {};
  final meta = t.metadata ?? const {};
  final path = _filePath(t);

  // Filesystem Write: metadata has bytes_written / lines.
  // Workspace WsWrite: result has size / lines / lint.
  final lines = (r['lines'] as num?)?.toInt()
      ?? (meta['lines'] as num?)?.toInt();
  final bytes = (meta['bytes_written'] as num?)?.toInt()
      ?? (r['size'] as num?)?.toInt()
      ?? (meta['file_size'] as num?)?.toInt();
  final operation = (meta['operation'] as String?) ??
      (r['mode'] as String?) ?? 'create';

  final headerPath = _dedupPath(t, path);
  final headerParts = <String>[
    if (headerPath.isNotEmpty) headerPath,
    if (lines != null) '$lines line${lines == 1 ? '' : 's'}',
    if (bytes != null) _formatBytes(bytes),
  ];
  if (operation == 'append') headerParts.insert(0, '(append)');

  final out = <_PreviewLine>[];
  if (headerParts.isNotEmpty) {
    out.add(_PreviewLine(headerParts.join(' · '), 'file_link',
        clickPath: path, clickLine: 1));
  }

  // Content — prefer params.content, else result.content.
  final content = (t.params['content'] as String? ??
      r['content'] as String? ?? '').trim();
  if (content.isNotEmpty) {
    final stripped = _stripLineNos(content);
    final code = stripped.split('\n');
    final limit = showAll ? code.length : 6;
    for (int i = 0; i < code.length && i < limit; i++) {
      out.add(_PreviewLine(code[i], 'add',
          lineNo: i + 1, clickPath: path, clickLine: i + 1));
    }
    if (code.length > limit) {
      out.add(_PreviewLine(
        showAll ? 'Show less' : '… +${code.length - limit} lines',
        'summary',
      ));
    }
  }

  // Workspace lint output
  final lint = r['lint'];
  if (lint is List && lint.isNotEmpty) {
    final errs = (r['errors'] as num?)?.toInt() ?? 0;
    final warns = (r['warnings'] as num?)?.toInt() ?? 0;
    out.add(_PreviewLine(
      'lint: $errs error${errs == 1 ? '' : 's'}, '
          '$warns warning${warns == 1 ? '' : 's'}',
      warns > 0 || errs > 0 ? 'summary' : 'output',
    ));
    final lim = showAll ? lint.length : 4;
    for (var i = 0; i < lint.length && i < lim; i++) {
      final it = lint[i];
      if (it is! Map) continue;
      final line = it['line'];
      final col = it['column'];
      final sev = it['severity']?.toString() ?? '';
      final msg = it['message']?.toString() ?? '';
      final pos = [if (line != null) '$line', if (col != null) '$col'].join(':');
      out.add(_PreviewLine(
        '$sev${pos.isNotEmpty ? ' @ $pos' : ''}: $msg',
        sev == 'error' ? 'error' : 'summary',
        clickPath: path,
        clickLine: line is num ? line.toInt() : 0,
      ));
    }
  }

  return out.isEmpty ? null : out;
}

String _formatBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
}

// ── EDIT ───────────────────────────────────────────────────────────────────

List<_PreviewLine>? _editPreview(ToolCall t, {bool showAll = false}) {
  final r = t.result is Map ? t.result as Map : const {};
  final meta = t.metadata ?? const {};
  final path = _filePath(t);

  // Failure: suggestion + closest matches.
  final notFound = r['not_found'] == true ||
      (t.error != null && t.error!.contains('not found'));
  if (notFound) {
    final out = <_PreviewLine>[];
    final suggestion = r['suggestion'] as String? ??
        meta['suggestion'] as String? ?? '';
    final shortP = _dedupPath(t, path);
    if (shortP.isNotEmpty) {
      out.add(_PreviewLine(shortP, 'file_link',
          clickPath: path, clickLine: 1));
    }
    out.add(_PreviewLine(t.error ?? 'old_string not found', 'error'));
    final closest = (r['closest_matches'] ?? meta['closest_matches']) as List?;
    if (closest != null && closest.isNotEmpty) {
      out.add(_PreviewLine('Closest matches:', 'summary'));
      for (final m in closest.take(showAll ? closest.length : 3)) {
        if (m is! Map) continue;
        final range = m['line_range'] ??
            '${m['start_line'] ?? ''}-${m['end_line'] ?? ''}';
        final sim = m['similarity'];
        final text = (m['text'] as String? ?? '').trim();
        out.add(_PreviewLine(
          '  L$range${sim != null ? " ($sim)" : ""}: ${text.length > 60 ? "${text.substring(0, 60)}…" : text}',
          'output',
          clickPath: path,
          clickLine: int.tryParse(range.toString().split('-').first) ?? 0,
        ));
      }
    } else if (suggestion.isNotEmpty) {
      out.add(_PreviewLine(suggestion, 'output'));
    }
    return out;
  }

  // Build diff lines via the best available source.
  final out = <_PreviewLine>[];
  final insertions = (r['replacements'] as num?)?.toInt() ??
      (meta['lines_changed'] as num?)?.toInt();
  final headerPath = _dedupPath(t, path);
  final header = [
    if (headerPath.isNotEmpty) headerPath,
    if (insertions != null) '$insertions change${insertions == 1 ? '' : 's'}',
  ].join(' · ');
  if (header.isNotEmpty) {
    out.add(_PreviewLine(header, 'file_link',
        clickPath: path, clickLine: 1));
  }

  List<diff_lib.DiffLine>? computed;
  final unified = t.unifiedDiff ?? r['unified_diff'] as String?;
  if (unified != null && unified.trim().isNotEmpty) {
    computed = parseUnifiedDiff(unified);
  } else if (t.hasFullDiff) {
    computed = diff_lib.computeLineDiff(
      _stripLineNos(t.previousContent!),
      _stripLineNos(t.newContent!),
    );
  } else {
    // Fallback — params.old_string → params.new_string. Simple replace.
    final oldStr = (t.params['old_string'] as String? ?? '').trim();
    final newStr = (t.params['new_string'] as String? ?? '').trim();
    if (oldStr.isNotEmpty || newStr.isNotEmpty) {
      computed = diff_lib.computeLineDiff(oldStr, newStr);
    }
  }

  if (computed != null && computed.isNotEmpty) {
    final limit = showAll ? computed.length : 10;
    for (int i = 0; i < computed.length && i < limit; i++) {
      final dl = computed[i];
      out.add(_PreviewLine(
        dl.text,
        switch (dl.type) {
          diff_lib.DiffLineType.added => 'add',
          diff_lib.DiffLineType.removed => 'del',
          _ => 'context',
        },
        lineNo: dl.lineNum,
        clickPath: path,
        clickLine: dl.lineNum,
      ));
    }
    if (computed.length > limit) {
      out.add(_PreviewLine(
        showAll ? 'Show less' : '… +${computed.length - limit} lines',
        'summary',
      ));
    }
  } else {
    // Last resort — textual diff summary (filesystem "Changes:\n  Line 9:\n    - …")
    final diffText = t.diff ?? r['diff'] as String? ?? '';
    if (diffText.trim().isNotEmpty) {
      final dl = diffText.split('\n');
      final limit = showAll ? dl.length : 6;
      for (int i = 0; i < dl.length && i < limit; i++) {
        final l = dl[i].trimRight();
        final trimmed = l.trimLeft();
        if (trimmed.startsWith('+')) {
          out.add(_PreviewLine(trimmed.substring(1).trimLeft(), 'add'));
        } else if (trimmed.startsWith('-')) {
          out.add(_PreviewLine(trimmed.substring(1).trimLeft(), 'del'));
        } else {
          out.add(_PreviewLine(l, 'summary'));
        }
      }
    }
  }
  return out.isEmpty ? null : out;
}

// ── GLOB ───────────────────────────────────────────────────────────────────

List<_PreviewLine>? _globPreview(ToolCall t, {bool showAll = false}) {
  final r = t.result is Map ? t.result as Map : const {};
  final meta = t.metadata ?? const {};
  final pattern = t.params['pattern'] as String? ?? '';

  // Entries: workspace → result.files (objects); filesystem → metadata.matches
  // (strings) or t.output (newline-separated paths).
  final entries = <Map<String, dynamic>>[];
  if (r['files'] is List) {
    for (final f in r['files'] as List) {
      if (f is Map) {
        entries.add(Map<String, dynamic>.from(f));
      } else if (f is String) {
        entries.add({'path': f});
      }
    }
  }
  if (entries.isEmpty && meta['matches'] is List) {
    for (final p in meta['matches'] as List) {
      entries.add({'path': p.toString()});
    }
  }
  if (entries.isEmpty && (t.output ?? '').isNotEmpty) {
    for (final line in t.output!.split('\n')) {
      final p = line.trim();
      if (p.isNotEmpty) entries.add({'path': p});
    }
  }

  final count = (r['count'] as num?)?.toInt() ??
      (meta['num_matches'] as num?)?.toInt() ??
      entries.length;
  final truncated = meta['truncated'] == true;

  // Pattern is almost always the tool header's `display.detail`
  // already — drop it from the summary line to avoid duplication.
  final showPattern = pattern.isNotEmpty && !_headerShows(t, pattern);
  final out = <_PreviewLine>[
    _PreviewLine(
      '$count file${count == 1 ? '' : 's'}'
          '${showPattern ? " · $pattern" : ""}'
          '${truncated ? " · truncated" : ""}',
      'summary',
    ),
  ];
  if (entries.isEmpty) return out;

  final limit = showAll ? entries.length : 8;
  for (int i = 0; i < entries.length && i < limit; i++) {
    final e = entries[i];
    final path = e['path'] as String? ?? '';
    if (path.isEmpty) continue;
    final size = e['size'];
    final lines = e['lines'];
    final meta2 = [
      if (lines != null) '$lines L',
      if (size is num) _formatBytes(size.toInt()),
    ].join(' · ');
    out.add(_PreviewLine(
      meta2.isEmpty ? path : '$path    $meta2',
      'file_link',
      clickPath: path,
    ));
  }
  if (entries.length > limit) {
    out.add(_PreviewLine(
      showAll ? 'Show less' : '… +${entries.length - limit} more',
      'summary',
    ));
  }
  return out;
}

// ── GREP ───────────────────────────────────────────────────────────────────

List<_PreviewLine>? _grepPreview(ToolCall t, {bool showAll = false}) {
  final r = t.result is Map ? t.result as Map : const {};
  final meta = t.metadata ?? const {};
  final pattern = t.params['pattern'] as String? ?? '';

  // Gather matches.
  final matches = <Map<String, dynamic>>[];
  if (r['matches'] is List) {
    for (final m in r['matches'] as List) {
      if (m is Map) matches.add(Map<String, dynamic>.from(m));
    }
  }
  if (matches.isEmpty) {
    // Filesystem: "path:line:text" in output or error.
    final txt = (t.output?.trim().isNotEmpty ?? false)
        ? t.output!
        : (t.error ?? '');
    if (txt.trim().isNotEmpty) {
      for (final line in txt.split('\n')) {
        final m = RegExp(r'^([^:]+):(\d+):(.*)$').firstMatch(line);
        if (m != null) {
          matches.add({
            'path': m.group(1),
            'line': int.tryParse(m.group(2) ?? '') ?? 0,
            'text': m.group(3) ?? '',
          });
        }
      }
    }
  }

  final total = (r['total_matches'] as num?)?.toInt() ??
      (meta['num_matches'] as num?)?.toInt() ??
      matches.length;
  final filesSearched = (r['files_searched'] as num?)?.toInt();
  final fileSet = <String>{for (final m in matches) m['path']?.toString() ?? ''}
    ..removeWhere((p) => p.isEmpty);

  // Pattern is usually already in the tool header (display.detail)
  // — only re-emit it when the header doesn't already show it.
  final showPattern = pattern.isNotEmpty && !_headerShows(t, pattern);
  final out = <_PreviewLine>[
    _PreviewLine(
      '$total match${total == 1 ? '' : 'es'}'
          '${fileSet.isNotEmpty ? " in ${fileSet.length} file${fileSet.length == 1 ? '' : 's'}" : ""}'
          '${filesSearched != null ? " · searched $filesSearched" : ""}'
          '${showPattern ? " · \"$pattern\"" : ""}',
      'summary',
    ),
  ];

  if (matches.isEmpty) return out;

  // Group matches by path; show file header then each line.
  final byFile = <String, List<Map<String, dynamic>>>{};
  for (final m in matches) {
    final p = m['path']?.toString() ?? '';
    byFile.putIfAbsent(p, () => []).add(m);
  }
  final fileLimit = showAll ? byFile.length : 6;
  var shownFiles = 0;
  var shownMatches = 0;
  final maxMatches = showAll ? 9999 : 12;
  for (final entry in byFile.entries) {
    if (shownFiles >= fileLimit || shownMatches >= maxMatches) break;
    shownFiles++;
    out.add(_PreviewLine(entry.key, 'file_link',
        clickPath: entry.key, clickLine: 0));
    for (final m in entry.value) {
      if (shownMatches >= maxMatches) break;
      shownMatches++;
      final line = (m['line'] as num?)?.toInt() ?? 0;
      final text = (m['text'] as String? ?? '').trim();
      out.add(_PreviewLine(
        text,
        'code',
        lineNo: line,
        clickPath: entry.key,
        clickLine: line,
      ));
    }
  }
  if (byFile.length > fileLimit || matches.length > shownMatches) {
    out.add(_PreviewLine(
      showAll
          ? 'Show less'
          : '… +${byFile.length - shownFiles} files, ${matches.length - shownMatches} matches',
      'summary',
    ));
  }
  return out;
}

// ── DELETE ─────────────────────────────────────────────────────────────────

List<_PreviewLine>? _deletePreview(ToolCall t) {
  final path = _filePath(t);
  if (path.isEmpty) return null;
  // If the header already shows the path there's no useful info
  // left for this preview — return null so the expand chevron
  // doesn't appear on something empty.
  final shortP = _dedupPath(t, path);
  if (shortP.isEmpty) return null;
  return [
    _PreviewLine('Deleted $shortP', 'summary'),
  ];
}

/// Render any JSON-ish Map/List/primitive into preview lines.
/// Used as the last-resort fallback when no specialised renderer
/// matches, so new tools get a structured view without code changes.
/// Render the tool's visible params (per `display.visible_params`)
/// as preview lines. Skips params whose value is already visible in
/// the header to avoid duplication. Returns an empty list when the
/// daemon didn't provide a visible-params hint — callers keep their
/// legacy "don't render params" behaviour in that case so unknown
/// tools don't suddenly start dumping schema internals.
///
/// Duplication guards (in order of strictness):
///   1. The daemon-designated `detail_param` is ALWAYS skipped —
///      that param's value is the one that ends up on
///      `display.detail` and is already shown in the header row.
///      This works even when the daemon truncates the header
///      detail (our fuzzy [_headerShows] can't catch that case).
///   2. Any remaining param whose value substring-matches the
///      header detail is also dropped.
/// Keys that carry the WHOLE user-visible content of a file-op tool —
/// the preview body already renders these as a proper diff / code
/// view with line numbers. Showing them again as a one-line
/// `"content: name: chat-cv-upload…"` key-value above the body is
/// redundant and ugly (the body is the truthful render; the param
/// version is just a 139-char truncation).
const Set<String> _bulkContentParamKeys = {
  'content',
  'new_content',
  'previous_content',
  'file_text',
  'text',
  'new_string',
  'old_string',
  'patch',
  'diff',
  'unified_diff',
};

List<_PreviewLine> _paramLines(ToolCall t) {
  if (!t.hasVisibleParamsHint) return const [];
  final out = <_PreviewLine>[];
  final detailParamKey = t.detailParam;
  for (final key in t.visibleParams!) {
    // (1) Daemon said this param IS the header detail — skip.
    if (detailParamKey.isNotEmpty && key == detailParamKey) continue;
    if (!t.params.containsKey(key)) continue;
    // (2) Bulk-content keys — the preview body already renders
    //     these as a diff / numbered code block. Never show them
    //     as a truncated key-value.
    if (_bulkContentParamKeys.contains(key.toLowerCase())) continue;
    final raw = t.params[key];
    if (raw == null) continue;
    final valueStr = raw is String ? raw : raw.toString();
    if (valueStr.trim().isEmpty) continue;
    // (3) Fuzzy header match — catches the "detail without
    //     detail_param" case.
    if (_headerShows(t, valueStr)) continue;
    // Trim long blobs so one noisy param doesn't explode the preview.
    final shown = valueStr.length > 140
        ? '${valueStr.substring(0, 139)}…'
        : valueStr;
    out.add(_PreviewLine('$key: $shown', 'param'));
  }
  return out;
}

/// True if [value] is effectively already visible in the bubble's
/// header — i.e. the preview should skip re-rendering it to avoid
/// the "param shown twice" bug. Matches if:
///   - `display.detail` is exactly the value (after whitespace
///     normalisation), OR
///   - the value is the `display.detail_param` param's value, OR
///   - either string's first ~20 characters prefix the other (the
///     daemon often truncates long paths/commands in `detail`).
bool _headerShows(ToolCall t, String value) {
  if (value.isEmpty) return false;
  String norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
  final v = norm(value);
  if (v.isEmpty) return false;
  final hdr = norm(t.detail);
  if (hdr.isNotEmpty) {
    if (hdr == v) return true;
    // Substring check either direction — handles the common case
    //   detail = "ls -la /…/very/long/path"           (truncated)
    //   value  = "ls -la /Users/me/very/long/path"    (full)
    if (v.contains(hdr) || hdr.contains(v)) return true;
    // Prefix match — covers the case where the daemon uses an
    // ellipsis character that breaks the substring check.
    final prefix = v.length < hdr.length ? v : hdr;
    final other = v.length < hdr.length ? hdr : v;
    if (prefix.length >= 16 && other.startsWith(prefix.substring(0, 16))) {
      return true;
    }
  }
  if (t.detailParam.isNotEmpty) {
    final dp = t.params[t.detailParam];
    if (dp is String && norm(dp) == v) return true;
  }
  return false;
}

/// Keys the generic preview MUST NOT render as key/value lines
/// because they are always surfaced elsewhere (header, diff viewer,
/// dedicated preview branches) or are pure plumbing.
const Set<String> _genericPreviewSkipKeys = {
  'id', 'name', 'label', 'detail', 'display', 'params',
  'success', 'silent', 'hidden', 'category', 'group',
  'channel', 'icon', 'verb', 'visible_params',
  'previous_content', 'new_content', 'content', 'unified_diff', 'diff',
  'command', 'cmd',
  'error',
  // Transport-level metadata never useful in the preview
  'correlation_id', 'session_id', 'app_id', 'seq', 'ts',
};

/// Tool-aware generic preview. When a [ToolCall] is available we
/// also skip any key whose value matches the header detail or the
/// value of the daemon-designated `detail_param`. When the tool
/// declares `display.visible_params` we honour that whitelist to
/// keep custom / MCP tools from splatting raw schema internals.
List<_PreviewLine>? _genericPreview(dynamic value,
    {bool showAll = false, ToolCall? tool}) {
  final lines = <_PreviewLine>[];
  final maxLines = showAll ? 999999 : 12;
  final maxEntries = showAll ? 999999 : 8;
  const maxStringLen = 140;

  String abbr(String s) {
    final clean = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.length <= maxStringLen) return clean;
    return '${clean.substring(0, maxStringLen)}…';
  }

  String inlineValue(dynamic v) {
    if (v == null) return 'null';
    if (v is String) return '"${abbr(v)}"';
    if (v is num || v is bool) return '$v';
    if (v is List) {
      if (v.isEmpty) return '[]';
      return '[${v.length} items]';
    }
    if (v is Map) {
      if (v.isEmpty) return '{}';
      return '{${v.length} fields}';
    }
    return abbr(v.toString());
  }

  void addLine(String text, [String type = 'output']) {
    if (lines.length >= maxLines) return;
    lines.add(_PreviewLine(text, type));
  }

  if (value == null) return null;

  if (value is String) {
    if (value.trim().isEmpty) return null;
    return _truncatedLines(value, 'output');
  }

  if (value is num || value is bool) {
    return [_PreviewLine(value.toString(), 'output')];
  }

  if (value is List) {
    if (value.isEmpty) {
      return [_PreviewLine('(empty list)', 'summary')];
    }
    addLine('${value.length} item${value.length > 1 ? 's' : ''}', 'summary');
    for (int i = 0; i < value.length && i < maxEntries; i++) {
      final item = value[i];
      if (item is Map) {
        final title = item['title'] ??
            item['name'] ??
            item['label'] ??
            item['id'] ??
            item['path'] ??
            item['url'] ??
            '';
        if (title.toString().trim().isNotEmpty) {
          addLine('• ${abbr(title.toString())}');
        } else {
          addLine('• ${inlineValue(item)}');
        }
      } else {
        addLine('• ${inlineValue(item)}');
      }
    }
    if (!showAll && value.length > 8) {
      addLine('… +${value.length - 8} more', 'summary');
    } else if (showAll && value.length > 8) {
      addLine('Show less', 'summary');
    }
    return lines;
  }

  if (value is Map) {
    final m = value.cast<String, dynamic>();
    if (m.isEmpty) return [_PreviewLine('(empty)', 'summary')];

    // Honour the daemon's visible_params whitelist when available:
    // any key NOT in the whitelist is treated as internal schema
    // noise and skipped. Keeps MCP / custom tools clean.
    final Set<String>? whitelist = tool != null && tool.hasVisibleParamsHint
        ? tool.visibleParams!.toSet()
        : null;

    bool hiddenByWhitelist(String key) =>
        whitelist != null && !whitelist.contains(key);

    // Skip values already shown in the bubble header (detail /
    // detail_param) to prevent the "same value shown twice" bug.
    bool duplicatesHeader(dynamic v) {
      if (tool == null) return false;
      if (v is String) return _headerShows(tool, v);
      return false;
    }

    // Surface error first if present
    if (m['success'] == false ||
        (m['error'] != null && m['error'].toString().isNotEmpty)) {
      final err = (m['error'] ?? m['message'] ?? 'error').toString();
      addLine(abbr(err), 'error');
    }

    // Prioritise common "headline" keys
    const headlineKeys = [
      'summary', 'title', 'status',
      'count', 'total', 'url', 'path',
    ];
    final seen = <String>{..._genericPreviewSkipKeys};
    for (final k in headlineKeys) {
      if (!m.containsKey(k) || seen.contains(k)) continue;
      if (hiddenByWhitelist(k)) {
        seen.add(k);
        continue;
      }
      final v = m[k];
      if (v == null) continue;
      if (v is String && v.trim().isEmpty) continue;
      if (duplicatesHeader(v)) {
        seen.add(k);
        continue;
      }
      addLine('$k: ${inlineValue(v)}');
      seen.add(k);
      if (lines.length >= maxLines) break;
    }

    // Then the rest, skipping noisy/redundant fields
    int shown = lines.length;
    for (final entry in m.entries) {
      if (seen.contains(entry.key)) continue;
      if (hiddenByWhitelist(entry.key)) continue;
      if (lines.length >= maxLines) break;
      final v = entry.value;
      if (v == null) continue;
      if (v is String && v.trim().isEmpty) continue;
      if (v is String && v.length > 200) continue; // Skip long content blobs
      if (v is List && v.isEmpty) continue;
      if (v is Map && v.isEmpty) continue;
      if (duplicatesHeader(v)) continue;
      addLine('${entry.key}: ${inlineValue(v)}');
      shown++;
    }

    final remaining = m.keys.where((k) => !seen.contains(k)).length - (shown - lines.length);
    if (remaining > 0) {
      addLine('… +$remaining more fields', 'summary');
    }
    return lines.isEmpty ? null : lines;
  }

  // Unknown type — stringify
  return [_PreviewLine(abbr(value.toString()), 'output')];
}

/// Build a summary line for the tool result (like "Wrote 495 lines to path")
String? _buildSummaryLine(ToolCall t, Map data) {
  final path = data['path'] as String? ?? t.params['path'] as String? ?? '';
  final shortPath = path.length > 50
      ? '…/${path.replaceAll('\\', '/').split('/').last}'
      : path;

  // Detect Ws tools by name
  final toolLower = t.name.toLowerCase();
  final isWsTool = toolLower.contains('ws') || toolLower.contains('workspace');

  // Write (filesystem.write or WsWrite)
  // Don't repeat "Wrote" — the label already says "Write".
  if (data.containsKey('lines_written')) {
    final n = data['lines_written'];
    return '$n line${n == 1 ? '' : 's'}${shortPath.isNotEmpty ? ' to $shortPath' : ''}';
  }
  if (data.containsKey('chars_written')) {
    final n = data['chars_written'];
    return '$n char${n == 1 ? '' : 's'}${shortPath.isNotEmpty ? ' to $shortPath' : ''}';
  }
  if (isWsTool && data.containsKey('lines') && data.containsKey('chars') &&
      (toolLower.contains('write') || toolLower.contains('create'))) {
    final n = data['lines'];
    return '$n line${n == 1 ? '' : 's'}${shortPath.isNotEmpty ? ' to $shortPath' : ''}';
  }

  // Read (filesystem.read or WsRead)
  // Don't repeat "Read" — the label already says it. Just show line count + path.
  if (data.containsKey('total_lines')) {
    final n = data['total_lines'];
    return '$n line${n == 1 ? '' : 's'}${shortPath.isNotEmpty ? ' from $shortPath' : ''}';
  }
  if (isWsTool && data.containsKey('lines') && data.containsKey('content') &&
      toolLower.contains('read')) {
    final n = data['lines'];
    return '$n line${n == 1 ? '' : 's'}${shortPath.isNotEmpty ? ' from $shortPath' : ''}';
  }

  // Edit (filesystem.edit or WsEdit)
  if (data.containsKey('diff') && data.containsKey('path')) {
    return shortPath;
  }
  if (isWsTool && toolLower.contains('edit') && shortPath.isNotEmpty) {
    final ins = data['insertions'] as int? ?? 0;
    final del = data['deletions'] as int? ?? 0;
    final parts = <String>[];
    if (ins > 0) parts.add('+$ins');
    if (del > 0) parts.add('-$del');
    return '$shortPath${parts.isNotEmpty ? ' (${parts.join(' ')})' : ''}';
  }

  if (isWsTool && toolLower.contains('delete') && shortPath.isNotEmpty) {
    return shortPath;
  }

  // WsGlob
  if (isWsTool && toolLower.contains('glob')) {
    final files = data['files'] ?? data['matches'];
    if (files is List) return '${files.length} file${files.length == 1 ? '' : 's'} matched';
  }

  // WsGrep
  if (isWsTool && toolLower.contains('grep')) {
    final matches = data['matches'];
    if (matches is List) return '${matches.length} match${matches.length == 1 ? '' : 'es'}';
  }

  // Bash — don't add summary (brief result already shows exit code inline)
  if (data.containsKey('exit_code')) {
    return null;
  }

  return null;
}

/// Extract a human-friendly label for a parallel sub-result.
/// Tries explicit fields first, then infers the type from the data shape.
String _prettyActionLabel(Map sub) {
  // 1. Daemon-provided display block
  final display = sub['display'];
  if (display is Map) {
    final verb = display['verb'];
    if (verb is String && verb.isNotEmpty) return verb;
  }

  // 2. Explicit label/name fields (including inside result)
  final result = sub['data'] ?? sub['result'];
  for (final source in [sub, if (result is Map) result]) {
    for (final k in ['label', 'tool_name', 'tool', 'name', 'action_type', 'action']) {
      final v = source[k];
      if (v is String && v.isNotEmpty && v != 'action') {
        return _prettifyToolName(v);
      }
    }
  }

  // 3. Infer from result/data shape — guess what the tool did
  final data = sub['data'] ?? sub['result'] ?? sub;
  if (data is Map) {
    // File operations
    if (data.containsKey('lines_written') || data.containsKey('chars_written')) return 'Write';
    if (data.containsKey('total_lines') && data.containsKey('content')) return 'Read';
    if (data.containsKey('diff')) return 'Edit';
    // Search
    if (data.containsKey('matches')) return 'Search';
    if (data.containsKey('files') && data['files'] is List) return 'Glob';
    // HTTP
    if (data.containsKey('status_code') && data.containsKey('method')) {
      return data['method'] as String? ?? 'HTTP';
    }
    // Shell
    if (data.containsKey('exit_code')) return 'Shell';
    // RAG / KB
    if (data.containsKey('chunks') || data.containsKey('documents')) return 'Query';
    // Database
    if (data.containsKey('rows') || data.containsKey('rowcount')) return 'SQL';
    // Memory
    if (data.containsKey('goal')) return 'Set Goal';
    if (data.containsKey('todos')) return 'Update Todo';
    // Ask user
    if (data.containsKey('user_response')) return 'Asked User';
    // File path present → probably a file op
    if (data.containsKey('path') && data.containsKey('content')) return 'Write';
    if (data.containsKey('path') && !data.containsKey('content')) return 'Read';
    // Namespace/collection operations
    if (data.containsKey('namespace') || data.containsKey('collection')) return 'Index';
    // Generic success
    if (data.containsKey('created')) return 'Create';
    if (data.containsKey('deleted')) return 'Delete';
    if (data.containsKey('updated')) return 'Update';
  }

  return 'Action';
}

String _prettifyToolName(String raw) {
  // Split on separators, drop module prefixes
  final segs = raw
      .split(RegExp(r'[._\-/:]+'))
      .where((s) => s.isNotEmpty && s.toLowerCase() != 'mcp')
      .toList();
  if (segs.isEmpty) return raw;
  final last = segs.last;
  final words = last.split('_').where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return last;
  return words
      .map((w) => w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

/// Extract a human-friendly detail (path, url, query, etc.) for a sub-result.
String _prettyActionDetail(Map sub) {
  // Daemon-provided display.detail wins
  final display = sub['display'];
  if (display is Map) {
    final detail = display['detail'];
    if (detail is String && detail.isNotEmpty) return _shortenIfLong(detail);
  }
  // Explicit detail field
  final d = sub['detail'];
  if (d is String && d.isNotEmpty) return _shortenIfLong(d);

  // Try params / args
  final params = (sub['params'] ?? sub['args'] ?? sub['input']) as Map?;
  if (params != null) {
    for (final k in ['path', 'file', 'file_path', 'filename',
                     'url', 'query', 'q', 'command', 'cmd',
                     'pattern', 'key', 'name', 'folder']) {
      final v = params[k];
      if (v is String && v.isNotEmpty) return _shortenIfLong(v);
    }
  }

  // Try top-level fields
  for (final k in ['path', 'url', 'file', 'query', 'command', 'namespace']) {
    final v = sub[k];
    if (v is String && v.isNotEmpty) return _shortenIfLong(v);
  }

  // Try inside data/result
  final data = sub['data'] ?? sub['result'];
  if (data is Map) {
    for (final k in ['path', 'url', 'file', 'query', 'namespace',
                     'collection', 'command']) {
      final v = data[k];
      if (v is String && v.isNotEmpty) return _shortenIfLong(v);
    }
    // HTTP → show url
    if (data.containsKey('status_code') && data.containsKey('url')) {
      return _shortenIfLong(data['url'] as String? ?? '');
    }
  }

  return '';
}

String _shortenIfLong(String v) {
  if (v.length <= 50) return v;
  if (v.contains('/')) return _shortenPath(v);
  return '${v.substring(0, 47)}…';
}

String _shortenPath(String path) {
  final parts = path.replaceAll('\\', '/').split('/');
  if (parts.length <= 2) return path;
  return '…/${parts.sublist(parts.length - 2).join('/')}';
}

/// Enriched brief for a parallel sub-result — covers many module patterns.
String _subBrief(Map sub) {
  final data = sub['data'] ?? sub['result'] ?? sub;
  if (data is! Map) return '';

  // Read / view file
  if (data.containsKey('total_lines')) {
    final n = data['total_lines'];
    return '$n line${n == 1 ? '' : 's'}';
  }
  if (data.containsKey('lines_written')) {
    final n = data['lines_written'];
    return '$n line${n == 1 ? '' : 's'} written';
  }
  if (data.containsKey('chars_written')) {
    final n = data['chars_written'];
    return '$n char${n == 1 ? '' : 's'} written';
  }

  // Bash / shell
  if (data.containsKey('exit_code')) {
    final code = data['exit_code'];
    return code == 0 ? 'ok' : 'exit $code';
  }

  // Search / grep / glob
  if (data.containsKey('matches') && data['matches'] is List) {
    final n = (data['matches'] as List).length;
    return '$n match${n == 1 ? '' : 'es'}';
  }
  if (data.containsKey('count')) {
    final count = data['count'];
    return '$count result${count == 1 ? '' : 's'}';
  }
  if (data.containsKey('results') && data['results'] is List) {
    final n = (data['results'] as List).length;
    return '$n result${n == 1 ? '' : 's'}';
  }
  if (data.containsKey('files') && data['files'] is List) {
    final n = (data['files'] as List).length;
    return '$n file${n == 1 ? '' : 's'}';
  }

  // HTTP
  if (data.containsKey('status_code') && data.containsKey('method')) {
    final method = data['method'];
    final code = data['status_code'];
    return '$method $code';
  }

  // RAG / knowledge base
  if (data.containsKey('chunks') && data['chunks'] is List) {
    final n = (data['chunks'] as List).length;
    return '$n chunk${n == 1 ? '' : 's'}';
  }
  if (data.containsKey('documents') && data['documents'] is List) {
    final n = (data['documents'] as List).length;
    return '$n doc${n == 1 ? '' : 's'}';
  }

  // Database
  if (data.containsKey('rows') && data['rows'] is List) {
    final n = (data['rows'] as List).length;
    return '$n row${n == 1 ? '' : 's'}';
  }
  if (data.containsKey('rowcount')) return '${data['rowcount']} rows';
  if (data.containsKey('affected')) return '${data['affected']} affected';

  // Generic lists
  for (final k in ['items', 'entries', 'records']) {
    final v = data[k];
    if (v is List) {
      return '${v.length} ${k == 'entries' ? 'entr${v.length == 1 ? 'y' : 'ies'}' : k}';
    }
  }

  // Workspace / file operations
  if (data.containsKey('created')) return 'created';
  if (data.containsKey('deleted')) return 'deleted';
  if (data.containsKey('updated')) return 'updated';

  // Boolean success
  if (data['success'] == true) return 'ok';

  return '';
}

List<_PreviewLine> _truncatedLines(String text, String type, {int max = 6, bool showAll = false}) {
  final allLines = text.split('\n');
  final limit = showAll ? allLines.length : max;
  final lines = allLines.take(limit).map((l) => _PreviewLine(l, type)).toList();
  if (!showAll && allLines.length > max) {
    lines.add(_PreviewLine('… +${allLines.length - max} lines', 'summary'));
  } else if (showAll && allLines.length > max) {
    lines.add(_PreviewLine('Show less', 'summary'));
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

// ─── Inline widget block (Digitorn Widgets v1) ──────────────────────────────
//
// Renders an [InlineWidgetPayload] coming from a `widget:render`
// SSE event with `zone: inline`. The block re-uses the full
// widgets v1 runtime (state, data, action dispatcher) by wrapping
// the pane spec in a standard [WidgetHost] — so bindings, forms,
// tool actions and live updates work exactly like in Z2/Z3.
//
// Hooks are built locally so widget actions can push chat
// messages, run tools, open modals and navigate without
// re-plumbing the whole app shell.

class _InlineWidgetBlock extends StatelessWidget {
  final InlineWidgetPayload payload;
  const _InlineWidgetBlock({required this.payload});

  widgets_disp.ActionHooks _buildHooks(BuildContext context) {
    final appState = context.read<AppState>();
    return widgets_disp.ActionHooks(
      // `action: chat` → inject the message into the current chat
      // input and trigger a send.
      chatSender: (msg, {bool silent = false, Map<String, dynamic>? context}) async {
        if (silent) return;
        appState.injectChatMessage(msg);
      },
      // `action: tool` → round-trip through the widgets action
      // endpoint; the daemon knows how to route the tool call.
      toolRunner: (tool, args) async {
        final resp = await widgets_service.WidgetsService().postAction(
          appState.activeApp?.appId ?? '',
          payload: {
            'type': 'tool',
            'payload': {'tool': tool, 'args': args},
          },
        );
        if (resp == null) return null;
        return resp['result'] ?? resp['data'] ?? resp;
      },
      // Modal/workspace/navigate openers stay wired so nested
      // widgets can escalate out of the bubble when needed.
      openModal: (name, ctx) {
        final modal = appState.activeAppWidgets.modals[name];
        if (modal == null) return;
        showDialog(
          context: context,
          builder: (dialogCtx) => AlertDialog(
            content: SizedBox(
              width: modal.width ?? 560,
              child: widgets_host.WidgetHost(
                appId: appState.activeApp?.appId ?? '',
                paneKey: 'modal.$name',
                pane: modal,
                ctx: ctx ?? const {},
                hooks: _buildHooks(context),
              ),
            ),
          ),
        );
      },
      navigate: ({String? appId, String? workspaceTab}) {
        if (workspaceTab != null) {
          appState.isWorkspaceVisible = true;
          SessionService();
          appState.publicNotify();
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final appState = context.read<AppState>();
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      constraints: const BoxConstraints(maxWidth: 640),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      padding: const EdgeInsets.all(12),
      child: widgets_host.WidgetHost(
        key: ValueKey('inline-${payload.widgetId}'),
        appId: appState.activeApp?.appId ?? '',
        paneKey: 'inline.${payload.widgetId}',
        pane: payload.paneSpec,
        ctx: payload.ctx,
        session: {
          'session_id': SessionService().activeSession?.sessionId ?? '',
          'app_id': appState.activeApp?.appId ?? '',
        },
        app: {
          'id': appState.activeApp?.appId ?? '',
          'name': appState.activeApp?.name ?? '',
        },
        hooks: _buildHooks(context),
        // Subscribe this host to the event bus so `widget:update`
        // events targeting this widgetId land back inside it.
        subscribeToEvents: true,
        widgetId: payload.widgetId,
      ),
    );
  }
}

// _TypingSkeleton / _SkeletonBar removed — the chat's "agent is
// thinking" cue is now a single top-level row rendered by ChatPanel
// from the ``_awaitingAgentResponse`` flag. See the new
// ``_ChatTypingSkeleton`` at the bottom of chat_panel.dart.

