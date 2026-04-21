import '../../../services/workspace_service.dart';
import 'file_viewer.dart';

/// Process-wide registry of [FileViewer]s.
///
/// Viewers are registered once at app startup (typically in `main()`)
/// and resolved per-buffer when the workspace renders the active file.
///
/// Resolution rules:
/// - Iterate registered viewers in **descending priority** order.
/// - Return the first viewer whose `canHandle` returns true.
/// - If none match, return [_fallback] (which **must** be configured
///   via [setFallback] at startup).
class ViewerRegistry {
  ViewerRegistry._();

  static final List<FileViewer> _viewers = [];
  static FileViewer? _fallback;

  /// Read-only view of currently registered viewers (priority-sorted).
  static List<FileViewer> get registered => List.unmodifiable(_viewers);

  /// Register a new viewer. Subsequent registrations re-sort by priority.
  /// Calling [register] with a viewer whose [FileViewer.id] already
  /// exists replaces the previous one (useful for hot-reload during dev).
  static void register(FileViewer viewer) {
    _viewers.removeWhere((v) => v.id == viewer.id);
    _viewers.add(viewer);
    _viewers.sort((a, b) => b.priority.compareTo(a.priority));
  }

  /// Set the fallback viewer used when no other viewer claims the buffer.
  /// This is typically the generic code/text viewer.
  static void setFallback(FileViewer viewer) {
    _fallback = viewer;
  }

  /// Resolve the best viewer for the given buffer. Throws if no viewer
  /// matches and no fallback was configured (programmer error — there
  /// should always be a fallback).
  static FileViewer resolve(WorkbenchBuffer buffer) {
    for (final v in _viewers) {
      if (v.canHandle(buffer)) return v;
    }
    final fb = _fallback;
    if (fb == null) {
      throw StateError(
        'ViewerRegistry has no viewer for "${buffer.path}" and no '
        'fallback was configured. Call ViewerRegistry.setFallback() '
        'during app startup.',
      );
    }
    return fb;
  }

  /// Reset the registry. **Test-only.** Removes all viewers and the fallback.
  static void resetForTesting() {
    _viewers.clear();
    _fallback = null;
  }
}
