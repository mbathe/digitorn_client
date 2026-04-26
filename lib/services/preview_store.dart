/// Client-side store for the preview module state delivered over
/// Socket.IO `preview:*` events.
///
/// The daemon's preview module maintains two kinds of data:
///
///   * **State** — flat key/value scalars (e.g. `theme: "dark"`,
///     `locale: "fr"`). Updated by `preview:state_changed` and
///     `preview:state_patched`.
///
///   * **Resources** — per-channel collections keyed by id (e.g.
///     channel `"cards"` → `{"task-1": {title, column}, ...}`).
///     Updated by `preview:resource_set`, `preview:resource_patched`,
///     `preview:resource_deleted`, `preview:resource_bulk_set`,
///     `preview:channel_cleared`.
///
/// The store is rebuilt from scratch on `preview:snapshot` (full dump)
/// and `preview:cleared` (wipe). The `preview_seq` in each payload
/// provides ordering — useful for the iframe to know it's up to date.
///
/// [DigitornSocketService.previewEvents] delivers every `preview:*`
/// event here. Consumers (e.g. the preview iframe via postMessage)
/// watch this store via [addListener] / Provider.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'session_service.dart';
import 'socket_service.dart';

class PreviewStore extends ChangeNotifier {
  static final PreviewStore _i = PreviewStore._();
  factory PreviewStore() => _i;
  PreviewStore._() {
    _bind();
  }

  // ── State (flat key/value) ──────────────────────────────────────────

  final Map<String, dynamic> _state = {};
  Map<String, dynamic> get state => Map.unmodifiable(_state);

  // ── Resources (channel → {id → payload}) ────────────────────────────

  final Map<String, Map<String, dynamic>> _resources = {};
  Map<String, Map<String, dynamic>> get resources =>
      Map.unmodifiable(_resources);

  /// Convenience — get all items in a channel.
  Map<String, dynamic> channel(String name) =>
      Map.unmodifiable(_resources[name] ?? const {});

  /// The highest preview_seq received so far.
  int seq = 0;

  StreamSubscription<Map<String, dynamic>>? _sub;

  void _bind() {
    _sub?.cancel();
    _sub = DigitornSocketService().previewEvents.listen(_onEvent);
  }

  void _onEvent(Map<String, dynamic> event) {
    final type = event['type'] as String? ?? '';
    final payload = event['payload'] as Map<String, dynamic>? ?? {};

    // Hard per-session isolation. Without this guard, a late event
    // for session A that races in after the user switched to session
    // B would overwrite B's workspace with A's files (Monaco shows
    // the wrong file tree, the wrong open tab, the wrong tool
    // output). The daemon tags every envelope with ``session_id`` —
    // we drop anything that doesn't match what the user is currently
    // looking at. ``reset()`` + the new session's ``preview:snapshot``
    // then rebuild the store cleanly on session entry.
    //
    // Events without a ``session_id`` (legacy / bootstrap) are let
    // through so we don't regress on daemons that haven't been
    // updated. Once the contract is enforced server-side this can
    // become a strict filter.
    final evSid = event['session_id'] as String?;
    final activeSid = SessionService().activeSession?.sessionId;
    if (evSid != null &&
        evSid.isNotEmpty &&
        activeSid != null &&
        activeSid.isNotEmpty &&
        evSid != activeSid) {
      debugPrint(
          'PreviewStore: drop $type for sid=$evSid (active=$activeSid)');
      return;
    }

    debugPrint('PreviewStore: $type (payload keys: ${payload.keys})');
    final pSeq = (payload['preview_seq'] as num?)?.toInt();
    if (pSeq != null && pSeq > seq) seq = pSeq;

    switch (type) {
      case 'preview:state_changed':
        _onStateChanged(payload);
      case 'preview:state_patched':
        _onStatePatched(payload);
      case 'preview:resource_set':
        _onResourceSet(payload);
      case 'preview:resource_patched':
        _onResourcePatched(payload);
      case 'preview:resource_deleted':
        _onResourceDeleted(payload);
      case 'preview:resource_bulk_set':
        _onBulkSet(payload);
      case 'preview:channel_cleared':
        _onChannelCleared(payload);
      case 'preview:cleared':
        _onCleared();
      case 'preview:snapshot':
        _onSnapshot(payload);
    }
  }

  // ── State handlers ──────────────────────────────────────────────────

  void _onStateChanged(Map<String, dynamic> p) {
    final key = p['key'] as String?;
    if (key != null) {
      _state[key] = p['value'];
      notifyListeners();
    }
  }

  void _onStatePatched(Map<String, dynamic> p) {
    final patch = p['patch'];
    if (patch is Map) {
      _state.addAll(patch.cast<String, dynamic>());
      notifyListeners();
    }
  }

  // ── Resource handlers ───────────────────────────────────────────────

  void _onResourceSet(Map<String, dynamic> p) {
    final ch = p['channel'] as String?;
    final id = p['id'] as String?;
    if (ch == null || id == null) return;
    _resources.putIfAbsent(ch, () => {});
    _resources[ch]![id] = p['payload'] ?? {};
    notifyListeners();
  }

  void _onResourcePatched(Map<String, dynamic> p) {
    final ch = p['channel'] as String?;
    final id = p['id'] as String?;
    if (ch == null || id == null) return;
    // Scout-confirmed: the daemon ships the FULL new state in
    // `payload` alongside the incremental `patch`. Prefer the full
    // payload when present — it survives a missed preview event
    // upstream (reconnect race, dropped frame) where a blind merge
    // of `patch` into whatever we happen to have locally would
    // leave us with a truncated row (only the 4 changed fields,
    // missing content / language / size / …).
    final fullPayload = p['payload'];
    if (fullPayload is Map) {
      _resources.putIfAbsent(ch, () => {});
      _resources[ch]![id] = fullPayload.cast<String, dynamic>();
      notifyListeners();
      return;
    }
    final patch = p['patch'];
    if (patch is! Map) return;
    final existing = _resources[ch]?[id];
    if (existing is Map) {
      final merged = Map<String, dynamic>.from(existing);
      merged.addAll(patch.cast<String, dynamic>());
      _resources[ch]![id] = merged;
    } else {
      _resources.putIfAbsent(ch, () => {});
      _resources[ch]![id] = patch.cast<String, dynamic>();
    }
    notifyListeners();
  }

  void _onResourceDeleted(Map<String, dynamic> p) {
    final ch = p['channel'] as String?;
    final id = p['id'] as String?;
    if (ch == null || id == null) return;
    _resources[ch]?.remove(id);
    notifyListeners();
  }

  void _onBulkSet(Map<String, dynamic> p) {
    final ch = p['channel'] as String?;
    if (ch == null) return;
    if (p['replace'] == true) _resources[ch] = {};
    _resources.putIfAbsent(ch, () => {});
    final items = p['items'];
    if (items is Map) {
      items.cast<String, dynamic>().forEach((id, payload) {
        _resources[ch]![id] = payload;
      });
    }
    notifyListeners();
  }

  void _onChannelCleared(Map<String, dynamic> p) {
    final ch = p['channel'] as String?;
    if (ch == null) return;
    _resources[ch]?.clear();
    notifyListeners();
  }

  // ── Full reset / snapshot ───────────────────────────────────────────

  void _onCleared() {
    _state.clear();
    _resources.clear();
    seq = 0;
    notifyListeners();
  }

  void _onSnapshot(Map<String, dynamic> p) {
    _state.clear();
    _resources.clear();

    final snapState = p['state'];
    if (snapState is Map) {
      _state.addAll(snapState.cast<String, dynamic>());
    }

    final snapResources = p['resources'];
    if (snapResources is Map) {
      for (final entry in snapResources.entries) {
        final ch = entry.key as String;
        final items = entry.value;
        if (items is Map) {
          _resources[ch] = Map<String, dynamic>.from(items);
        }
      }
    }

    final pSeq = (p['preview_seq'] as num?)?.toInt();
    if (pSeq != null) seq = pSeq;
    notifyListeners();
  }

  /// Hard reset — call on app switch or session change.
  void reset() {
    _state.clear();
    _resources.clear();
    seq = 0;
    notifyListeners();
  }

  /// Apply a history-sourced `preview_snapshot` payload. The payload
  /// shape matches what the daemon emits for `preview:snapshot` but
  /// arrives here from the `/history` endpoint rather than the
  /// Socket.IO stream, so we expose a public entry point.
  void applySnapshot(Map<String, dynamic> snapshot) => _onSnapshot(snapshot);

  /// Prime the `files` channel from the lightweight
  /// `GET /workspace/code-snapshot` response (per-file metadata, no
  /// content). Non-destructive: only fills slots that aren't already
  /// populated by live `preview:resource_set` events. Used on session
  /// load for an instant file-tree render — Socket.IO's authoritative
  /// `preview:snapshot` still replaces / overrides when it arrives.
  ///
  /// Wire shape (scout-verified on `digitorn-builder`):
  ///   `{ "session_id": "...", "files": { "{path}": { ...metadata } },
  ///     "seq": N }`
  ///
  /// The per-file metadata carries `insertions_pending`,
  /// `deletions_pending`, `validation`, `status`, `git_status`, etc.
  /// — enough for the explorer to show badges before any file is
  /// opened.
  void primeFilesFromCodeSnapshot(Map<String, dynamic> snapshot) {
    final files = snapshot['files'];
    if (files is! Map) return;
    _resources.putIfAbsent('files', () => {});
    var changed = false;
    for (final entry in files.entries) {
      final path = entry.key as String?;
      if (path == null) continue;
      if (_resources['files']!.containsKey(path)) continue; // live wins
      _resources['files']![path] = entry.value;
      changed = true;
    }
    final snapSeq = (snapshot['seq'] as num?)?.toInt();
    if (snapSeq != null && snapSeq > seq) {
      seq = snapSeq;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Prime `state['workspace']` from the HTTP
  /// `GET /sessions/{sid}/workspace` payload. Scout-confirmed that the
  /// daemon ships metadata here (not via `preview:state_changed`), so
  /// this is how BuilderCanvas / code-preview / other canvas modes
  /// learn which renderer to mount.
  ///
  /// Accepts either `{render_mode, entry_file, title, workspace}` at
  /// the top level or nested under `workspace: {...}` (the
  /// `/api/apps/{id}` variant). Overwrites any stale value — this
  /// endpoint is the source of truth on session load.
  void primeWorkspaceMeta(Map<String, dynamic> meta) {
    final nested = meta['workspace'];
    final Map<String, dynamic> ws;
    if (nested is Map && nested['render_mode'] != null) {
      ws = nested.cast<String, dynamic>();
    } else {
      ws = {
        if (meta['render_mode'] != null) 'render_mode': meta['render_mode'],
        if (meta['entry_file'] != null) 'entry_file': meta['entry_file'],
        if (meta['title'] != null) 'title': meta['title'],
        if (meta['workspace'] != null && meta['workspace'] is String)
          'workspace_path': meta['workspace'],
      };
    }
    if (ws.isEmpty) return;
    _state['workspace'] = ws;
    notifyListeners();
  }

  /// Apply any `preview:*` event payload from history. Routes to the
  /// same private handlers used for live events. Unknown types are
  /// ignored silently.
  void applyHistoryEvent(String type, Map<String, dynamic> payload) {
    final pSeq = (payload['preview_seq'] as num?)?.toInt();
    if (pSeq != null && pSeq > seq) seq = pSeq;
    switch (type) {
      case 'preview:state_changed':
        _onStateChanged(payload);
      case 'preview:state_patched':
        _onStatePatched(payload);
      case 'preview:resource_set':
        _onResourceSet(payload);
      case 'preview:resource_patched':
        _onResourcePatched(payload);
      case 'preview:resource_deleted':
        _onResourceDeleted(payload);
      case 'preview:resource_bulk_set':
        _onBulkSet(payload);
      case 'preview:channel_cleared':
        _onChannelCleared(payload);
      case 'preview:cleared':
        _onCleared();
      case 'preview:snapshot':
        _onSnapshot(payload);
    }
  }

  // ── Synthetic injection from tool_call (bridge for non-preview apps) ─
  //
  // Apps that only load the `filesystem` module (e.g. fs-tester,
  // prod-coding-assistant) don't carry a `preview` module, so the
  // daemon never emits `preview:resource_set` for files they Write /
  // Edit / Delete. The file still lands on disk and the tool_call
  // envelope carries the metadata — we just have to bridge it into
  // the PreviewStore ourselves so the rest of the workspace pipeline
  // (WorkspaceModule → CodeExplorer) lights up uniformly.
  //
  // The scout confirmed the tool_call `result` shape for these tools
  // is:
  //   Write:  { path, language, operation: "create"|"write", size, lines }
  //   Edit:   { path, language, operation: "edit", ... }
  //   Delete: { path, operation: "delete" }
  //   Read:   { path, content, language, total_lines, lines_read, ... }
  //
  // For Write/Edit/Delete we want a preview:resource_set (or _deleted)
  // so the file tree updates. Read is a no-op here (the file may or
  // may not already be tracked, and we shouldn't invent an entry that
  // doesn't exist just because it was read).
  static const Set<String> _fsMutatingTools = {
    'write', 'wswrite', 'file_write', 'create_file',
    'edit', 'wsedit', 'file_edit', 'multiedit', 'multi_edit',
    'delete', 'wsdelete', 'file_delete', 'remove_file',
    'notebookedit', 'notebook_edit',
  };

  /// Call from the chat pipeline on every successful filesystem
  /// `tool_call`. Builds a synthetic `preview:resource_set` (or
  /// `preview:resource_deleted`) so apps without the `preview` module
  /// still see their file tree update live.
  ///
  /// Returns `true` if the envelope was handled, `false` if it's
  /// outside our scope (non-filesystem tool, failed call, already
  /// served by a real preview event from the daemon — see below).
  bool ingestToolCall({
    required String toolName,
    required Map<String, dynamic> params,
    required Map<String, dynamic> result,
    Map<String, dynamic>? display,
  }) {
    final lname = toolName.toLowerCase();
    if (!_fsMutatingTools.contains(lname)) return false;

    // Extract the path — different tools stash it under different keys.
    final path = (params['file_path'] as String?)
        ?? (params['path'] as String?)
        ?? (result['path'] as String?);
    if (path == null || path.isEmpty) return false;

    final operation = (result['operation'] as String?)
        ?? (lname.contains('delete') ? 'delete' : 'write');

    if (operation == 'delete' || lname.contains('delete')) {
      _resources['files']?.remove(path);
      notifyListeners();
      return true;
    }

    // If the daemon's preview module already populated this entry
    // with its rich payload (diff counters, validation state,
    // baseline_lines — fields only the preview module knows), don't
    // overwrite it. Our synthetic payload is a strict downgrade for
    // apps that DO carry the preview module (ws-preview-test,
    // digitorn-builder, …). The scout confirmed preview:resource_set
    // lands BEFORE tool_call, so the guard fires reliably.
    final existing = _resources['files']?[path];
    if (existing is Map) {
      final daemonPopulated = existing.containsKey('insertions') ||
          existing.containsKey('deletions') ||
          existing.containsKey('baseline_lines') ||
          existing['validation'] == 'pending';
      if (daemonPopulated) return false;
    }

    // Determine status for the badge: "added" for a fresh create,
    // "modified" for an overwrite of an existing tracked file.
    final existed = _resources['files']?.containsKey(path) ?? false;
    final status = existed ? 'modified' : 'added';

    final payload = <String, dynamic>{
      // Content from tool params when available; Write/Edit carry it,
      // Delete doesn't (and we returned above anyway).
      if (params['content'] is String) 'content': params['content'],
      if (result['language'] is String) 'language': result['language'],
      if (result['size'] is num) 'size': result['size'],
      if (result['lines'] is num) 'lines': result['lines'],
      'operation': operation,
      'status': status,
      // Non-preview apps have no approval flow — mark approved so the
      // file renders as "clean" rather than a pending-review badge.
      'validation': 'approved',
      'updated_at': DateTime.now().millisecondsSinceEpoch / 1000,
    };

    _resources.putIfAbsent('files', () => {});
    _resources['files']![path] = payload;
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
