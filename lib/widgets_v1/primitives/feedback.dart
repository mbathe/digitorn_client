/// Digitorn Widgets v1 — feedback primitives.
///
/// alert, badge, progress, skeleton.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../theme/app_theme.dart';
import '../bindings.dart';
import '../models.dart';
import '../runtime.dart';
import 'layout.dart' show widgetIconByName;

// ─── alert ────────────────────────────────────────────────────────

Widget buildAlert(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final scope = runtime.state.buildScope(extra: extra);
    final kind = node.props['kind'] as String? ?? 'info';
    final title = evalTemplate(node.props['title'] as String? ?? '', scope);
    final text = evalTemplate(node.props['text'] as String? ?? '', scope);
    final iconName = node.props['icon'] as String?;
    final dismissible = node.props['dismissible'] == true;
    final action = node.actionAt('action');
    final actionLabel = node.props['action'] is Map
        ? (node.props['action'] as Map)['label']?.toString()
        : null;
    final (bg, border, fg, defaultIcon) = switch (kind) {
      'success' => (
          c.green.withValues(alpha: 0.08),
          c.green.withValues(alpha: 0.35),
          c.green,
          Icons.check_circle_outline_rounded
        ),
      'warning' => (
          c.orange.withValues(alpha: 0.08),
          c.orange.withValues(alpha: 0.35),
          c.orange,
          Icons.warning_amber_rounded
        ),
      'error' => (
          c.red.withValues(alpha: 0.08),
          c.red.withValues(alpha: 0.35),
          c.red,
          Icons.error_outline_rounded
        ),
      _ => (
          c.blue.withValues(alpha: 0.08),
          c.blue.withValues(alpha: 0.35),
          c.blue,
          Icons.info_outline_rounded
        ),
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            iconName != null ? widgetIconByName(iconName) : defaultIcon,
            size: 17,
            color: fg,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (title.isNotEmpty)
                  Text(
                    title,
                    style: GoogleFonts.inter(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: fg,
                    ),
                  ),
                if (text.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: title.isNotEmpty ? 2 : 0),
                    child: Text(
                      text,
                      style: GoogleFonts.inter(
                        fontSize: 11.5,
                        color: c.text,
                        height: 1.5,
                      ),
                    ),
                  ),
                if (action != null && actionLabel != null) ...[
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: () => runtime.dispatcher.run(
                      action,
                      context: ctx,
                      scopeExtra: extra,
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: fg,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                    ),
                    child: Text(
                      actionLabel,
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (dismissible)
            IconButton(
              icon: Icon(Icons.close_rounded, size: 14, color: fg),
              visualDensity: VisualDensity.compact,
              onPressed: () => runtime.dispatcher.hooks.closeHost?.call(),
            ),
        ],
      ),
    );
  });
}

// ─── badge ────────────────────────────────────────────────────────

Widget buildBadge(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final scope = runtime.state.buildScope(extra: extra);
    final label = evalTemplate(node.props['label'] as String? ?? '', scope);
    final colorName = evalTemplate(node.props['color'] as String? ?? '', scope);
    final variant = node.props['variant'] as String? ?? 'soft';
    final iconName = node.props['icon'] as String?;
    final color = runtime.semanticColor(
      colorName.isEmpty ? 'muted' : colorName,
      c,
    );
    final (bg, fg, border) = switch (variant) {
      'solid' => (color, Colors.white, color),
      'outline' => (Colors.transparent, color, color),
      _ => (color.withValues(alpha: 0.12), color, color.withValues(alpha: 0.4)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (iconName != null) ...[
            Icon(widgetIconByName(iconName), size: 10, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: GoogleFonts.firaCode(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: fg,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  });
}

// ─── progress ─────────────────────────────────────────────────────

Widget buildProgress(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final scope = runtime.state.buildScope(extra: extra);
    final label = evalTemplate(node.props['label'] as String? ?? '', scope);
    final rawValue = node.props['value'];
    final showValue = node.props['show_value'] == true;
    final kind = node.props['kind'] as String? ?? 'bar';
    final indeterminate =
        rawValue == null || rawValue == 'indeterminate' || rawValue == false;
    final v = asDouble(rawValue)?.clamp(0.0, 1.0);
    final accent = runtime.accentColor(node, c);
    if (kind == 'circle') {
      return SizedBox(
        width: 32,
        height: 32,
        child: CircularProgressIndicator(
          value: indeterminate ? null : v,
          strokeWidth: 2.5,
          color: accent,
          backgroundColor: c.surfaceAlt,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label.isNotEmpty || showValue)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                if (label.isNotEmpty)
                  Expanded(
                    child: Text(label,
                        style: GoogleFonts.inter(
                            fontSize: 11, color: c.textMuted)),
                  ),
                if (showValue && v != null)
                  Text(
                    '${(v * 100).toStringAsFixed(0)}%',
                    style: GoogleFonts.firaCode(
                      fontSize: 10.5,
                      color: c.textMuted,
                    ),
                  ),
              ],
            ),
          ),
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: LinearProgressIndicator(
            value: indeterminate ? null : v,
            minHeight: 6,
            color: accent,
            backgroundColor: c.surfaceAlt,
          ),
        ),
      ],
    );
  });
}

// ─── skeleton ─────────────────────────────────────────────────────

Widget buildSkeleton(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final lines = asInt(node.props['lines']) ?? 3;
    final widthRaw = node.props['width'];
    final width = widthRaw is num
        ? widthRaw.toDouble()
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < lines; i++)
          Container(
            width: width ??
                (i == lines - 1 ? double.infinity : double.infinity),
            height: 10,
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              color: c.skeleton,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  });
}
