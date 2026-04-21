/// Oneshot-mode panel — the app is stateless from the user's
/// perspective: type a prompt, press Run, read the answer, done.
///
/// Conceptually the UI is an API client, not a chat. There is no
/// timeline, no turn history, no session drawer. Under the hood we
/// still spin up a daemon session per run (for cost tracking,
/// replay, audit), but that plumbing is invisible — each Run
/// replaces the previous result on screen.
library;

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../main.dart' show AppState;
import '../../models/chat_message.dart';
import '../../services/api_client.dart';
import '../../services/session_service.dart';
import '../../theme/app_theme.dart';
import '../chat/chat_bubbles.dart';

class OneshotPanel extends StatefulWidget {
  const OneshotPanel({super.key});

  @override
  State<OneshotPanel> createState() => _OneshotPanelState();
}

class _OneshotPanelState extends State<OneshotPanel> {
  final TextEditingController _prompt = TextEditingController();
  final FocusNode _focus = FocusNode();
  final ScrollController _resultScroll = ScrollController();

  // We render exactly two things: the last user message, and the
  // assistant's response. Both are ChatMessage instances so we can
  // reuse the timeline renderer (tool calls, diffs, agent events,
  // widgets — everything a turn can produce).
  ChatMessage? _currentMsg;
  bool _running = false;
  String _statusPhase = '';
  String _lastPrompt = '';

  StreamSubscription? _eventSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _eventSub = SessionService().events.listen(_onEvent);
      _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _prompt.dispose();
    _focus.dispose();
    _resultScroll.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final text = _prompt.text.trim();
    if (text.isEmpty || _running) return;
    final appState = context.read<AppState>();
    final appId = appState.activeApp?.appId;
    if (appId == null) return;

    // Fresh session per run — oneshot apps don't keep context
    // between invocations, so the daemon starts clean each time.
    setState(() {
      _running = true;
      _statusPhase = 'requesting';
      _lastPrompt = text;
      _currentMsg = ChatMessage(
        id: 'oneshot-${DateTime.now().microsecondsSinceEpoch}',
        role: MessageRole.assistant,
      );
      _currentMsg!.setStreamingState(true);
    });

    final created = await SessionService().createAndSetSession(appId);
    if (!created || !mounted) {
      setState(() {
        _running = false;
        _statusPhase = '';
      });
      return;
    }
    final sessionId = SessionService().activeSession?.sessionId;
    if (sessionId == null) return;

    final err = await SessionService().sendMessage(appId, sessionId, text);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _running = false;
        _statusPhase = '';
        _currentMsg?.setStreamingState(false);
        _currentMsg = ChatMessage(
          id: 'err-${DateTime.now().microsecondsSinceEpoch}',
          role: MessageRole.assistant,
          initialText: '**Error:** $err',
        );
      });
    }
  }

  void _onEvent(Map<String, dynamic> event) {
    if (!mounted || _currentMsg == null) return;
    final type = event['type'] as String? ?? '';
    final sid = event['session_id'] as String?;
    final activeId = SessionService().activeSession?.sessionId;
    // Only pick up events for the session we just created.
    if (sid != null && sid.isNotEmpty && sid != activeId) return;

    // Reuse the api_client stream handler so tool calls / tokens /
    // thinking all route into the same ChatMessage and render via
    // the shared ChatBubble widget.
    DigitornApiClient().handleStreamEvent(type, event['data'] ?? {}, _currentMsg!);

    if (type == 'status') {
      final phase =
          ((event['data'] as Map?)?['phase'] as String?) ?? '';
      if (phase.isNotEmpty && mounted) {
        setState(() => _statusPhase = phase);
      }
    }
    if (type == 'result' ||
        type == 'turn_complete' ||
        type == 'turn_end' ||
        type == 'error' ||
        type == 'abort') {
      _currentMsg?.setStreamingState(false);
      _currentMsg?.setThinkingState(false);
      if (mounted) {
        setState(() {
          _running = false;
          _statusPhase = '';
        });
      }
      _scrollToBottom();
    } else {
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_resultScroll.hasClients) return;
      _resultScroll.animateTo(
        _resultScroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  void _newRun() {
    setState(() {
      _currentMsg = null;
      _statusPhase = '';
      _lastPrompt = '';
      _prompt.clear();
    });
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final appState = context.watch<AppState>();
    final manifest = appState.manifest;
    final accent = manifest.accent ?? c.blue;
    final emoji = manifest.icon;
    final name = manifest.name.isNotEmpty
        ? manifest.name
        : (appState.activeApp?.name ?? 'Oneshot App');
    final greeting = manifest.greeting.isNotEmpty
        ? manifest.greeting
        : (appState.activeApp?.greeting ?? '');
    final isSmall = MediaQuery.of(context).size.width < 700;
    final maxW = isSmall ? double.infinity : 820.0;

    return Container(
      color: c.bg,
      child: Column(
        children: [
          _OneshotHeader(
            accent: accent,
            emoji: emoji,
            name: name,
            description: manifest.description,
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxW),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                      horizontal: isSmall ? 14 : 28,
                      vertical: isSmall ? 10 : 18),
                  child: SingleChildScrollView(
                    controller: _resultScroll,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (greeting.isNotEmpty && _currentMsg == null) ...[
                          Text(
                            greeting,
                            textAlign: TextAlign.center,
                            style: GoogleFonts.inter(
                              fontSize: 13.5,
                              color: c.textMuted,
                              height: 1.55,
                            ),
                          ),
                          const SizedBox(height: 20),
                        ],
                        _PromptField(
                          controller: _prompt,
                          focusNode: _focus,
                          disabled: _running,
                          onSubmit: _run,
                          accent: accent,
                        ),
                        const SizedBox(height: 12),
                        _RunRow(
                          accent: accent,
                          running: _running,
                          statusPhase: _statusPhase,
                          onRun: _run,
                          canRun: _prompt.text.trim().isNotEmpty,
                          canReset: _currentMsg != null && !_running,
                          onReset: _newRun,
                        ),
                        if (_currentMsg != null) ...[
                          const SizedBox(height: 24),
                          _ResultCard(
                            prompt: _lastPrompt,
                            message: _currentMsg!,
                            accent: accent,
                            onNewRun: _newRun,
                          ),
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
}

// ─── Header ─────────────────────────────────────────────────────────

class _OneshotHeader extends StatelessWidget {
  final Color accent;
  final String emoji;
  final String name;
  final String description;
  const _OneshotHeader({
    required this.accent,
    required this.emoji,
    required this.name,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: accent.withValues(alpha: 0.3)),
            ),
            child: emoji.isNotEmpty
                ? Text(emoji, style: const TextStyle(fontSize: 15, height: 1))
                : Icon(Icons.bolt_rounded, size: 15, color: accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: c.text)),
                if (description.isNotEmpty)
                  Text(description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                          fontSize: 11, color: c.textDim)),
              ],
            ),
          ),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: accent.withValues(alpha: 0.25)),
            ),
            child: Text('oneshot.title'.tr(),
                style: GoogleFonts.firaCode(
                    fontSize: 10,
                    color: accent,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

// ─── Prompt field ───────────────────────────────────────────────────

class _PromptField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool disabled;
  final VoidCallback onSubmit;
  final Color accent;
  const _PromptField({
    required this.controller,
    required this.focusNode,
    required this.disabled,
    required this.onSubmit,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.inputBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: focusNode.hasFocus
                ? accent.withValues(alpha: 0.6)
                : c.inputBorder),
      ),
      child: Shortcuts(
        shortcuts: {
          LogicalKeySet(
                  LogicalKeyboardKey.enter, LogicalKeyboardKey.meta):
              const _RunIntent(),
          LogicalKeySet(LogicalKeyboardKey.enter,
                  LogicalKeyboardKey.control):
              const _RunIntent(),
        },
        child: Actions(
          actions: {
            _RunIntent: CallbackAction<_RunIntent>(
              onInvoke: (_) {
                if (!disabled) onSubmit();
                return null;
              },
            ),
          },
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            enabled: !disabled,
            minLines: 3,
            maxLines: 10,
            maxLength: 16000,
            onChanged: (_) {
              // rebuild parent so the Run button picks up canRun
              (context as Element).markNeedsBuild();
            },
            style: GoogleFonts.inter(
                fontSize: 14, color: c.text, height: 1.55),
            decoration: InputDecoration(
              hintText: 'oneshot.placeholder'.tr(),
              hintStyle:
                  GoogleFonts.inter(fontSize: 14, color: c.textMuted),
              border: InputBorder.none,
              counterText: '',
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      ),
    );
  }
}

class _RunIntent extends Intent {
  const _RunIntent();
}

// ─── Run button + status line ──────────────────────────────────────

class _RunRow extends StatelessWidget {
  final Color accent;
  final bool running;
  final String statusPhase;
  final VoidCallback onRun;
  final bool canRun;
  final bool canReset;
  final VoidCallback onReset;
  const _RunRow({
    required this.accent,
    required this.running,
    required this.statusPhase,
    required this.onRun,
    required this.canRun,
    required this.canReset,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        if (running) ...[
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
                strokeWidth: 1.6, color: accent),
          ),
          const SizedBox(width: 8),
          Text(
            statusPhase.isEmpty ? 'Running…' : 'Running · $statusPhase',
            style: GoogleFonts.firaCode(fontSize: 11, color: c.textMuted),
          ),
        ] else if (canReset) ...[
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onReset,
              child: Row(
                children: [
                  Icon(Icons.refresh_rounded, size: 13, color: c.textMuted),
                  const SizedBox(width: 4),
                  Text('oneshot.new_run'.tr(),
                      style: GoogleFonts.inter(
                          fontSize: 12, color: c.textMuted)),
                ],
              ),
            ),
          ),
        ],
        const Spacer(),
        MouseRegion(
          cursor: (running || !canRun)
              ? SystemMouseCursors.forbidden
              : SystemMouseCursors.click,
          child: GestureDetector(
            onTap: (running || !canRun) ? null : onRun,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: (running || !canRun)
                    ? c.surfaceAlt
                    : accent,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  if (!running && canRun)
                    BoxShadow(
                      color: accent.withValues(alpha: 0.25),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.play_arrow_rounded,
                    size: 16,
                    color: (running || !canRun)
                        ? c.textDim
                        : Colors.white,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    'Run',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: (running || !canRun)
                          ? c.textDim
                          : Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Result card ────────────────────────────────────────────────────

class _ResultCard extends StatelessWidget {
  final String prompt;
  final ChatMessage message;
  final Color accent;
  final VoidCallback onNewRun;
  const _ResultCard({
    required this.prompt,
    required this.message,
    required this.accent,
    required this.onNewRun,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Prompt recap — compact, collapsible feel
          if (prompt.isNotEmpty)
            Container(
              padding:
                  const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: c.surfaceAlt.withValues(alpha: 0.4),
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(12)),
                border: Border(bottom: BorderSide(color: c.border)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.north_east_rounded,
                      size: 13, color: c.textDim),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      prompt,
                      style: GoogleFonts.inter(
                          fontSize: 12, color: c.textMuted, height: 1.5),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: prompt));
                      },
                      child: Icon(Icons.copy_rounded,
                          size: 12, color: c.textDim),
                    ),
                  ),
                ],
              ),
            ),
          // The assistant bubble — reuses the full ChatBubble widget so
          // every renderer (tool calls, diffs, agent events, widgets,
          // markdown) just works, no duplication.
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
            child: ChatBubble(message: message),
          ),
        ],
      ),
    );
  }
}
