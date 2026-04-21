import 'package:flutter/foundation.dart';

import 'artifact.dart';

/// Session-scoped registry of artifacts extracted from assistant
/// messages. Single source of truth for the side panel — UI reads
/// via `context.watch<ArtifactService>()`.
///
/// Cleared on session switch (consumers wire this into
/// SessionService.onSessionChange).
class ArtifactService extends ChangeNotifier {
  static final ArtifactService _i = ArtifactService._();
  factory ArtifactService() => _i;
  ArtifactService._();

  final Map<String, Artifact> _byId = {};
  String? _selectedId;
  bool _panelOpen = false;

  List<Artifact> get artifacts =>
      _byId.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  Artifact? artifactById(String id) => _byId[id];
  Artifact? get selected =>
      _selectedId == null ? null : _byId[_selectedId];
  bool get isOpen => _panelOpen;
  bool get hasAny => _byId.isNotEmpty;

  /// Merge a batch of artifacts extracted from a single message.
  /// Existing ids are replaced (message may have been edited /
  /// re-streamed); ids absent from the new set but sharing the same
  /// messageId are removed so stale pills disappear.
  ///
  /// Preserves the original `createdAt` of an existing artifact so
  /// streaming updates (content growing) don't restart any
  /// "just arrived" entry animation. Equally, skips the notify when
  /// nothing actually changed (same content + streaming flag) —
  /// prevents a notifyListeners storm during high-frequency token
  /// deltas.
  void upsertForMessage(String messageId, List<Artifact> fresh) {
    final currentForMsg =
        _byId.values.where((a) => a.messageId == messageId).toList();
    final freshIds = fresh.map((a) => a.id).toSet();
    bool changed = false;
    for (final stale in currentForMsg) {
      if (!freshIds.contains(stale.id)) {
        _byId.remove(stale.id);
        if (_selectedId == stale.id) _selectedId = null;
        changed = true;
      }
    }
    for (final incoming in fresh) {
      final existing = _byId[incoming.id];
      if (existing != null) {
        if (existing.content == incoming.content &&
            existing.isStreaming == incoming.isStreaming &&
            existing.title == incoming.title &&
            existing.type == incoming.type) {
          continue;
        }
        // Preserve createdAt so the pill doesn't re-animate its
        // entry on every streaming update.
        _byId[incoming.id] = Artifact(
          id: incoming.id,
          messageId: incoming.messageId,
          index: incoming.index,
          type: incoming.type,
          language: incoming.language,
          title: incoming.title,
          content: incoming.content,
          createdAt: existing.createdAt,
          isStreaming: incoming.isStreaming,
        );
      } else {
        _byId[incoming.id] = incoming;
      }
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Remove every artifact tied to a message — used when the user
  /// deletes/retries/rewrites a turn.
  void removeForMessage(String messageId) {
    final toRemove =
        _byId.values.where((a) => a.messageId == messageId).map((a) => a.id);
    for (final id in toRemove.toList()) {
      _byId.remove(id);
      if (_selectedId == id) _selectedId = null;
    }
    if (_byId.isEmpty) _panelOpen = false;
    notifyListeners();
  }

  void select(String id) {
    if (!_byId.containsKey(id)) return;
    _selectedId = id;
    _panelOpen = true;
    notifyListeners();
  }

  /// Index of the currently-selected artifact inside [artifacts]
  /// (createdAt-sorted). Returns -1 when nothing is selected.
  int get selectedIndex {
    final id = _selectedId;
    if (id == null) return -1;
    return artifacts.indexWhere((a) => a.id == id);
  }

  /// Total count of registered artifacts — used by the panel header
  /// to render the `n / total` indicator.
  int get total => _byId.length;

  bool get canGoPrevious => selectedIndex > 0;
  bool get canGoNext =>
      selectedIndex >= 0 && selectedIndex < artifacts.length - 1;

  void selectPrevious() {
    final i = selectedIndex;
    if (i <= 0) return;
    final list = artifacts;
    _selectedId = list[i - 1].id;
    _panelOpen = true;
    notifyListeners();
  }

  void selectNext() {
    final i = selectedIndex;
    final list = artifacts;
    if (i < 0 || i >= list.length - 1) return;
    _selectedId = list[i + 1].id;
    _panelOpen = true;
    notifyListeners();
  }

  /// Open the **first** artifact and let the user walk forward via
  /// the panel's nav arrows. Called by the floating chip — starting
  /// at index 0 means every artifact is reachable with a right
  /// arrow, which the old `openLatest` defeated by jumping to the
  /// tail (leaving the earlier ones invisible).
  void openFirst() {
    final list = artifacts;
    if (list.isEmpty) return;
    _selectedId = list.first.id;
    _panelOpen = true;
    notifyListeners();
  }

  /// Open the most recently-created artifact. Kept for callers that
  /// want the "jump to newest" semantics (e.g. post-turn deep link).
  void openLatest() {
    final list = artifacts;
    if (list.isEmpty) return;
    _selectedId = list.last.id;
    _panelOpen = true;
    notifyListeners();
  }

  void close() {
    _panelOpen = false;
    notifyListeners();
  }

  void toggle() {
    if (_panelOpen) {
      close();
    } else {
      openLatest();
    }
  }

  /// Wipe everything — call from SessionService.onSessionChange.
  void clear() {
    _byId.clear();
    _selectedId = null;
    _panelOpen = false;
    notifyListeners();
  }
}
