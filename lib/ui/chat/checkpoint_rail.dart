import 'package:flutter/material.dart';
import '../../models/chat_message.dart';
import '../../theme/app_theme.dart';

/// Subtle checkpoint rail — thin vertical timeline on the right of the chat.
/// One dot per message (not per tool call), click to scroll to that message.
class CheckpointRail extends StatelessWidget {
  final List<ChatMessage> messages;
  final ScrollController scrollController;
  final Map<String, GlobalKey> messageKeys;

  const CheckpointRail({
    super.key,
    required this.messages,
    required this.scrollController,
    required this.messageKeys,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    // One checkpoint per message (grouped, not per tool call)
    final checkpoints = <_Checkpoint>[];
    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      if (msg.role == MessageRole.user) {
        checkpoints.add(_Checkpoint(
          type: _CpType.user,
          messageId: msg.id,
        ));
      } else if (msg.role == MessageRole.assistant) {
        // Determine the dominant type for this assistant message
        final hasFailed = msg.toolCalls.any((t) => t.status == 'failed');
        final hasTools = msg.toolCalls.isNotEmpty;
        final hasAgents = msg.agentEvents.isNotEmpty;

        final type = hasFailed
            ? _CpType.error
            : hasAgents
                ? _CpType.agent
                : hasTools
                    ? _CpType.tool
                    : _CpType.response;

        checkpoints.add(_Checkpoint(
          type: type,
          messageId: msg.id,
        ));
      }
    }

    if (checkpoints.length < 3) return const SizedBox.shrink();

    return SizedBox(
      width: 14,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxH = constraints.maxHeight - 32; // minus vertical padding
          const dotH = 10.0; // dot size + min spacing
          // Limit dots to what fits, sampling evenly if too many
          final maxDots = (maxH / dotH).floor().clamp(1, checkpoints.length);
          final sampled = maxDots >= checkpoints.length
              ? checkpoints
              : _sampleEvenly(checkpoints, maxDots);

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              children: [
                for (int i = 0; i < sampled.length; i++) ...[
                  _Dot(
                    checkpoint: sampled[i],
                    onTap: () => _scrollTo(sampled[i].messageId),
                    c: c,
                  ),
                  if (i < sampled.length - 1)
                    Expanded(
                      child: Center(
                        child: Container(
                          width: 0.5,
                          color: c.border.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  /// Sample N items evenly from a list, always including first and last
  List<_Checkpoint> _sampleEvenly(List<_Checkpoint> all, int n) {
    if (n <= 2) return [all.first, all.last];
    final result = <_Checkpoint>[all.first];
    final step = (all.length - 1) / (n - 1);
    for (int i = 1; i < n - 1; i++) {
      result.add(all[(i * step).round()]);
    }
    result.add(all.last);
    return result;
  }

  void _scrollTo(String messageId) {
    final key = messageKeys[messageId];
    if (key == null || key.currentContext == null) return;
    Scrollable.ensureVisible(
      key.currentContext!,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      alignment: 0.15, // Show near the top
    );
  }
}

enum _CpType { user, tool, error, agent, response }

class _Checkpoint {
  final _CpType type;
  final String messageId;
  const _Checkpoint({required this.type, required this.messageId});
}

class _Dot extends StatefulWidget {
  final _Checkpoint checkpoint;
  final VoidCallback onTap;
  final AppColors c;
  const _Dot({
    required this.checkpoint,
    required this.onTap,
    required this.c,
  });

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final cp = widget.checkpoint;
    final c = widget.c;

    final color = switch (cp.type) {
      _CpType.user     => c.blue,
      _CpType.tool     => c.green,
      _CpType.error    => c.red,
      _CpType.agent    => c.cyan,
      _CpType.response => c.textDim,
    };

    // Small subtle dot — grows slightly on hover
    final size = _h ? 6.0 : 4.0;

    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 14,
          height: 14,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _h ? color : color.withValues(alpha: 0.5),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
