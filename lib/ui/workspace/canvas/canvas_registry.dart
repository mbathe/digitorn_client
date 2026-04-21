/// Registry of per-`render_mode` canvas renderers.
///
/// Apps with `workspace.render_mode: <key>` and `preview.enabled: false`
/// want a client-side canvas derived from workspace files — NOT an
/// iframe pointing at a Vite dev server. Each app-specific canvas
/// registers a builder here at app boot; `WsPreviewRouter` resolves
/// the registry when it sees a mode that isn't one of the built-in
/// native renderers (code / html / markdown / slides / react).
///
/// Example (in `main.dart` startup):
///   CanvasRegistry.register('builder', (_) => const BuilderCanvas());
///
/// A canvas widget typically watches [WorkspaceModule] + [PreviewStore]
/// to derive its visual (parse `app.yaml`, read `_state/*.json`, …).
/// The daemon stays dumb about the graph — it only transports files.
library;

import 'package:flutter/widgets.dart';

typedef CanvasBuilder = Widget Function(BuildContext context);

class CanvasRegistry {
  CanvasRegistry._();

  static final Map<String, CanvasBuilder> _canvases = {};

  /// Register a widget builder for a given `render_mode` key.
  /// Idempotent — re-registering under the same key replaces the
  /// previous builder (useful in tests / hot-reload scenarios).
  static void register(String renderMode, CanvasBuilder builder) {
    _canvases[renderMode] = builder;
  }

  /// Resolve the builder for [renderMode], or null when none is
  /// registered. Callers should fall back to a native renderer (code
  /// view, empty state, …) when null.
  static CanvasBuilder? resolve(String renderMode) => _canvases[renderMode];

  /// True when [renderMode] has a canvas registered. Convenience for
  /// router code that needs to branch without resolving.
  static bool has(String renderMode) => _canvases.containsKey(renderMode);

  /// Clear every registration — test-only hook; never called from
  /// production code paths.
  @visibleForTesting
  static void reset() => _canvases.clear();
}
