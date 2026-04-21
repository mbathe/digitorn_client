/// Digitorn Widgets v1 — models.
///
/// Typed AST mirroring the daemon's widget spec. Every node is
/// deliberately loose (`props` is a raw map) so that adding new
/// primitives doesn't require touching the parser — builders read
/// whatever keys they need from [WidgetNode.props].
library;

/// Top-level spec returned by `GET /api/apps/{id}/widgets`.
class WidgetsAppSpec {
  final int version;
  final WidgetPaneSpec? chatSide;
  final List<WidgetPaneSpec> workspaceTabs;
  final Map<String, WidgetPaneSpec> modals;
  final Map<String, WidgetPaneSpec> inline;

  const WidgetsAppSpec({
    this.version = 1,
    this.chatSide,
    this.workspaceTabs = const [],
    this.modals = const {},
    this.inline = const {},
  });

  bool get hasChatSide => chatSide != null;
  bool get hasWorkspaceTabs => workspaceTabs.isNotEmpty;
  bool get isEmpty =>
      chatSide == null &&
      workspaceTabs.isEmpty &&
      modals.isEmpty &&
      inline.isEmpty;

  factory WidgetsAppSpec.fromJson(Map<String, dynamic> j) {
    WidgetPaneSpec? chatSide;
    final cs = j['chat_side'];
    if (cs is Map) {
      chatSide = WidgetPaneSpec.fromJson(cs.cast<String, dynamic>());
    }
    final wt = <WidgetPaneSpec>[];
    final rawTabs = j['workspace_tabs'];
    if (rawTabs is List) {
      for (final e in rawTabs) {
        if (e is Map) {
          wt.add(WidgetPaneSpec.fromJson(e.cast<String, dynamic>()));
        }
      }
    }
    final modals = <String, WidgetPaneSpec>{};
    final mj = j['modals'];
    if (mj is Map) {
      mj.forEach((k, v) {
        if (v is Map) {
          modals[k.toString()] =
              WidgetPaneSpec.fromJson(v.cast<String, dynamic>());
        }
      });
    }
    final inline = <String, WidgetPaneSpec>{};
    final ij = j['inline'];
    if (ij is Map) {
      ij.forEach((k, v) {
        if (v is Map) {
          inline[k.toString()] =
              WidgetPaneSpec.fromJson(v.cast<String, dynamic>());
        }
      });
    }
    return WidgetsAppSpec(
      version: (j['version'] as num?)?.toInt() ?? 1,
      chatSide: chatSide,
      workspaceTabs: wt,
      modals: modals,
      inline: inline,
    );
  }

  static const empty = WidgetsAppSpec();
}

/// One pane (chat_side, a workspace_tab, a modal, an inline widget).
/// Wraps a root [tree] node + pane-level metadata + data bindings
/// that live at the pane root rather than inside the tree.
class WidgetPaneSpec {
  final String? id;
  final String? title;
  final String? icon;
  final String? accent;
  final String? density;
  final double? width;
  final bool collapsible;
  final bool defaultOpen;
  final bool dismissible;
  final WidgetNode tree;
  final Map<String, DataSourceSpec> data;

  const WidgetPaneSpec({
    this.id,
    this.title,
    this.icon,
    this.accent,
    this.density,
    this.width,
    this.collapsible = true,
    this.defaultOpen = true,
    this.dismissible = true,
    required this.tree,
    this.data = const {},
  });

  factory WidgetPaneSpec.fromJson(Map<String, dynamic> j) {
    final rawTree = j['tree'];
    final tree = rawTree is Map
        ? WidgetNode.fromJson(rawTree.cast<String, dynamic>())
        : const WidgetNode(type: 'empty_state');
    final dataMap = <String, DataSourceSpec>{};
    final rawData = j['data'];
    if (rawData is Map) {
      rawData.forEach((k, v) {
        if (v is Map) {
          dataMap[k.toString()] =
              DataSourceSpec.fromJson(v.cast<String, dynamic>());
        }
      });
    }
    return WidgetPaneSpec(
      id: j['id'] as String?,
      title: j['title'] as String?,
      icon: j['icon'] as String?,
      accent: j['accent'] as String?,
      density: j['density'] as String?,
      width: (j['width'] as num?)?.toDouble(),
      collapsible: j['collapsible'] != false,
      defaultOpen: j['default_open'] != false,
      dismissible: j['dismissible'] != false,
      tree: tree,
      data: dataMap,
    );
  }
}

/// A single widget node in the tree. [props] holds the raw JSON map
/// so builders can pluck any primitive-specific key without schema
/// duplication.
class WidgetNode {
  final String type;
  final Map<String, dynamic> props;

  const WidgetNode({
    required this.type,
    this.props = const {},
  });

  // ── Common fields (read from props with sensible defaults) ─────

  String? get id => props['id'] as String?;
  String? get whenExpr => props['when'] as String?;
  String? get forExpr => props['for'] as String?;
  String get asName => (props['as'] as String?) ?? 'item';
  String? get keyExpr => props['key'] as String?;
  String? get accent => props['accent'] as String?;
  String? get density => props['density'] as String?;
  bool get hidden => props['hidden'] == true;

  /// Parsed `data:` block attached to this node. Fetchers live
  /// outside the node so this is cheap read-only metadata.
  Map<String, DataSourceSpec> get data {
    final raw = props['data'];
    if (raw is! Map) return const {};
    final out = <String, DataSourceSpec>{};
    raw.forEach((k, v) {
      if (v is Map) {
        out[k.toString()] = DataSourceSpec.fromJson(v.cast<String, dynamic>());
      }
    });
    return out;
  }

  /// Returns the `children:` array as parsed nodes, or null if the
  /// key is absent. Null vs empty matters — some primitives (column,
  /// row) require the key.
  List<WidgetNode>? get children {
    final raw = props['children'];
    if (raw is! List) return null;
    return raw
        .whereType<Map>()
        .map((m) => WidgetNode.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  /// Convenience to parse a single nested node under any key.
  WidgetNode? nodeAt(String key) {
    final raw = props[key];
    if (raw is! Map) return null;
    return WidgetNode.fromJson(raw.cast<String, dynamic>());
  }

  /// Nested list of nodes under [key] (for `tabs:`, `columns:` etc).
  List<WidgetNode> nodesAt(String key) {
    final raw = props[key];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => WidgetNode.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  /// Action spec under [key], or null.
  ActionSpec? actionAt(String key) {
    final raw = props[key];
    if (raw is! Map) return null;
    return ActionSpec.fromJson(raw.cast<String, dynamic>());
  }

  factory WidgetNode.fromJson(Map<String, dynamic> j) =>
      WidgetNode(type: j['type'] as String? ?? 'unknown', props: j);
}

/// Declarative action. [type] is the action id (e.g. `chat`, `tool`),
/// [props] holds the full raw map.
class ActionSpec {
  final String type;
  final Map<String, dynamic> props;

  const ActionSpec({required this.type, this.props = const {}});

  factory ActionSpec.fromJson(Map<String, dynamic> j) => ActionSpec(
        type: j['action'] as String? ?? 'noop',
        props: j,
      );

  /// A sub-action under [key] — e.g. `on_success`, `confirm_action`,
  /// `then`. Returns null if absent.
  ActionSpec? sub(String key) {
    final raw = props[key];
    if (raw is! Map) return null;
    return ActionSpec.fromJson(raw.cast<String, dynamic>());
  }

  List<ActionSpec> subs(String key) {
    final raw = props[key];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => ActionSpec.fromJson(m.cast<String, dynamic>()))
        .toList();
  }
}

/// Declarative data source. Builders call a runtime that owns
/// fetchers keyed by this spec.
class DataSourceSpec {
  final String type; // http|tool|static|stream|local
  final Map<String, dynamic> props;

  const DataSourceSpec({required this.type, this.props = const {}});

  factory DataSourceSpec.fromJson(Map<String, dynamic> j) => DataSourceSpec(
        type: j['type'] as String? ?? 'static',
        props: j,
      );
}

/// Socket.IO event decoded from `widget:*` channels.
class WidgetEvent {
  /// `render`, `update`, `close`, `error`, `state`, `cleared`, `snapshot`
  final String kind;
  final Map<String, dynamic> data;

  const WidgetEvent({required this.kind, required this.data});

  String? get widgetId => data['widget_id'] as String?;
  String? get zone => data['zone'] as String?;
  String? get target => data['target'] as String?;
  String? get ref => data['ref'] as String?;

  Map<String, dynamic>? get ctx {
    final c = data['ctx'];
    return c is Map ? c.cast<String, dynamic>() : null;
  }

  WidgetNode? get tree {
    final t = data['tree'];
    return t is Map ? WidgetNode.fromJson(t.cast<String, dynamic>()) : null;
  }

  Map<String, dynamic>? get patch {
    final p = data['patch'];
    return p is Map ? p.cast<String, dynamic>() : null;
  }

  factory WidgetEvent.fromJson(String event, Map<String, dynamic> data) {
    final kind = event.startsWith('widget:')
        ? event.substring('widget:'.length)
        : event;
    return WidgetEvent(kind: kind, data: data);
  }
}
