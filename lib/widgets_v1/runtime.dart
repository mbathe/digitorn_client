/// Digitorn Widgets v1 — runtime wiring.
///
/// Exposes [WidgetRuntime] (the per-pane facade builders receive)
/// and [buildNode], the top-level dispatch function that routes a
/// [WidgetNode] to the right primitive builder.
///
/// Every primitive receives the current [WidgetRuntime], which lets
/// them access the state container, the action dispatcher, the
/// binding engine, and the recursive `build` function — with zero
/// inter-primitive imports.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'bindings.dart';
import 'data_runtime.dart';
import 'dispatcher.dart' as disp;
import 'models.dart';
import 'primitives/action_primitives.dart';
import 'primitives/content.dart';
import 'primitives/data_display.dart';
import 'primitives/feedback.dart';
import 'primitives/html.dart';
import 'primitives/input.dart';
import 'primitives/layout.dart';
import 'primitives/presence.dart';
import 'state.dart';

/// Per-pane facade passed through to every primitive builder.
class WidgetRuntime {
  final String appId;
  final WidgetRuntimeState state;
  final DataRuntime data;
  final disp.ActionDispatcher dispatcher;

  /// Accent & density resolved at the pane level. Primitives can
  /// override via a child node's own accent/density keys.
  final String accent;
  final String density;

  /// Theme tokens — small, closed-set overrides the daemon may
  /// expose at pane level. [radiusBase] is the default corner
  /// radius for cards/inputs (primitives that care can scale from
  /// it), [spacingBase] is the base padding unit in logical pixels.
  final double radiusBase;
  final double spacingBase;

  const WidgetRuntime({
    required this.appId,
    required this.state,
    required this.data,
    required this.dispatcher,
    this.accent = 'blue',
    this.density = 'normal',
    this.radiusBase = 8,
    this.spacingBase = 4,
  });

  /// Resolve the effective accent color for a node (node override
  /// or the pane default).
  Color accentColor(WidgetNode node, AppColors colors) {
    final name = node.accent ?? accent;
    return _accent(name, colors);
  }

  /// Resolve a semantic color name to an [AppColors] slot.
  Color semanticColor(String? name, AppColors colors) {
    switch (name) {
      case 'success':
        return colors.green;
      case 'warning':
        return colors.orange;
      case 'error':
        return colors.red;
      case 'info':
      case 'accent':
        return _accent(accent, colors);
      case 'muted':
        return colors.textMuted;
      case 'bright':
        return colors.textBright;
      case 'dim':
        return colors.textDim;
      case 'text':
      default:
        return colors.text;
    }
  }

  static Color _accent(String name, AppColors colors) {
    switch (name) {
      case 'purple':
        return colors.purple;
      case 'green':
        return colors.green;
      case 'orange':
        return colors.orange;
      case 'red':
        return colors.red;
      case 'cyan':
        return colors.cyan;
      case 'blue':
      default:
        return colors.blue;
    }
  }

  double densityScale() {
    switch (density) {
      case 'compact':
        return 0.75;
      case 'roomy':
        return 1.25;
      case 'normal':
      default:
        return 1.0;
    }
  }

  /// Forks the runtime with overridden tokens (used when an
  /// intermediate node declares its own accent/density/radius/…).
  WidgetRuntime fork({
    String? newAccent,
    String? newDensity,
    double? newRadius,
    double? newSpacing,
  }) =>
      WidgetRuntime(
        appId: appId,
        state: state,
        data: data,
        dispatcher: dispatcher,
        accent: newAccent ?? accent,
        density: newDensity ?? density,
        radiusBase: newRadius ?? radiusBase,
        spacingBase: newSpacing ?? spacingBase,
      );
}

/// Top-level dispatch. Handles the common-node fields first
/// (`when`, `for`, `hidden`), then routes by `type:` to a builder.
///
/// [scopeExtra] is threaded through so loop iterations can layer
/// `item`, `row`, `index`, `first`, `last` on top of the pane scope
/// without mutating it.
Widget buildNode(
  WidgetNode node,
  WidgetRuntime runtime, {
  Map<String, dynamic>? scopeExtra,
}) {
  if (node.hidden) return const SizedBox.shrink();
  final scope = runtime.state.buildScope(extra: scopeExtra);

  // `when:` — skip if falsy.
  if (node.whenExpr != null) {
    if (!evalBool(node.whenExpr, scope, fallback: true)) {
      return const SizedBox.shrink();
    }
  }

  // `for:` — replicate the node for every iteration.
  if (node.forExpr != null) {
    final list = evalValue(node.forExpr, scope);
    if (list is! List || list.isEmpty) {
      return const SizedBox.shrink();
    }
    final as = node.asName;
    final children = <Widget>[];
    for (var i = 0; i < list.length; i++) {
      final item = list[i];
      final extra = <String, dynamic>{
        ...?scopeExtra,
        as: item,
        'row': item,
        'index': i,
        'first': i == 0,
        'last': i == list.length - 1,
      };
      // Clone the node without the `for:` to avoid infinite loop.
      final cloneProps = Map<String, dynamic>.from(node.props);
      cloneProps.remove('for');
      cloneProps.remove('as');
      cloneProps.remove('key');
      final clone = WidgetNode(type: node.type, props: cloneProps);
      // Stable key: prefer an `id` field on the item (survives reorder /
      // filter / add-remove), otherwise fall back to the index.
      final stableId = (item is Map) ? item['id'] ?? item['_id'] : null;
      children.add(KeyedSubtree(
        key: ValueKey(stableId ?? i),
        child: buildNode(clone, runtime, scopeExtra: extra),
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  // Pane-level token overrides: accent/density/radius/spacing.
  final radiusOverride = asDouble(node.props['radius']);
  final spacingOverride = asDouble(node.props['spacing']);
  final hasOverride = node.accent != null ||
      node.density != null ||
      radiusOverride != null ||
      spacingOverride != null;
  final subRuntime = hasOverride
      ? runtime.fork(
          newAccent: node.accent,
          newDensity: node.density,
          newRadius: radiusOverride,
          newSpacing: spacingOverride,
        )
      : runtime;

  return _dispatch(node, subRuntime, scopeExtra);
}

Widget _dispatch(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? scopeExtra,
) {
  switch (node.type) {
    // Layout
    case 'column':
      return buildColumn(node, runtime, scopeExtra);
    case 'row':
      return buildRow(node, runtime, scopeExtra);
    case 'card':
      return buildCard(node, runtime, scopeExtra);
    case 'section':
      return buildSection(node, runtime, scopeExtra);
    case 'tabs':
      return buildTabs(node, runtime, scopeExtra);
    case 'split':
      return buildSplit(node, runtime, scopeExtra);
    case 'grid':
      return buildGrid(node, runtime, scopeExtra);
    case 'spacer':
      return buildSpacer(node, runtime, scopeExtra);
    case 'divider':
      return buildDivider(node, runtime, scopeExtra);

    // Content
    case 'text':
      return buildText(node, runtime, scopeExtra);
    case 'markdown':
      return buildMarkdown(node, runtime, scopeExtra);
    case 'image':
      return buildImage(node, runtime, scopeExtra);
    case 'icon':
      return buildIconNode(node, runtime, scopeExtra);

    // Data display
    case 'list':
      return buildList(node, runtime, scopeExtra);
    case 'table':
      return buildTable(node, runtime, scopeExtra);
    case 'stat':
      return buildStat(node, runtime, scopeExtra);
    case 'chart':
      return buildChart(node, runtime, scopeExtra);
    case 'tree':
      return buildTree(node, runtime, scopeExtra);
    case 'timeline':
      return buildTimeline(node, runtime, scopeExtra);
    case 'kanban':
      return buildKanban(node, runtime, scopeExtra);
    case 'empty_state':
      return buildEmptyState(node, runtime, scopeExtra);

    // Input
    case 'form':
      return buildForm(node, runtime, scopeExtra);
    case 'text_input':
      return buildTextInput(node, runtime, scopeExtra);
    case 'textarea':
      return buildTextarea(node, runtime, scopeExtra);
    case 'select':
      return buildSelect(node, runtime, scopeExtra);
    case 'multi_select':
      return buildMultiSelect(node, runtime, scopeExtra);
    case 'radio':
      return buildRadio(node, runtime, scopeExtra);
    case 'checkbox':
      return buildCheckbox(node, runtime, scopeExtra);
    case 'switch':
      return buildSwitchNode(node, runtime, scopeExtra);
    case 'slider':
      return buildSlider(node, runtime, scopeExtra);
    case 'date':
    case 'time':
    case 'datetime':
      return buildDate(node, runtime, scopeExtra);
    case 'file_upload':
      return buildFileUpload(node, runtime, scopeExtra);
    case 'code_editor':
      return buildCodeEditor(node, runtime, scopeExtra);

    // Action
    case 'button':
      return buildButton(node, runtime, scopeExtra);
    case 'icon_button':
      return buildIconButton(node, runtime, scopeExtra);
    case 'link':
      return buildLink(node, runtime, scopeExtra);
    case 'confirm':
      return buildConfirmNode(node, runtime, scopeExtra);

    // Feedback
    case 'alert':
      return buildAlert(node, runtime, scopeExtra);
    case 'badge':
      return buildBadge(node, runtime, scopeExtra);
    case 'progress':
      return buildProgress(node, runtime, scopeExtra);
    case 'skeleton':
      return buildSkeleton(node, runtime, scopeExtra);

    // v2 — escape hatches & presence
    case 'html':
      return buildHtml(node, runtime, scopeExtra);
    case 'presence':
      return buildPresence(node, runtime, scopeExtra);

    default:
      return _unknown(node);
  }
}

Widget _unknown(WidgetNode node) {
  return Builder(
    builder: (ctx) {
      final c = ctx.colors;
      return Container(
        margin: const EdgeInsets.all(6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: c.red.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: c.red.withValues(alpha: 0.35)),
        ),
        child: Text(
          'Unknown widget: ${node.type}',
          style: TextStyle(
            color: c.red,
            fontSize: 11,
            fontFamily: 'monospace',
          ),
        ),
      );
    },
  );
}

/// Helper: parse a padding value that may be an int, a 2-array
/// [v, h], or a 4-array [t, r, b, l]. Used by layout primitives.
EdgeInsets parsePadding(dynamic raw, [double fallback = 0]) {
  if (raw is num) {
    final v = raw.toDouble();
    return EdgeInsets.all(v);
  }
  if (raw is List) {
    if (raw.length == 2) {
      final v = (raw[0] as num?)?.toDouble() ?? fallback;
      final h = (raw[1] as num?)?.toDouble() ?? fallback;
      return EdgeInsets.symmetric(vertical: v, horizontal: h);
    }
    if (raw.length == 4) {
      return EdgeInsets.fromLTRB(
        (raw[3] as num?)?.toDouble() ?? fallback,
        (raw[0] as num?)?.toDouble() ?? fallback,
        (raw[1] as num?)?.toDouble() ?? fallback,
        (raw[2] as num?)?.toDouble() ?? fallback,
      );
    }
  }
  return EdgeInsets.all(fallback);
}

/// Helper: extract a double from a dynamic prop.
double? asDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

/// Helper: extract an int from a dynamic prop.
int? asInt(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}
