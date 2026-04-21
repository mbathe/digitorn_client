import 'package:flutter/material.dart';

import '../../design/ds.dart';
import '../../theme/app_theme.dart';

/// Keyboard key chip — small mono glyph with inset shadow so it
/// looks physically pressed into the surface. Use for shortcut
/// hints ("Press ⌘K", "Enter to continue"). Chain multiple via
/// the [DsKbdCombo] helper.
class DsKbd extends StatelessWidget {
  final String label;
  final bool highlighted;

  const DsKbd({super.key, required this.label, this.highlighted = false});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final bg = highlighted ? c.accentPrimary : c.surfaceAlt;
    final fg = highlighted ? c.onAccent : c.textBright;
    return Container(
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(DsRadius.xs),
        border: Border.all(
          color: highlighted ? c.accentPrimary : c.border,
        ),
        boxShadow: highlighted
            ? DsElevation.accentGlow(c.accentPrimary, strength: 0.5)
            : [
                BoxShadow(
                  color: c.shadow.withValues(alpha: 0.18),
                  offset: const Offset(0, 1),
                  blurRadius: 0,
                ),
              ],
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: DsType.mono(size: 11, color: fg)
            .copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

class DsKbdCombo extends StatelessWidget {
  final List<String> keys;
  final bool highlighted;
  final double gap;

  const DsKbdCombo({
    super.key,
    required this.keys,
    this.highlighted = false,
    this.gap = 4,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final children = <Widget>[];
    for (int i = 0; i < keys.length; i++) {
      if (i > 0) {
        children.add(Padding(
          padding: EdgeInsets.symmetric(horizontal: gap),
          child: Text('+', style: DsType.micro(color: c.textDim)),
        ));
      }
      children.add(DsKbd(label: keys[i], highlighted: highlighted));
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }
}
