/// Daemon "modules" are shared python packages / tool bundles the
/// user can enable across multiple apps. Distinct from MCP servers
/// (separate processes) and from packages (full apps). Backed by
/// three daemon routes:
///
///   * GET /api/discovery/modules       — browsable catalogue
///   * GET /api/modules                 — modules enabled for this user
///   * GET /api/modules/{id}/health     — liveness + version
///   * POST /api/modules/{id}/enable    — flip on for current user
///   * DELETE /api/modules/{id}         — disable
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'auth_service.dart';

class Module {
  final String id;
  final String name;
  final String description;
  final String? author;
  final String? version;
  final String? icon;
  final String category;
  final List<String> tags;
  final bool enabled;
  final bool verified;
  final int installCount;
  final String? repoUrl;
  final String? longDescription;

  const Module({
    required this.id,
    required this.name,
    this.description = '',
    this.author,
    this.version,
    this.icon,
    this.category = 'general',
    this.tags = const [],
    this.enabled = false,
    this.verified = false,
    this.installCount = 0,
    this.repoUrl,
    this.longDescription,
  });

  factory Module.fromJson(Map<String, dynamic> j) => Module(
        id: j['id'] as String? ?? j['name'] as String? ?? '',
        name: j['name'] as String? ?? '',
        description: j['description'] as String? ?? '',
        author: j['author'] as String?,
        version: j['version'] as String?,
        icon: j['icon'] as String?,
        category: j['category'] as String? ?? 'general',
        tags: (j['tags'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        enabled: j['enabled'] == true,
        verified: j['verified'] == true,
        installCount: (j['install_count'] as num?)?.toInt() ?? 0,
        repoUrl: j['repo_url'] as String?,
        longDescription: j['long_description'] as String?,
      );
}

class ModuleHealth {
  final String id;
  final String status;
  final String? version;
  final String? error;
  final DateTime? lastChecked;
  const ModuleHealth({
    required this.id,
    required this.status,
    this.version,
    this.error,
    this.lastChecked,
  });

  factory ModuleHealth.fromJson(String id, Map<String, dynamic> j) {
    return ModuleHealth(
      id: id,
      status: j['status'] as String? ?? 'unknown',
      version: j['version'] as String?,
      error: j['error'] as String?,
      lastChecked: _parseDate(j['last_checked']),
    );
  }

  static DateTime? _parseDate(dynamic v) {
    if (v is String) return DateTime.tryParse(v);
    if (v is num) {
      return DateTime.fromMillisecondsSinceEpoch((v * 1000).toInt());
    }
    return null;
  }

  bool get isHealthy => status == 'ok' || status == 'running';
}

class ModulesService extends ChangeNotifier {
  static final ModulesService _i = ModulesService._();
  factory ModulesService() => _i;
  ModulesService._();

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 6),
    receiveTimeout: const Duration(seconds: 15),
    validateStatus: (s) => s != null && s < 500,
  ))..interceptors.add(AuthService().authInterceptor);

  List<Module> _catalog = const [];
  List<Module> get catalog => _catalog;

  List<Module> _enabled = const [];
  List<Module> get enabled => _enabled;

  final Map<String, ModuleHealth> _health = {};
  Map<String, ModuleHealth> get health => Map.unmodifiable(_health);

  bool _loading = false;
  bool get loading => _loading;
  String? _error;
  String? get error => _error;

  Options get _opts => Options(headers: {
        if (AuthService().accessToken != null)
          'Authorization': 'Bearer ${AuthService().accessToken}',
      });

  Future<void> refresh() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final results = await Future.wait([
        _fetchCatalog(),
        _fetchEnabled(),
      ]);
      _catalog = results[0];
      _enabled = results[1];
      // Merge enabled flag into catalog rows so the discover tab
      // can render the right badge without a second lookup.
      final enabledIds = _enabled.map((m) => m.id).toSet();
      _catalog = _catalog
          .map((m) => m.enabled == enabledIds.contains(m.id)
              ? m
              : Module(
                  id: m.id,
                  name: m.name,
                  description: m.description,
                  author: m.author,
                  version: m.version,
                  icon: m.icon,
                  category: m.category,
                  tags: m.tags,
                  enabled: enabledIds.contains(m.id),
                  verified: m.verified,
                  installCount: m.installCount,
                  repoUrl: m.repoUrl,
                  longDescription: m.longDescription,
                ))
          .toList();
      _loading = false;
      notifyListeners();
    } on DioException catch (e) {
      _error = e.message ?? e.toString();
      _loading = false;
      notifyListeners();
    }
  }

  Future<List<Module>> _fetchCatalog() async {
    final r = await _dio.get(
      '${AuthService().baseUrl}/api/discovery/modules',
      options: _opts,
    );
    if (r.statusCode != 200) return const [];
    final list = r.data is Map && r.data['modules'] is List
        ? r.data['modules'] as List
        : (r.data is List ? r.data as List : const []);
    return list
        .whereType<Map>()
        .map((m) => Module.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  Future<List<Module>> _fetchEnabled() async {
    final r = await _dio.get(
      '${AuthService().baseUrl}/api/modules',
      options: _opts,
    );
    if (r.statusCode != 200) return const [];
    final list = r.data is Map && r.data['modules'] is List
        ? r.data['modules'] as List
        : (r.data is List ? r.data as List : const []);
    return list
        .whereType<Map>()
        .map((m) => Module.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  Future<ModuleHealth?> fetchHealth(String id) async {
    try {
      final r = await _dio.get(
        '${AuthService().baseUrl}/api/modules/$id/health',
        options: _opts,
      );
      if (r.statusCode != 200 || r.data is! Map) return null;
      final h = ModuleHealth.fromJson(
          id, (r.data as Map).cast<String, dynamic>());
      _health[id] = h;
      notifyListeners();
      return h;
    } on DioException {
      return null;
    }
  }

  Future<bool> enable(String id) async {
    try {
      final r = await _dio.post(
        '${AuthService().baseUrl}/api/modules/$id/enable',
        options: _opts,
      );
      if ((r.statusCode ?? 0) >= 300) return false;
      await refresh();
      return true;
    } on DioException {
      return false;
    }
  }

  Future<bool> disable(String id) async {
    try {
      final r = await _dio.delete(
        '${AuthService().baseUrl}/api/modules/$id',
        options: _opts,
      );
      if ((r.statusCode ?? 0) >= 300) return false;
      _enabled = _enabled.where((m) => m.id != id).toList();
      await refresh();
      return true;
    } on DioException {
      return false;
    }
  }
}
