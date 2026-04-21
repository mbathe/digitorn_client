/// Keyboard-shortcuts overlay, opened via `Ctrl+/` from anywhere in
/// the app. Lists every keybinding the client registers, grouped by
/// context, so the user doesn't have to hunt the Settings page to
/// remember what `Ctrl+K` does.
///
/// To open: `KeyboardShortcutsSheet.show(context)` — or press the
/// global shortcut from the chat panel tree.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_theme.dart';

class KeyboardShortcutsSheet extends StatelessWidget {
  const KeyboardShortcutsSheet({super.key});

  static void show(BuildContext context) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => const KeyboardShortcutsSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Dialog(
      alignment: Alignment.center,
      backgroundColor: c.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: c.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 18, 14),
              child: Row(
                children: [
                  Icon(Icons.keyboard_alt_outlined, size: 18, color: c.text),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Keyboard shortcuts',
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: c.textBright,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    iconSize: 16,
                    icon: Icon(Icons.close_rounded, color: c.textMuted),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: c.border),
            // Groups
            Flexible(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Group(title: 'GLOBAL', items: const [
                      _Shortcut('Ctrl + P', 'Search everything'),
                      _Shortcut('Ctrl + T', 'Quick switcher (apps + sessions)'),
                      _Shortcut('Ctrl + K', 'Open command palette'),
                      _Shortcut('Ctrl + /', 'Show this shortcuts sheet'),
                      _Shortcut('Ctrl + N', 'New session'),
                      _Shortcut('Escape', 'Stop running agent'),
                    ]),
                    const SizedBox(height: 18),
                    _Group(title: 'CHAT', items: const [
                      _Shortcut('Enter', 'Send message'),
                      _Shortcut('Shift + Enter', 'New line'),
                      _Shortcut('Ctrl + L', 'Clear chat'),
                      _Shortcut('Ctrl + Enter', 'Send even when draft is empty'),
                    ]),
                    const SizedBox(height: 18),
                    _Group(title: 'WORKSPACE · VIEWERS', items: const [
                      _Shortcut('Ctrl + F', 'Find in viewer'),
                      _Shortcut('Ctrl + C', 'Copy selection'),
                      _Shortcut('Ctrl + Shift + F',
                          'Cross-buffer search'),
                    ]),
                    const SizedBox(height: 18),
                    _Group(title: 'NAVIGATION', items: const [
                      _Shortcut('Click logo', 'Back to apps grid'),
                      _Shortcut('Click apps icon', 'Toggle waffle menu'),
                      _Shortcut('Ctrl + K · Diagnostics',
                          'Quick jump to diagnostics'),
                    ]),
                  ],
                ),
              ),
            ),
            // Footer
            Container(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.border)),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded,
                      size: 13, color: c.textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Some shortcuts only work when their panel is focused '
                      '(e.g. viewer find).',
                      style: GoogleFonts.inter(
                          fontSize: 11, color: c.textMuted),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  final String title;
  final List<_Shortcut> items;
  const _Group({required this.title, required this.items});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: GoogleFonts.firaCode(
            fontSize: 10,
            color: c.textMuted,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.border),
          ),
          child: Column(
            children: [
              for (var i = 0; i < items.length; i++) ...[
                _ShortcutRow(shortcut: items[i]),
                if (i < items.length - 1)
                  Divider(height: 1, color: c.border),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Shortcut {
  final String keys;
  final String label;
  const _Shortcut(this.keys, this.label);
}

class _ShortcutRow extends StatelessWidget {
  final _Shortcut shortcut;
  const _ShortcutRow({required this.shortcut});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              shortcut.label,
              style: GoogleFonts.inter(fontSize: 12.5, color: c.text),
            ),
          ),
          for (final part in _parseKeys(shortcut.keys)) ...[
            if (part == '+')
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Text('+',
                    style: GoogleFonts.inter(
                        fontSize: 11, color: c.textMuted)),
              )
            else
              _KeyCap(label: part),
          ],
        ],
      ),
    );
  }

  /// Split "Ctrl + Shift + F" → ["Ctrl", "+", "Shift", "+", "F"] so
  /// we can render each key as its own rounded cap.
  static List<String> _parseKeys(String input) {
    final parts = input.split('+').map((s) => s.trim()).toList();
    final out = <String>[];
    for (var i = 0; i < parts.length; i++) {
      out.add(parts[i]);
      if (i < parts.length - 1) out.add('+');
    }
    return out;
  }
}

class _KeyCap extends StatelessWidget {
  final String label;
  const _KeyCap({required this.label});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 1),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.border),
      ),
      child: Text(
        label,
        style: GoogleFonts.firaCode(
          fontSize: 10.5,
          color: c.textBright,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
