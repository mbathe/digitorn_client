/// Lightweight ChangeNotifier wrapping the daemon's `/api/hub/me`,
/// `/api/hub/login`, `/api/hub/logout` so the UI doesn't re-query
/// the daemon on every mount.
///
/// The daemon owns the actual hub session token — we only cache the
/// public [HubSession] payload.
///
/// Mirror of the web `useHubSession` Zustand store
/// (`digitorn_web/src/stores/hub.ts`).
library;

import 'package:flutter/foundation.dart';

import '../models/hub/hub_models.dart';
import 'hub_service.dart';

class HubSessionService extends ChangeNotifier {
  HubSessionService._();
  static final HubSessionService _instance = HubSessionService._();
  factory HubSessionService() => _instance;

  HubSession? _session;
  bool _loading = false;
  bool _loggingIn = false;
  String? _error;

  HubSession? get session => _session;
  bool get loading => _loading;
  bool get loggingIn => _loggingIn;
  String? get error => _error;
  bool get isLoggedIn => _session?.loggedIn == true;

  /// Refresh the cached session by re-querying the daemon.
  Future<void> refresh() async {
    _loading = true;
    notifyListeners();
    try {
      _session = await HubService().me();
      _error = null;
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Returns true on success. On 401 (bad credentials) [error] is set
  /// to a user-readable message and the method returns false.
  Future<bool> login({required String email, required String password}) async {
    _loggingIn = true;
    _error = null;
    notifyListeners();
    try {
      final s = await HubService().login(email: email, password: password);
      if (s == null) {
        _error = 'Invalid email or password';
        _loggingIn = false;
        notifyListeners();
        return false;
      }
      _session = s;
      _loggingIn = false;
      notifyListeners();
      return s.loggedIn;
    } catch (e) {
      _error = e.toString();
      _loggingIn = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> logout() async {
    try {
      await HubService().logout();
    } finally {
      _session = const HubSession(loggedIn: false, hubUrl: '');
      _error = null;
      notifyListeners();
    }
  }

  void clearError() {
    if (_error != null) {
      _error = null;
      notifyListeners();
    }
  }
}
