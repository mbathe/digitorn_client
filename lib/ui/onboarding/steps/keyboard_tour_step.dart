import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../design/ds.dart';
import '../../../services/onboarding_service.dart';
import '../../../theme/app_theme.dart';
import '../../ds/ds.dart';
import '../wizard_nav.dart';
import '../wizard_step_scaffold.dart';

class KeyboardTourStep extends StatefulWidget {
  const KeyboardTourStep({super.key});

  @override
  State<KeyboardTourStep> createState() => _KeyboardTourStepState();
}

class _KeyboardTourStepState extends State<KeyboardTourStep> {
  final Set<String> _tried = {};
  final _focus = FocusNode();

  static const _shortcuts = <_Shortcut>[
    _Shortcut(
      id: 'palette',
      label: 'Open command palette',
      keys: ['⌘', 'K'],
      logical: [LogicalKeyboardKey.meta, LogicalKeyboardKey.keyK],
    ),
    _Shortcut(
      id: 'sidebar',
      label: 'Toggle sidebar',
      keys: ['⌘', 'B'],
      logical: [LogicalKeyboardKey.meta, LogicalKeyboardKey.keyB],
    ),
    _Shortcut(
      id: 'chat',
      label: 'Focus chat',
      keys: ['⌘', '/'],
      logical: [LogicalKeyboardKey.meta, LogicalKeyboardKey.slash],
    ),
    _Shortcut(
      id: 'search',
      label: 'Global search',
      keys: ['⌘', '⇧', 'F'],
      logical: [
        LogicalKeyboardKey.meta,
        LogicalKeyboardKey.shift,
        LogicalKeyboardKey.keyF,
      ],
    ),
  ];

  @override
  void initState() {
    super.initState();
    _tried.addAll(OnboardingService().triedShortcuts);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      WizardNav.of(context).setCanAdvance(true);
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    for (final s in _shortcuts) {
      if (_matches(s.logical)) {
        if (!_tried.contains(s.id)) {
          setState(() {
            _tried.add(s.id);
            OnboardingService().triedShortcuts.add(s.id);
          });
        }
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  bool _matches(List<LogicalKeyboardKey> combo) {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    for (final k in combo) {
      final hit = pressed.contains(k) ||
          (k == LogicalKeyboardKey.meta &&
              (pressed.contains(LogicalKeyboardKey.metaLeft) ||
                  pressed.contains(LogicalKeyboardKey.metaRight) ||
                  pressed.contains(LogicalKeyboardKey.controlLeft) ||
                  pressed.contains(LogicalKeyboardKey.controlRight))) ||
          (k == LogicalKeyboardKey.shift &&
              (pressed.contains(LogicalKeyboardKey.shiftLeft) ||
                  pressed.contains(LogicalKeyboardKey.shiftRight)));
      if (!hit) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: WizardStepScaffold(
        eyebrow: 'STEP 04',
        title: 'Learn the shortcuts.',
        subtitle:
            'Digitorn is keyboard-first. Try each combo once — they unlock '
            'everywhere in the app.',
        showSkip: true,
        skipLabel: 'Skip tour',
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (int i = 0; i < _shortcuts.length; i++) ...[
              if (i > 0) SizedBox(height: DsSpacing.x3),
              _ShortcutRow(
                shortcut: _shortcuts[i],
                tried: _tried.contains(_shortcuts[i].id),
              ),
            ],
            SizedBox(height: DsSpacing.x5),
            _TriedCounter(
              tried: _tried.length,
              total: _shortcuts.length,
              accent: c.accentPrimary,
            ),
          ],
        ),
      ),
    );
  }
}

class _Shortcut {
  final String id;
  final String label;
  final List<String> keys;
  final List<LogicalKeyboardKey> logical;
  const _Shortcut({
    required this.id,
    required this.label,
    required this.keys,
    required this.logical,
  });
}

class _ShortcutRow extends StatelessWidget {
  final _Shortcut shortcut;
  final bool tried;
  const _ShortcutRow({required this.shortcut, required this.tried});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AnimatedContainer(
      duration: DsDuration.base,
      curve: DsCurve.decelSnap,
      padding: EdgeInsets.symmetric(
        horizontal: DsSpacing.x5,
        vertical: DsSpacing.x4,
      ),
      decoration: BoxDecoration(
        color: tried ? c.green.withValues(alpha: 0.06) : c.surface,
        borderRadius: BorderRadius.circular(DsRadius.card),
        border: Border.all(
          color: tried
              ? c.green.withValues(alpha: 0.35)
              : c.border,
        ),
      ),
      child: Row(
        children: [
          AnimatedScale(
            scale: tried ? 1 : 0.7,
            duration: DsDuration.base,
            curve: DsCurve.spring,
            child: AnimatedOpacity(
              opacity: tried ? 1 : 0.3,
              duration: DsDuration.base,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: tried ? c.green : c.surfaceAlt,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.check, size: 14, color: c.onAccent),
              ),
            ),
          ),
          SizedBox(width: DsSpacing.x4),
          Expanded(
            child: Text(
              shortcut.label,
              style: DsType.label(color: c.textBright),
            ),
          ),
          DsKbdCombo(keys: shortcut.keys, highlighted: tried),
        ],
      ),
    );
  }
}

class _TriedCounter extends StatelessWidget {
  final int tried;
  final int total;
  final Color accent;
  const _TriedCounter({
    required this.tried,
    required this.total,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Text(
        tried == 0
            ? 'Press a combo — the row will light up.'
            : tried < total
                ? '$tried of $total tried. Keep going.'
                : "All tried. You're ready.",
        style: DsType.caption(
          color: tried == 0 ? c.textMuted : accent,
        ),
      ),
    );
  }
}
