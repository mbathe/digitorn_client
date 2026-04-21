/// Digitorn Widgets v1 — content primitives.
///
/// text, markdown, image, icon.
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../theme/app_theme.dart';
import '../bindings.dart';
import '../models.dart';
import '../runtime.dart';
import 'layout.dart' show widgetIconByName;

Widget buildText(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final scope = runtime.state.buildScope(extra: extra);
    final text = evalTemplate(node.props['text'] as String? ?? '', scope);
    final variant = node.props['variant'] as String? ?? 'body';
    final weight = _weightOf(node.props['weight'] as String?);
    final color = runtime.semanticColor(node.props['color'] as String?, c);
    final maxLines = asInt(node.props['max_lines']);
    final selectable = node.props['selectable'] == true;
    final align = _alignOf(node.props['align']);
    final style = _styleFor(variant, weight, color);
    Widget t = selectable
        ? SelectableText(
            text,
            style: style,
            maxLines: maxLines,
            textAlign: align,
          )
        : Text(
            text,
            style: style,
            maxLines: maxLines,
            overflow:
                maxLines != null ? TextOverflow.ellipsis : TextOverflow.clip,
            textAlign: align,
          );
    return t;
  });
}

Widget buildMarkdown(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final scope = runtime.state.buildScope(extra: extra);
    final rawText = node.props['text'] as String?;
    // `source:` (http loader) not supported v1; rely on `data:` block.
    final text = rawText != null ? evalTemplate(rawText, scope) : '';
    return MarkdownBody(
      data: text,
      selectable: true,
      styleSheet: MarkdownStyleSheet(
        p: GoogleFonts.inter(
          fontSize: 13,
          color: c.text,
          height: 1.55,
        ),
        h1: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w800,
          color: c.textBright,
        ),
        h2: GoogleFonts.inter(
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: c.textBright,
        ),
        h3: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: c.textBright,
        ),
        code: GoogleFonts.firaCode(
          fontSize: 11.5,
          color: c.cyan,
          backgroundColor: c.codeBlockBg,
        ),
        codeblockDecoration: BoxDecoration(
          color: c.codeBlockBg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: c.border),
        ),
      ),
    );
  });
}

Widget buildImage(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final scope = runtime.state.buildScope(extra: extra);
    final src = evalTemplate(node.props['src'] as String? ?? '', scope);
    final width = asDouble(node.props['width']);
    final height = asDouble(node.props['height']);
    final radius = asDouble(node.props['radius']) ?? 8;
    final fit = _boxFit(node.props['fit']);
    if (src.isEmpty) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: c.surfaceAlt,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: c.border),
        ),
        child: Icon(Icons.image_outlined, color: c.textMuted),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(
        src,
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (_, _, _) => Container(
          width: width,
          height: height,
          color: c.surfaceAlt,
          child: Icon(Icons.broken_image_outlined, color: c.textMuted),
        ),
      ),
    );
  });
}

Widget buildIconNode(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final name = node.props['name'] as String? ?? 'help_outline';
    final size = asDouble(node.props['size']) ?? 18;
    final color = runtime.semanticColor(node.props['color'] as String?, c);
    return Icon(widgetIconByName(name), size: size, color: color);
  });
}

// ── helpers ──────────────────────────────────────────────────────

TextStyle _styleFor(String variant, FontWeight weight, Color color) {
  switch (variant) {
    case 'display':
      return GoogleFonts.inter(
        fontSize: 28,
        fontWeight: weight,
        color: color,
        letterSpacing: -0.5,
      );
    case 'headline':
      return GoogleFonts.inter(
        fontSize: 20,
        fontWeight: weight,
        color: color,
        letterSpacing: -0.3,
      );
    case 'title':
      return GoogleFonts.inter(
        fontSize: 15,
        fontWeight: weight,
        color: color,
      );
    case 'caption':
      return GoogleFonts.inter(
        fontSize: 11,
        fontWeight: weight,
        color: color,
      );
    case 'code':
      return GoogleFonts.firaCode(
        fontSize: 11.5,
        fontWeight: weight,
        color: color,
      );
    case 'body':
    default:
      return GoogleFonts.inter(
        fontSize: 13,
        fontWeight: weight,
        color: color,
      );
  }
}

FontWeight _weightOf(String? v) {
  switch (v) {
    case 'bold':
      return FontWeight.w800;
    case 'semibold':
      return FontWeight.w700;
    case 'medium':
      return FontWeight.w600;
    case 'regular':
    default:
      return FontWeight.w500;
  }
}

TextAlign _alignOf(dynamic v) {
  switch (v) {
    case 'center':
      return TextAlign.center;
    case 'end':
      return TextAlign.end;
    default:
      return TextAlign.start;
  }
}

BoxFit _boxFit(dynamic v) {
  switch (v) {
    case 'contain':
      return BoxFit.contain;
    case 'fill':
      return BoxFit.fill;
    case 'cover':
    default:
      return BoxFit.cover;
  }
}
