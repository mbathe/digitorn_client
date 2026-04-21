/// Digitorn Widgets v1 — state container.
///
/// One [WidgetRuntimeState] per mounted pane (Z1 bubble / Z2 chat
/// side / Z3 workspace tab / Z4 modal). Holds:
///
///   * `form.*`    — auto-collected from inputs inside a `form`
///   * `state.*`   — mutable via `set_state` actions
///   * `data.*`    — results of data-source fetches
///   * `ctx.*`     — context passed at mount (immutable)
///
/// Notifies listeners on every mutation so builders can rebuild.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bindings.dart';

/// Mutable per-pane state. Cheap to build, owned by [WidgetHost].
class WidgetRuntimeState extends ChangeNotifier {
  /// App id — used to namespace `scope: global` state in SharedPrefs.
  final String appId;
  final String paneKey;

  /// Context map passed by the caller when mounting the pane or via
  /// a `widget:render` SSE event. Read-only from bindings.
  final Map<String, dynamic> ctx;

  /// Root session info (user, session id, …) — passed through from
  /// main.dart. Read-only.
  final Map<String, dynamic> session;

  /// App config. Read-only.
  final Map<String, dynamic> app;

  /// Form stack. Key = form id, value = map of input name → value.
  /// Nested forms are supported — each `form` primitive pushes a
  /// new frame and inputs resolve to the top of the stack.
  final Map<String, Map<String, dynamic>> _forms = {};

  /// The currently-active form id (the innermost open form), or
  /// null when no form is mounted.
  String? _activeForm;
  String? get activeForm => _activeForm;

  /// Mutable local state (`state.*`).
  final Map<String, dynamic> _state = {};
  Map<String, dynamic> get stateMap => Map.unmodifiable(_state);

  /// Data binding results, keyed by binding name.
  final Map<String, DataEntry> _data = {};
  Map<String, DataEntry> get dataEntries => Map.unmodifiable(_data);

  /// Form validation errors, per form id → per field name.
  final Map<String, Map<String, String>> _formErrors = {};

  WidgetRuntimeState({
    required this.appId,
    required this.paneKey,
    this.ctx = const {},
    this.session = const {},
    this.app = const {},
  }) {
    _hydrateGlobalState();
  }

  // ── Forms ──────────────────────────────────────────────────────

  void pushForm(String id, Map<String, dynamic>? initial) {
    _forms.putIfAbsent(id, () => {...?initial});
    _formErrors.putIfAbsent(id, () => {});
    _activeForm = id;
  }

  void popForm(String id) {
    if (_activeForm == id) _activeForm = null;
  }

  void setField(String name, dynamic value, {String? formId}) {
    final id = formId ?? _activeForm ?? '_default';
    _forms.putIfAbsent(id, () => {});
    _forms[id]![name] = value;
    _formErrors[id]?.remove(name);
    notifyListeners();
  }

  dynamic getField(String name, {String? formId}) {
    final id = formId ?? _activeForm;
    if (id == null) return null;
    return _forms[id]?[name];
  }

  Map<String, dynamic> currentFormMap() {
    final id = _activeForm;
    if (id == null) return const {};
    return Map.unmodifiable(_forms[id] ?? const {});
  }

  /// Flat map of the active form's fields + meta keys, keyed for
  /// binding resolution under `form.*`.
  Map<String, dynamic> allFormsMap() {
    final out = <String, dynamic>{};
    // Expose every form under its id (nested access).
    _forms.forEach((k, v) => out[k] = v);
    // Flatten the active form at the top so `{{form.email}}` works
    // in the 99% case with a single form on screen.
    if (_activeForm != null) {
      final active = _forms[_activeForm!] ?? const {};
      active.forEach((k, v) => out[k] = v);
    }
    out['valid'] = _currentFormValid();
    out['dirty'] = (_forms[_activeForm] ?? const {}).isNotEmpty;
    out['errors'] =
        Map<String, dynamic>.from(_formErrors[_activeForm] ?? const {});
    return out;
  }

  bool _currentFormValid() {
    final errs = _formErrors[_activeForm] ?? const {};
    return errs.isEmpty;
  }

  void setFieldError(String name, String message, {String? formId}) {
    final id = formId ?? _activeForm ?? '_default';
    _formErrors.putIfAbsent(id, () => {});
    if (message.isEmpty) {
      _formErrors[id]!.remove(name);
    } else {
      _formErrors[id]![name] = message;
    }
    notifyListeners();
  }

  // ── state.* ────────────────────────────────────────────────────

  void setState(Map<String, dynamic> patch, {String scope = 'widget'}) {
    _state.addAll(patch);
    if (scope == 'global') {
      _persistGlobalState();
    }
    notifyListeners();
  }

  /// Full state replacement — clears all keys and sets new ones.
  void replaceState(Map<String, dynamic> newState) {
    _state.clear();
    _state.addAll(newState);
    notifyListeners();
  }

  dynamic getState(String key) => _state[key];

  // ── data.* ─────────────────────────────────────────────────────

  void setDataLoading(String key) {
    final e = _data.putIfAbsent(key, () => DataEntry());
    e.loading = true;
    e.error = null;
    notifyListeners();
  }

  void setDataValue(String key, dynamic value) {
    final e = _data.putIfAbsent(key, () => DataEntry());
    e.value = value;
    e.loading = false;
    e.error = null;
    e.stale = false;
    notifyListeners();
  }

  void setDataError(String key, String message) {
    final e = _data.putIfAbsent(key, () => DataEntry());
    e.loading = false;
    e.error = message;
    notifyListeners();
  }

  void setDataStale(String key) {
    _data[key]?.stale = true;
    notifyListeners();
  }

  dynamic getDataValue(String key) => _data[key]?.value;

  /// Flat map exposed under `data.*`. Each binding appears both
  /// by key (→ value) and as `<key>.loading` / `<key>.error` /
  /// `<key>.stale`.
  Map<String, dynamic> dataMap() {
    final out = <String, dynamic>{};
    _data.forEach((k, e) {
      out[k] = e.value;
    });
    // Meta fields nested as a sub-map so the binding engine can
    // look them up via `data.key.loading` etc.
    _data.forEach((k, e) {
      final existing = out[k];
      if (existing is Map) {
        final merged = Map<String, dynamic>.from(existing);
        merged['loading'] = e.loading;
        merged['error'] = e.error;
        merged['stale'] = e.stale;
        out[k] = merged;
      }
    });
    return out;
  }

  /// Builds a [BindingScope] suitable for expression evaluation.
  /// Pass [extra] to layer loop-scope variables (`item`, `index`,
  /// `first`, `last`).
  BindingScope buildScope({Map<String, dynamic>? extra}) {
    final scope = BindingScope.root(
      form: allFormsMap(),
      state: _state,
      data: dataMap(),
      ctx: ctx,
      session: session,
      app: app,
    );
    if (extra != null && extra.isNotEmpty) {
      return scope.fork(extra);
    }
    return scope;
  }

  // ── Global state persistence ───────────────────────────────────

  String get _globalKey => 'widget.state.$appId.$paneKey';

  Future<void> _hydrateGlobalState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_globalKey);
      if (raw == null || raw.isEmpty) return;
      final parsed = jsonDecode(raw);
      if (parsed is Map) {
        parsed.forEach((k, v) => _state[k.toString()] = v);
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> _persistGlobalState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_globalKey, jsonEncode(_state));
    } catch (_) {}
  }
}

/// Mutable container for one data binding's current value.
class DataEntry {
  dynamic value;
  bool loading = false;
  String? error;
  bool stale = false;
}
