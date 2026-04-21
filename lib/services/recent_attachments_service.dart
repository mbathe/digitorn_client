import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One entry in the "Recently attached" list surfaced inside the
/// composer's attach menu. Path is the filesystem / tmp / workspace
/// identifier; [isImage] matches the `_attachments` record shape
/// used by the chat panel so re-attach is a straight copy.
class RecentAttachment {
  final String name;
  final String path;
  final bool isImage;
  final DateTime lastUsed;

  const RecentAttachment({
    required this.name,
    required this.path,
    required this.isImage,
    required this.lastUsed,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'path': path,
        'isImage': isImage,
        'lastUsed': lastUsed.millisecondsSinceEpoch,
      };

  factory RecentAttachment.fromJson(Map<String, dynamic> json) =>
      RecentAttachment(
        name: json['name'] as String? ?? '',
        path: json['path'] as String? ?? '',
        isImage: json['isImage'] as bool? ?? false,
        lastUsed: DateTime.fromMillisecondsSinceEpoch(
            (json['lastUsed'] as num?)?.toInt() ?? 0),
      );

  /// Coarse "Xm ago" label shown in the pill. Anything older than a
  /// day falls back to the calendar date.
  String get ago {
    final diff = DateTime.now().difference(lastUsed);
    if (diff.inSeconds < 60) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'yesterday';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    final d = lastUsed;
    return '${d.day}/${d.month}';
  }
}

/// Tracks the last ~N file attachments across all sessions so the
/// user can re-send common files (screenshot, dataset, prompt file)
/// without re-navigating the file picker each time.
///
/// Persisted to SharedPreferences so the list survives app restarts.
/// Keyed by absolute path — re-attaching the same file bumps it to
/// the front instead of creating a duplicate row.
class RecentAttachmentsService extends ChangeNotifier {
  static final RecentAttachmentsService _i = RecentAttachmentsService._();
  factory RecentAttachmentsService() => _i;
  RecentAttachmentsService._();

  static const _kKey = 'recent_attachments';
  static const int _cap = 20;

  List<RecentAttachment> _items = const [];
  bool _loaded = false;

  List<RecentAttachment> get items => List.unmodifiable(_items);
  bool get isLoaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _items = decoded
              .whereType<Map>()
              .map((m) => RecentAttachment.fromJson(m.cast<String, dynamic>()))
              .where((r) => r.path.isNotEmpty)
              .toList();
        }
      }
    } catch (e) {
      debugPrint('RecentAttachmentsService.load error: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> record({
    required String name,
    required String path,
    required bool isImage,
  }) async {
    if (path.isEmpty) return;
    final next = _items.where((r) => r.path != path).toList();
    next.insert(
      0,
      RecentAttachment(
        name: name,
        path: path,
        isImage: isImage,
        lastUsed: DateTime.now(),
      ),
    );
    if (next.length > _cap) {
      next.removeRange(_cap, next.length);
    }
    _items = next;
    notifyListeners();
    await _persist();
  }

  Future<void> remove(String path) async {
    final next = _items.where((r) => r.path != path).toList();
    if (next.length == _items.length) return;
    _items = next;
    notifyListeners();
    await _persist();
  }

  Future<void> clear() async {
    if (_items.isEmpty) return;
    _items = const [];
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kKey,
        jsonEncode(_items.map((r) => r.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('RecentAttachmentsService.persist error: $e');
    }
  }
}
