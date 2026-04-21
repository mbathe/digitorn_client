import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'auth_service.dart';

// ─── Models ───────────────────────────────────────────────────────────────────

class ToolCategory {
  final String id;
  final String name;
  final String description;
  final int toolCount;
  final String icon;

  const ToolCategory({
    required this.id,
    required this.name,
    required this.description,
    this.toolCount = 0,
    this.icon = '⚙',
  });

  factory ToolCategory.fromJson(Map<String, dynamic> j) => ToolCategory(
        id: j['id'] as String? ?? j['name'] as String? ?? '',
        name: j['name'] as String? ?? '',
        description: j['description'] as String? ?? '',
        toolCount: j['tool_count'] as int? ?? 0,
        icon: j['icon'] as String? ?? '⚙',
      );
}

class ToolRecord {
  final String name;
  final String label;
  final String description;
  final String category;
  final Map<String, dynamic> schema;
  final bool isSilent;

  const ToolRecord({
    required this.name,
    required this.label,
    required this.description,
    required this.category,
    this.schema = const {},
    this.isSilent = false,
  });

  String get displayName => label.isNotEmpty ? label : name;
  String get riskLevel {
    final r = schema['risk_level'] as String? ?? '';
    return r;
  }

  factory ToolRecord.fromJson(Map<String, dynamic> j) => ToolRecord(
        name: j['name'] as String? ?? '',
        label: j['label'] as String? ?? j['name'] as String? ?? '',
        description: j['description'] as String? ?? '',
        category: j['category'] as String? ?? '',
        schema: Map<String, dynamic>.from(j['schema'] ?? j['parameters'] ?? {}),
        isSilent: j['silent'] as bool? ?? false,
      );
}

class ToolExecuteResult {
  final bool success;
  final dynamic data;
  final String error;
  final double durationMs;

  const ToolExecuteResult({
    required this.success,
    this.data,
    this.error = '',
    this.durationMs = 0,
  });
}

// ─── ToolService ──────────────────────────────────────────────────────────────

class ToolService extends ChangeNotifier {
  static final ToolService _i = ToolService._();
  factory ToolService() => _i;
  ToolService._();

  List<ToolCategory> categories = [];
  List<ToolRecord> searchResults = [];
  Map<String, List<ToolRecord>> _categoryCache = {};
  bool isLoading = false;
  bool isSearching = false;
  String? _lastAppId;

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 15),
  ));

  Options get _opts {
    final token = AuthService().accessToken;
    return Options(headers: {
      if (token != null) 'Authorization': 'Bearer $token',
    });
  }

  String get _base => AuthService().baseUrl;

  // ── Categories ─────────────────────────────────────────────────────────────

  Future<void> loadCategories(String appId) async {
    if (_lastAppId == appId && categories.isNotEmpty) return;
    _lastAppId = appId;
    isLoading = true;
    notifyListeners();

    try {
      final resp = await _dio.get(
        '$_base/api/apps/$appId/tools/categories',
        options: _opts,
      );
      if (resp.data?['success'] == true) {
        final list = resp.data['data']['categories'] as List? ?? [];
        categories = list.map((j) => ToolCategory.fromJson(j as Map<String, dynamic>)).toList();
      }
    } catch (e) {
      debugPrint('ToolService.loadCategories: $e');
    }
    isLoading = false;
    notifyListeners();
  }

  /// Synchronous accessor for the cached tools of a category.
  /// Returns an empty list when `loadCategory(appId, id)` hasn't run
  /// yet for this category. UIs that render already-loaded data
  /// (tools panel) use this instead of awaiting.
  List<ToolRecord> categoryTools(String categoryId) =>
      _categoryCache[categoryId] ?? const <ToolRecord>[];

  Future<List<ToolRecord>> loadCategory(String appId, String categoryId) async {
    if (_categoryCache.containsKey(categoryId)) return _categoryCache[categoryId]!;

    try {
      final resp = await _dio.get(
        '$_base/api/apps/$appId/tools/categories/$categoryId',
        options: _opts,
        queryParameters: {'limit': 50},
      );
      if (resp.data?['success'] == true) {
        final list = resp.data['data']['tools'] as List? ?? [];
        final tools = list.map((j) => ToolRecord.fromJson(j as Map<String, dynamic>)).toList();
        _categoryCache[categoryId] = tools;
        return tools;
      }
    } catch (e) {
      debugPrint('ToolService.loadCategory: $e');
    }
    return [];
  }

  // ── Search ─────────────────────────────────────────────────────────────────

  Timer? _debounce;

  void search(String appId, String query) {
    _debounce?.cancel();
    if (query.trim().isEmpty) {
      searchResults = [];
      notifyListeners();
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () => _doSearch(appId, query));
  }

  Future<void> _doSearch(String appId, String query) async {
    isSearching = true;
    notifyListeners();
    try {
      final resp = await _dio.get(
        '$_base/api/apps/$appId/tools/search',
        queryParameters: {'query': query, 'limit': 20},
        options: _opts,
      );
      if (resp.data?['success'] == true) {
        final list = resp.data['data']['tools'] as List? ?? [];
        searchResults = list.map((j) => ToolRecord.fromJson(j as Map<String, dynamic>)).toList();
      }
    } catch (e) {
      debugPrint('ToolService.search: $e');
    }
    isSearching = false;
    notifyListeners();
  }

  // ── Tool detail ────────────────────────────────────────────────────────────

  Future<ToolRecord?> getToolDetail(String appId, String toolName) async {
    try {
      final resp = await _dio.get(
        '$_base/api/apps/$appId/tools/$toolName',
        options: _opts,
      );
      if (resp.data?['success'] == true) {
        return ToolRecord.fromJson(resp.data['data'] as Map<String, dynamic>);
      }
    } catch (e) {
      debugPrint('ToolService.getToolDetail: $e');
    }
    return null;
  }

  // ── Execute ────────────────────────────────────────────────────────────────

  Future<ToolExecuteResult> executeTool(
      String appId, String toolName, Map<String, dynamic> params) async {
    final sw = Stopwatch()..start();
    try {
      final resp = await _dio.post(
        '$_base/api/apps/$appId/tools/$toolName/execute',
        data: {'params': params},
        options: _opts,
      );
      sw.stop();
      if (resp.data?['success'] == true) {
        return ToolExecuteResult(
          success: true,
          data: resp.data['data'],
          durationMs: sw.elapsedMilliseconds.toDouble(),
        );
      }
      return ToolExecuteResult(
        success: false,
        error: resp.data?['error'] as String? ?? 'Unknown error',
        durationMs: sw.elapsedMilliseconds.toDouble(),
      );
    } catch (e) {
      sw.stop();
      return ToolExecuteResult(
        success: false,
        error: e.toString(),
        durationMs: sw.elapsedMilliseconds.toDouble(),
      );
    }
  }

  void clearCache() {
    categories = [];
    searchResults = [];
    _categoryCache = {};
    _lastAppId = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}
