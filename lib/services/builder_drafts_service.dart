/// App Builder drafts. A draft is an in-progress app spec the user
/// is assembling in the builder surface — name, description, prompt,
/// permissions, tools, credentials. Saved server-side so the user
/// can pick up on another device and so the builder can recover
/// after a crash.
///
/// Backed by the daemon routes:
///   * GET    /api/builder/drafts          — list all the user's drafts
///   * POST   /api/builder/drafts          — create a new draft
///   * GET    /api/builder/drafts/{id}     — full draft payload
///   * PUT    /api/builder/drafts/{id}     — upsert edits
///   * DELETE /api/builder/drafts/{id}     — drop a draft
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'auth_service.dart';

class BuilderDraft {
  final String id;
  final String name;
  final String? description;
  final String? mode; // conversation | background
  final DateTime? updatedAt;
  final DateTime? createdAt;

  /// Full spec payload. We keep it loosely typed here — the builder
  /// surface knows its own shape; this service just ships the JSON.
  final Map<String, dynamic> spec;

  const BuilderDraft({
    required this.id,
    required this.name,
    required this.spec,
    this.description,
    this.mode,
    this.updatedAt,
    this.createdAt,
  });

  factory BuilderDraft.fromJson(Map<String, dynamic> j) => BuilderDraft(
        id: (j['id'] ?? j['draft_id'] ?? '') as String,
        name: (j['name'] ?? 'Untitled draft') as String,
        description: j['description'] as String?,
        mode: j['mode'] as String?,
        createdAt: _parseDate(j['created_at']),
        updatedAt: _parseDate(j['updated_at']),
        spec: j['spec'] is Map
            ? (j['spec'] as Map).cast<String, dynamic>()
            : <String, dynamic>{},
      );

  static DateTime? _parseDate(dynamic v) {
    if (v is String) return DateTime.tryParse(v);
    if (v is num) {
      return DateTime.fromMillisecondsSinceEpoch((v * 1000).toInt());
    }
    return null;
  }
}

class BuilderDraftsService extends ChangeNotifier {
  static final BuilderDraftsService _i = BuilderDraftsService._();
  factory BuilderDraftsService() => _i;
  BuilderDraftsService._();

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 12),
    validateStatus: (s) => s != null && s < 500,
  ))..interceptors.add(AuthService().authInterceptor);

  List<BuilderDraft> _drafts = const [];
  List<BuilderDraft> get drafts => _drafts;

  bool _loading = false;
  bool get loading => _loading;
  String? _error;
  String? get error => _error;

  Options get _opts => Options(headers: {
        if (AuthService().accessToken != null)
          'Authorization': 'Bearer ${AuthService().accessToken}',
        'Content-Type': 'application/json',
      });

  Future<void> refresh() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final r = await _dio.get(
        '${AuthService().baseUrl}/api/builder/drafts',
        options: _opts,
      );
      if (r.statusCode != 200) {
        _error = 'HTTP ${r.statusCode}';
        _drafts = const [];
        _loading = false;
        notifyListeners();
        return;
      }
      final raw = r.data is Map && r.data['drafts'] is List
          ? r.data['drafts'] as List
          : (r.data is List ? r.data as List : const []);
      _drafts = raw
          .whereType<Map>()
          .map((m) => BuilderDraft.fromJson(m.cast<String, dynamic>()))
          .toList()
        ..sort((a, b) {
          final l = b.updatedAt ?? DateTime(0);
          final r = a.updatedAt ?? DateTime(0);
          return l.compareTo(r);
        });
      _loading = false;
      notifyListeners();
    } on DioException catch (e) {
      _error = e.message ?? e.toString();
      _loading = false;
      notifyListeners();
    }
  }

  Future<BuilderDraft?> create({
    required String name,
    String? description,
    String mode = 'conversation',
    Map<String, dynamic>? spec,
  }) async {
    try {
      final r = await _dio.post(
        '${AuthService().baseUrl}/api/builder/drafts',
        data: {
          'name': name,
          'description': ?description,
          'mode': mode,
          'spec': spec ?? <String, dynamic>{},
        },
        options: _opts,
      );
      if ((r.statusCode ?? 0) >= 300) return null;
      final data = r.data is Map && r.data['draft'] is Map
          ? (r.data['draft'] as Map).cast<String, dynamic>()
          : (r.data as Map).cast<String, dynamic>();
      final draft = BuilderDraft.fromJson(data);
      _drafts = [draft, ..._drafts];
      notifyListeners();
      return draft;
    } on DioException {
      return null;
    }
  }

  Future<BuilderDraft?> get(String id) async {
    try {
      final r = await _dio.get(
        '${AuthService().baseUrl}/api/builder/drafts/$id',
        options: _opts,
      );
      if (r.statusCode != 200 || r.data is! Map) return null;
      final data = r.data['draft'] is Map
          ? (r.data['draft'] as Map).cast<String, dynamic>()
          : (r.data as Map).cast<String, dynamic>();
      return BuilderDraft.fromJson(data);
    } on DioException {
      return null;
    }
  }

  Future<bool> update(
    String id, {
    String? name,
    String? description,
    Map<String, dynamic>? spec,
  }) async {
    try {
      final body = <String, dynamic>{};
      if (name != null) body['name'] = name;
      if (description != null) body['description'] = description;
      if (spec != null) body['spec'] = spec;
      final r = await _dio.put(
        '${AuthService().baseUrl}/api/builder/drafts/$id',
        data: body,
        options: _opts,
      );
      if ((r.statusCode ?? 0) >= 300) return false;
      _drafts = _drafts.map((d) {
        if (d.id != id) return d;
        return BuilderDraft(
          id: d.id,
          name: name ?? d.name,
          description: description ?? d.description,
          mode: d.mode,
          createdAt: d.createdAt,
          updatedAt: DateTime.now(),
          spec: spec ?? d.spec,
        );
      }).toList();
      notifyListeners();
      return true;
    } on DioException {
      return false;
    }
  }

  Future<bool> delete(String id) async {
    try {
      final r = await _dio.delete(
        '${AuthService().baseUrl}/api/builder/drafts/$id',
        options: _opts,
      );
      if ((r.statusCode ?? 0) >= 300) return false;
      _drafts = _drafts.where((d) => d.id != id).toList();
      notifyListeners();
      return true;
    } on DioException {
      return false;
    }
  }
}
