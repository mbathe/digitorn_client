import 'package:flutter/widgets.dart';
import '../../../services/workspace_service.dart';

/// Everything a [FileViewer] needs to render a buffer in the workspace.
///
/// This is the single point of contact between the workspace shell and
/// any concrete viewer. Adding a new field here is the only way the shell
/// passes new state to viewers, so keep it tight and well-named.
class ViewerContext {
  /// The buffer to display.
  final WorkbenchBuffer buffer;

  /// All diagnostics that target [buffer.path]. Pre-filtered.
  final List<DiagnosticItem> diagnostics;

  /// Optional one-shot navigation request. Non-null only when the
  /// pending reveal targets [buffer.path].
  final RevealTarget? revealTarget;

  /// Called by the viewer once it has scrolled/highlighted in response
  /// to [revealTarget], so the service stops re-firing on rebuilds.
  final void Function(int requestId)? onRevealConsumed;

  /// Backreference to the workspace service for advanced viewers
  /// (e.g. tabs that want to spawn sibling buffers, run search, etc.).
  final WorkspaceService ws;

  const ViewerContext({
    required this.buffer,
    required this.diagnostics,
    required this.revealTarget,
    required this.onRevealConsumed,
    required this.ws,
  });
}

/// Base contract for any viewer the workspace can host.
///
/// Concrete viewers should be **stateless** singletons (the underlying
/// widget produced by [build] can be stateful as needed). They are
/// registered once at app startup via [ViewerRegistry.register] and
/// resolved per-buffer via [ViewerRegistry.resolve].
abstract class FileViewer {
  const FileViewer();

  /// Stable identifier — useful for telemetry / debugging / overrides.
  String get id;

  /// File extensions this viewer claims (lowercase, no leading dot).
  /// Use the empty set for viewers that match by other heuristics
  /// (override [canHandle] in that case).
  Set<String> get extensions;

  /// Higher priority wins when multiple viewers can handle the same buffer.
  /// Default 0; specialised viewers (PDF, Excel, …) should bump this.
  int get priority => 0;

  /// Whether this viewer can render the given buffer. Default checks
  /// [extensions] against [WorkbenchBuffer.extension]; override for
  /// MIME-based or content-based dispatch.
  bool canHandle(WorkbenchBuffer buffer) {
    if (extensions.isEmpty) return false;
    return extensions.contains(buffer.extension.toLowerCase());
  }

  /// Build the viewer widget. Implementations should be cheap; heavy
  /// state belongs inside the produced widget's [State].
  Widget build(BuildContext context, ViewerContext vctx);
}

/// Marker interface: viewers that support programmatic navigation
/// (jump-to-line from diagnostics, search hits, etc.). Today the
/// reveal target is delivered via [ViewerContext.revealTarget] and
/// the viewer widget reacts to it internally — this mixin simply
/// declares the capability so the workspace shell can know.
mixin NavigableViewer on FileViewer {}

/// Marker interface: viewers that can search inside the current buffer
/// (find / find-and-replace). The Monaco viewer implements this via
/// its own Ctrl+F UX.
mixin SearchableViewer on FileViewer {}

/// Marker interface: viewers that allow user editing (not just display).
/// Monaco and the Excel grid implement this.
mixin EditableViewer on FileViewer {}
