/// Digitorn Widgets v1 — `type: presence` primitive.
///
/// Renders a horizontal strip of avatar circles from a list of
/// users. The daemon is expected to feed `users:` via a data
/// binding (usually `type: stream` on a `/presence` endpoint),
/// each entry shaped like `{id, name, avatar_url?, color?}`.
///
/// Overflow handling: up to [max] circles render; the rest
/// collapse into a `+N` pill. Clicking a circle fires `on_click`
/// with `{user}` in the scope.
///
/// Zero-daemon-required: if the binding is empty the widget
/// renders nothing, so adding this node is safe even when the
/// daemon hasn't implemented presence yet.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../theme/app_theme.dart';
import '../bindings.dart';
import '../models.dart';
import '../runtime.dart';

Widget buildPresence(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final scope = runtime.state.buildScope(extra: extra);
    final users = resolve(node.props['users'], scope);
    final max = asInt(node.props['max']) ?? 5;
    final size = asDouble(node.props['size']) ?? 28;
    final showLabel = node.props['show_label'] == true;
    final onClick = node.actionAt('on_click');

    if (users is! List || users.isEmpty) {
      return const SizedBox.shrink();
    }

    final visible = users.take(max).toList();
    final overflow = users.length - visible.length;

    Widget avatarFor(dynamic user, int index) {
      if (user is! Map) return const SizedBox.shrink();
      final name = user['name']?.toString() ?? '?';
      final avatarUrl = user['avatar_url']?.toString();
      final colorName = user['color']?.toString();
      final color = runtime.semanticColor(colorName, c);
      final initials = _initials(name);
      final inner = Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: avatarUrl == null ? color.withValues(alpha: 0.2) : null,
          shape: BoxShape.circle,
          border: Border.all(color: c.bg, width: 2),
          image: avatarUrl != null
              ? DecorationImage(
                  image: NetworkImage(avatarUrl),
                  fit: BoxFit.cover,
                )
              : null,
        ),
        child: avatarUrl == null
            ? Text(
                initials,
                style: GoogleFonts.inter(
                  fontSize: size * 0.38,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              )
            : null,
      );
      Widget out = Tooltip(
        message: name,
        child: inner,
      );
      if (onClick != null) {
        out = InkWell(
          borderRadius: BorderRadius.circular(size / 2),
          onTap: () => runtime.dispatcher.run(
            onClick,
            context: ctx,
            scopeExtra: {...?extra, 'user': user, 'index': index},
          ),
          child: out,
        );
      }
      return Padding(
        padding: EdgeInsets.only(right: index == visible.length - 1 ? 0 : 8),
        child: out,
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < visible.length; i++) avatarFor(visible[i], i),
        if (overflow > 0) ...[
          const SizedBox(width: 6),
          Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.surfaceAlt,
              shape: BoxShape.circle,
              border: Border.all(color: c.border),
            ),
            child: Text(
              '+$overflow',
              style: GoogleFonts.firaCode(
                fontSize: size * 0.34,
                fontWeight: FontWeight.w700,
                color: c.textMuted,
              ),
            ),
          ),
        ],
        if (showLabel) ...[
          const SizedBox(width: 10),
          Text(
            users.length == 1
                ? '1 person'
                : '${users.length} people',
            style: GoogleFonts.inter(
              fontSize: 11.5,
              color: c.textMuted,
            ),
          ),
        ],
      ],
    );
  });
}

String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty || parts[0].isEmpty) return '?';
  if (parts.length == 1) return parts[0].substring(0, 1).toUpperCase();
  return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
}
