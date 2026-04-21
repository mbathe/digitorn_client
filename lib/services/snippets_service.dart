/// Reusable prompt snippets stored locally. Each snippet has a name,
/// a body that may contain `{{variable}}` placeholders, and a list of
/// the variable names extracted from the body. The chat panel exposes
/// them through a `/snippet` slash command + a button in the toolbar.
///
/// Stored as a single JSON blob in SharedPreferences — small enough
/// (a few KB at most) that we don't bother with a real DB.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Snippet {
  final String id;
  String name;
  String body;
  String? description;
  DateTime updatedAt;

  Snippet({
    required this.id,
    required this.name,
    required this.body,
    this.description,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  /// All `{{var}}` names appearing in the body, in order, deduped.
  List<String> get variables {
    final out = <String>[];
    final seen = <String>{};
    final matches = RegExp(r'\{\{(\w+)\}\}').allMatches(body);
    for (final m in matches) {
      final name = m.group(1)!;
      if (seen.add(name)) out.add(name);
    }
    return out;
  }

  /// Substitute every `{{var}}` with the matching value from [values].
  /// Missing variables are left as-is so the user notices.
  String render(Map<String, String> values) {
    return body.replaceAllMapped(RegExp(r'\{\{(\w+)\}\}'), (m) {
      final v = values[m.group(1)!];
      return v ?? m.group(0)!;
    });
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'body': body,
        if (description != null) 'description': description,
        'updated_at': updatedAt.toIso8601String(),
      };

  factory Snippet.fromJson(Map<String, dynamic> j) => Snippet(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        body: j['body'] as String? ?? '',
        description: j['description'] as String?,
        updatedAt: DateTime.tryParse(j['updated_at'] as String? ?? '') ??
            DateTime.now(),
      );
}

class SnippetsService extends ChangeNotifier {
  static final SnippetsService _i = SnippetsService._();
  factory SnippetsService() => _i;
  SnippetsService._();

  static const _key = 'snippets.v1';

  List<Snippet> _items = [];
  List<Snippet> get items => List.unmodifiable(_items);
  bool _loaded = false;
  bool get isLoaded => _loaded;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null || raw.isEmpty) {
      // Seed with one example so the empty state isn't completely
      // mysterious on first run.
      _items = [
        Snippet(
          id: 'seed-1',
          name: 'Code review',
          description: 'Ask the agent to review a piece of code',
          body:
              'Review the following {{language}} code and suggest improvements. '
              'Focus on correctness, readability, and edge cases.\n\n```{{language}}\n{{code}}\n```',
        ),
        Snippet(
          id: 'seed-2',
          name: 'Explain like I\'m 5',
          description: 'Get a beginner-friendly explanation',
          body: 'Explain {{topic}} as if I were 5 years old, '
              'with concrete analogies and no jargon.',
        ),
      ];
      await _save();
    } else {
      try {
        final list = jsonDecode(raw) as List;
        _items = list
            .whereType<Map>()
            .map((m) => Snippet.fromJson(m.cast<String, dynamic>()))
            .toList();
      } catch (_) {
        _items = [];
      }
    }
    _items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _loaded = true;
    notifyListeners();
  }

  Future<void> upsert(Snippet s) async {
    final i = _items.indexWhere((x) => x.id == s.id);
    s.updatedAt = DateTime.now();
    if (i >= 0) {
      _items[i] = s;
    } else {
      _items.insert(0, s);
    }
    _items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await _save();
    notifyListeners();
  }

  Future<void> delete(String id) async {
    _items.removeWhere((s) => s.id == id);
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _key, jsonEncode(_items.map((s) => s.toJson()).toList()));
  }

  /// Generate a new collision-free ID. Time-based + random suffix —
  /// fine for a local-only feature.
  static String newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${(DateTime.now().millisecond * 1000).toRadixString(36)}';
}
