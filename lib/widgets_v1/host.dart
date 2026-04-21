/// Digitorn Widgets v1 — host widget.
///
/// [WidgetHost] mounts a [WidgetPaneSpec] and wires every runtime
/// piece together: state container, data runtime, action dispatcher,
/// SSE subscription for inbound updates.
///
/// Same host is used for all four zones (inline bubble / chat side /
/// workspace tab / modal) — the caller just feeds a different
/// [WidgetPaneSpec]. The host is stateful because the data runtime
/// owns fetch timers and we want them to live as long as the widget.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'dart:async';

import 'data_runtime.dart';
import 'dispatcher.dart' as disp;
import 'models.dart';
import 'runtime.dart';
import 'service.dart';
import 'state.dart';

class WidgetHost extends StatefulWidget {
  /// App id this host belongs to. Used for data source URL scoping
  /// and global state persistence.
  final String appId;

  /// Unique key — typically `chat_side`, `workspace.<tab_id>`,
  /// `modal.<name>`, or `inline.<widget_id>`. Used to namespace the
  /// state container.
  final String paneKey;

  /// The pane spec to mount.
  final WidgetPaneSpec pane;

  /// Initial binding context passed by the caller. Shown under
  /// `ctx.*` in expressions.
  final Map<String, dynamic> ctx;

  /// Session-level info (user, session id, …).
  final Map<String, dynamic> session;

  /// App config (read-only).
  final Map<String, dynamic> app;

  /// Action hooks wired by the app shell. Provides the chat sender,
  /// tool runner, modal/workspace openers, etc.
  final disp.ActionHooks hooks;

  /// When true, the host subscribes to SSE `widget:*` events from
  /// the bus and applies `widget:update` / `widget:render` / etc.
  /// Only the inline bubble host typically sets this; others have
  /// their content pushed explicitly.
  final bool subscribeToEvents;

  /// The widget_id this host responds to when [subscribeToEvents]
  /// is true. Null = subscribe to all events (not usually wanted).
  final String? widgetId;

  const WidgetHost({
    super.key,
    required this.appId,
    required this.paneKey,
    required this.pane,
    this.ctx = const {},
    this.session = const {},
    this.app = const {},
    required this.hooks,
    this.subscribeToEvents = false,
    this.widgetId,
  });

  @override
  State<WidgetHost> createState() => _WidgetHostState();
}

class _WidgetHostState extends State<WidgetHost>
    with AutomaticKeepAliveClientMixin {
  late WidgetRuntimeState _state;
  late DataRuntime _data;
  late disp.ActionDispatcher _dispatcher;
  late WidgetRuntime _runtime;
  StreamSubscription<WidgetEvent>? _eventSub;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _wire();
  }

  void _wire() {
    _state = WidgetRuntimeState(
      appId: widget.appId,
      paneKey: widget.paneKey,
      ctx: widget.ctx,
      session: widget.session,
      app: widget.app,
    );
    _data = DataRuntime(
      appId: widget.appId,
      state: _state,
      toolRunner: widget.hooks.toolRunner,
    );
    _dispatcher = disp.ActionDispatcher(
      appId: widget.appId,
      state: _state,
      data: _data,
      hooks: widget.hooks,
    );
    _runtime = WidgetRuntime(
      appId: widget.appId,
      state: _state,
      data: _data,
      dispatcher: _dispatcher,
      accent: widget.pane.accent ?? 'blue',
      density: widget.pane.density ?? 'normal',
      radiusBase: _asDouble(widget.pane.tree.props['radius']) ?? 8,
      spacingBase: _asDouble(widget.pane.tree.props['spacing']) ?? 4,
    );
    // Register pane-level data blocks, then walk the tree for
    // sub-tree blocks.
    _data.register(widget.pane.data);
    _data.scanTree(widget.pane.tree);

    if (widget.subscribeToEvents && widget.widgetId != null) {
      _eventSub = WidgetEventBus().listenFor(widget.widgetId!, _onEvent);
    }
  }

  double? _asDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  void _onEvent(WidgetEvent event) {
    if (!mounted) return;
    switch (event.kind) {
      case 'update':
        final patch = event.patch;
        if (patch == null) return;
        patch.forEach((path, value) {
          final dotIdx = path.indexOf('.');
          if (dotIdx < 0) return;
          final scope = path.substring(0, dotIdx);
          final key = path.substring(dotIdx + 1);
          if (scope == 'state') {
            _state.setState({key: value});
          } else if (scope == 'data') {
            _state.setDataValue(key, value);
          }
        });
        break;
      case 'state':
        // Full state replacement from daemon.
        final newState = event.data['state'];
        if (newState is Map) {
          _state.replaceState(newState.cast<String, dynamic>());
        }
        break;
      case 'snapshot':
        // Full state + data snapshot — reset everything.
        final snapState = event.data['state'];
        if (snapState is Map) {
          _state.replaceState(snapState.cast<String, dynamic>());
        }
        final snapData = event.data['data'];
        if (snapData is Map) {
          snapData.cast<String, dynamic>().forEach((key, value) {
            _state.setDataValue(key, value);
          });
        }
        break;
      case 'cleared':
        // Daemon wiped all widget state — reset local.
        _state.replaceState({});
        break;
      case 'close':
        widget.hooks.closeHost?.call();
        break;
      case 'error':
        final binding = event.data['binding'] as String?;
        final message = event.data['message'] as String? ?? 'Error';
        if (binding != null) {
          _state.setDataError(binding, message);
        }
        break;
    }
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _data.dispose();
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final c = context.colors;
    return AnimatedBuilder(
      animation: _state,
      builder: (_, _) {
        return Container(
          color: c.bg,
          child: buildNode(widget.pane.tree, _runtime),
        );
      },
    );
  }
}
