import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Client-side persistence for session/project preferences that the
/// daemon does not currently own:
///
///   * **pinned sessions** — stickied to the top of the drawer so the
///     user can protect a "main thread" from being buried under newer
///     chats.
///   * **archived sessions** — hidden from the default list but still
///     reachable via the "Archived" filter. Distinct from `delete`,
///     which wipes the session on the daemon.
///   * **local renames** — a title override applied on top of whatever
///     the daemon sends. Useful when the daemon auto-title isn't
///     flattering.
///   * **collapsed projects** — per-workspace-path expand/collapse
///     state for the tree view.
///   * **archived projects** — per-workspace-path flag hiding an
///     entire project folder from the default view.
///
/// All state is keyed by sessionId / workspacePath and persisted via
/// SharedPreferences under stable keys. Every mutation bumps
/// [ChangeNotifier] so the drawer re-renders immediately.
///
/// When the daemon grows real pin/archive endpoints these helpers
/// become the client-side mirror + offline cache — the service is
/// designed to be upgraded, not thrown away.
class SessionPrefsService extends ChangeNotifier {
  static final SessionPrefsService _i = SessionPrefsService._();
  factory SessionPrefsService() => _i;
  SessionPrefsService._();

  static const _kPinned = 'session_prefs.pinned_ids';
  static const _kArchived = 'session_prefs.archived_ids';
  static const _kRenames = 'session_prefs.renames';
  static const _kCollapsedProjects = 'session_prefs.collapsed_projects';
  static const _kArchivedProjects = 'session_prefs.archived_projects';

  Set<String> _pinned = const {};
  Set<String> _archived = const {};
  Map<String, String> _renames = const {};
  Set<String> _collapsedProjects = const {};
  Set<String> _archivedProjects = const {};
  bool _loaded = false;

  bool get isLoaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _pinned = (prefs.getStringList(_kPinned) ?? const []).toSet();
      _archived = (prefs.getStringList(_kArchived) ?? const []).toSet();
      _collapsedProjects =
          (prefs.getStringList(_kCollapsedProjects) ?? const []).toSet();
      _archivedProjects =
          (prefs.getStringList(_kArchivedProjects) ?? const []).toSet();
      final renamesJson = prefs.getString(_kRenames);
      if (renamesJson != null && renamesJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(renamesJson);
          if (decoded is Map) {
            _renames = decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
          }
        } catch (e) {
          debugPrint('SessionPrefsService: rename decode failed — $e');
        }
      }
      _loaded = true;
      notifyListeners();
    } catch (e) {
      debugPrint('SessionPrefsService.load error: $e');
      _loaded = true;
    }
  }

  // ── Pinning ────────────────────────────────────────────────────────
  bool isPinned(String sessionId) => _pinned.contains(sessionId);

  Future<void> togglePin(String sessionId) async {
    final next = _pinned.toSet();
    if (!next.remove(sessionId)) next.add(sessionId);
    _pinned = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kPinned, next.toList());
  }

  // ── Archive (sessions) ─────────────────────────────────────────────
  bool isArchived(String sessionId) => _archived.contains(sessionId);

  Future<void> setArchived(String sessionId, bool archived) async {
    final next = _archived.toSet();
    final changed = archived ? next.add(sessionId) : next.remove(sessionId);
    if (!changed) return;
    _archived = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kArchived, next.toList());
  }

  // ── Local rename ───────────────────────────────────────────────────
  String? localTitle(String sessionId) => _renames[sessionId];

  /// Apply a rename. Empty [title] clears the override.
  Future<void> setLocalTitle(String sessionId, String title) async {
    final trimmed = title.trim();
    final next = Map<String, String>.from(_renames);
    if (trimmed.isEmpty) {
      if (!next.containsKey(sessionId)) return;
      next.remove(sessionId);
    } else {
      if (next[sessionId] == trimmed) return;
      next[sessionId] = trimmed;
    }
    _renames = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRenames, jsonEncode(next));
  }

  // ── Collapsed projects ────────────────────────────────────────────
  bool isProjectCollapsed(String workspacePath) =>
      _collapsedProjects.contains(workspacePath);

  Future<void> toggleProjectCollapsed(String workspacePath) async {
    final next = _collapsedProjects.toSet();
    if (!next.remove(workspacePath)) next.add(workspacePath);
    _collapsedProjects = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kCollapsedProjects, next.toList());
  }

  // ── Archived projects ─────────────────────────────────────────────
  bool isProjectArchived(String workspacePath) =>
      _archivedProjects.contains(workspacePath);

  Future<void> setProjectArchived(String workspacePath, bool archived) async {
    final next = _archivedProjects.toSet();
    final changed =
        archived ? next.add(workspacePath) : next.remove(workspacePath);
    if (!changed) return;
    _archivedProjects = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kArchivedProjects, next.toList());
  }

  /// Cleanup — called when a session is deleted so we don't leak
  /// prefs for a row that will never be seen again.
  Future<void> forgetSession(String sessionId) async {
    bool changed = false;
    if (_pinned.contains(sessionId)) {
      _pinned = _pinned.toSet()..remove(sessionId);
      changed = true;
    }
    if (_archived.contains(sessionId)) {
      _archived = _archived.toSet()..remove(sessionId);
      changed = true;
    }
    if (_renames.containsKey(sessionId)) {
      _renames = Map<String, String>.from(_renames)..remove(sessionId);
      changed = true;
    }
    if (!changed) return;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kPinned, _pinned.toList());
    await prefs.setStringList(_kArchived, _archived.toList());
    await prefs.setString(_kRenames, jsonEncode(_renames));
  }
}
