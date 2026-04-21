/// Digitorn Widgets v1 — action primitives.
///
/// button, icon_button, link, confirm.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../theme/app_theme.dart';
import '../bindings.dart';
import '../models.dart';
import '../runtime.dart';
import 'layout.dart' show widgetIconByName;

// ─── button ───────────────────────────────────────────────────────

Widget buildButton(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final scope = runtime.state.buildScope(extra: extra);
    final label = evalTemplate(node.props['label'] as String? ?? '', scope);
    final iconName = node.props['icon'] as String?;
    final variant = node.props['variant'] as String? ?? 'primary';
    final size = node.props['size'] as String? ?? 'md';
    final fullWidth = node.props['full_width'] == true;
    final loading = evalBool(node.props['loading'] as String?, scope);
    final disabled = evalBool(node.props['disabled'] as String?, scope);
    final action = node.actionAt('action');

    final (pad, fontSize, iconSize) = switch (size) {
      'sm' => (
          const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          11.0,
          12.0
        ),
      'lg' => (
          const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          13.5,
          16.0
        ),
      _ => (
          const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          12.0,
          14.0
        ),
    };

    VoidCallback? onTap;
    if (action != null && !loading && !disabled) {
      onTap = () => runtime.dispatcher.run(
            action,
            context: ctx,
            scopeExtra: extra,
          );
    }

    Widget labelWidget = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (loading)
          SizedBox(
            width: iconSize,
            height: iconSize,
            child: const CircularProgressIndicator(
              strokeWidth: 1.5,
              color: Colors.white,
            ),
          )
        else if (iconName != null)
          Icon(widgetIconByName(iconName), size: iconSize),
        if ((iconName != null || loading) && label.isNotEmpty)
          const SizedBox(width: 8),
        if (label.isNotEmpty)
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );

    Widget btn;
    final accent = runtime.accentColor(node, c);
    switch (variant) {
      case 'primary':
        btn = ElevatedButton(
          onPressed: onTap,
          style: ElevatedButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: Colors.white,
            disabledBackgroundColor: accent.withValues(alpha: 0.4),
            elevation: 0,
            padding: pad,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
          ),
          child: labelWidget,
        );
        break;
      case 'destructive':
        btn = ElevatedButton(
          onPressed: onTap,
          style: ElevatedButton.styleFrom(
            backgroundColor: c.red,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: pad,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
          ),
          child: labelWidget,
        );
        break;
      case 'ghost':
        btn = TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            foregroundColor: c.text,
            padding: pad,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
          ),
          child: labelWidget,
        );
        break;
      case 'link':
        btn = TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            foregroundColor: accent,
            padding: pad,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
          ),
          child: labelWidget,
        );
        break;
      case 'secondary':
      default:
        btn = OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            foregroundColor: c.text,
            side: BorderSide(color: c.border),
            padding: pad,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
          ),
          child: labelWidget,
        );
    }
    return fullWidth ? SizedBox(width: double.infinity, child: btn) : btn;
  });
}

// ─── icon_button ─────────────────────────────────────────────────

Widget buildIconButton(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final iconName = node.props['icon'] as String? ?? 'help_outline';
    final tooltip = node.props['tooltip'] as String? ?? '';
    final variant = node.props['variant'] as String? ?? 'ghost';
    final action = node.actionAt('action');
    final color = variant == 'destructive' ? c.red : c.text;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: action == null
              ? null
              : () => runtime.dispatcher.run(
                    action,
                    context: ctx,
                    scopeExtra: extra,
                  ),
          child: Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            child: Icon(widgetIconByName(iconName), size: 15, color: color),
          ),
        ),
      ),
    );
  });
}

// ─── link ────────────────────────────────────────────────────────

Widget buildLink(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final scope = runtime.state.buildScope(extra: extra);
    final label = evalTemplate(node.props['label'] as String? ?? '', scope);
    final href = evalTemplate(node.props['href'] as String? ?? '', scope);
    final external = node.props['external'] != false;
    final iconName = node.props['icon'] as String?;
    return InkWell(
      onTap: () async {
        final uri = Uri.tryParse(href);
        if (uri == null) return;
        await launchUrl(
          uri,
          mode: external
              ? LaunchMode.externalApplication
              : LaunchMode.inAppWebView,
        );
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 12,
              color: runtime.accentColor(node, c),
              decoration: TextDecoration.underline,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (iconName != null) ...[
            const SizedBox(width: 4),
            Icon(widgetIconByName(iconName),
                size: 11, color: runtime.accentColor(node, c)),
          ],
        ],
      ),
    );
  });
}

// ─── confirm (inline destructive card) ───────────────────────────

Widget buildConfirmNode(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final scope = runtime.state.buildScope(extra: extra);
    final text = evalTemplate(node.props['text'] as String? ?? '', scope);
    final confirmLabel =
        node.props['confirm_label'] as String? ?? 'Confirm';
    final cancelLabel = node.props['cancel_label'] as String? ?? 'Cancel';
    final destructive = node.props['destructive'] == true;
    final confirmAction = node.actionAt('confirm_action');
    final cancelAction = node.actionAt('cancel_action');
    final accent = destructive ? c.red : runtime.accentColor(node, c);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: destructive ? c.red.withValues(alpha: 0.06) : c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: destructive ? c.red.withValues(alpha: 0.35) : c.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                destructive
                    ? Icons.warning_amber_rounded
                    : Icons.help_outline_rounded,
                size: 18,
                color: accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: GoogleFonts.inter(
                    fontSize: 12.5,
                    color: c.text,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Spacer(),
              TextButton(
                onPressed: cancelAction == null
                    ? () => runtime.dispatcher.hooks.closeHost?.call()
                    : () => runtime.dispatcher.run(
                          cancelAction,
                          context: ctx,
                          scopeExtra: extra,
                        ),
                child: Text(
                  cancelLabel,
                  style: GoogleFonts.inter(fontSize: 12, color: c.textMuted),
                ),
              ),
              const SizedBox(width: 6),
              ElevatedButton(
                onPressed: confirmAction == null
                    ? null
                    : () => runtime.dispatcher.run(
                          confirmAction,
                          context: ctx,
                          scopeExtra: extra,
                        ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                ),
                child: Text(
                  confirmLabel,
                  style: GoogleFonts.inter(
                      fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  });
}
