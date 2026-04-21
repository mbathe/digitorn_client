/// Encode/decode session configurations as portable base64 URLs so a
/// user can share a setup with a colleague by pasting one link.
///
/// The link format is intentionally simple and self-describing:
///
///   `digitorn://session?d=<base64url(json)>`
///
/// The JSON blob mirrors the export shape (`schema: digitorn.session.v1`)
/// so we can round-trip with `Copy as JSON` from the dashboard.
library;

import 'dart:convert';

class ShareableSession {
  final String appId;
  final String name;
  final Map<String, dynamic> params;
  final Map<String, dynamic> routingKeys;
  final String workspace;
  final String prompt;
  final Map<String, dynamic> metadata;

  const ShareableSession({
    required this.appId,
    required this.name,
    this.params = const {},
    this.routingKeys = const {},
    this.workspace = '',
    this.prompt = '',
    this.metadata = const {},
  });

  Map<String, dynamic> toJson() => {
        'schema': 'digitorn.session.v1',
        'app_id': appId,
        'session': {
          'name': name,
          'params': params,
          'routing_keys': routingKeys,
          if (workspace.isNotEmpty) 'workspace': workspace,
        },
        if (prompt.isNotEmpty || metadata.isNotEmpty)
          'payload': {
            if (prompt.isNotEmpty) 'prompt': prompt,
            if (metadata.isNotEmpty) 'metadata': metadata,
          },
      };

  static ShareableSession? fromJson(Map<String, dynamic> j) {
    if (j['schema'] != 'digitorn.session.v1') return null;
    final session = j['session'] as Map?;
    if (session == null) return null;
    final payload = j['payload'] as Map? ?? const {};
    return ShareableSession(
      appId: j['app_id'] as String? ?? '',
      name: session['name'] as String? ?? '',
      params: Map<String, dynamic>.from(session['params'] ?? const {}),
      routingKeys:
          Map<String, dynamic>.from(session['routing_keys'] ?? const {}),
      workspace: session['workspace'] as String? ?? '',
      prompt: payload['prompt'] as String? ?? '',
      metadata: Map<String, dynamic>.from(payload['metadata'] ?? const {}),
    );
  }
}

class SessionShareCodec {
  /// Build a shareable link from a session blob.
  static String encode(ShareableSession s) {
    final json = jsonEncode(s.toJson());
    final b64 = base64Url.encode(utf8.encode(json));
    return 'digitorn://session?d=$b64';
  }

  /// Parse anything the user might paste — full link, base64 only,
  /// or even raw JSON. Returns null when nothing decodes cleanly.
  static ShareableSession? decode(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    // 1. Full link with `d=` query param
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.queryParameters['d'] != null) {
      final r = _tryDecodeBase64(uri.queryParameters['d']!);
      if (r != null) return r;
    }

    // 2. Bare base64 string
    final r = _tryDecodeBase64(trimmed);
    if (r != null) return r;

    // 3. Raw JSON
    try {
      final j = jsonDecode(trimmed);
      if (j is Map<String, dynamic>) {
        return ShareableSession.fromJson(j);
      }
    } catch (_) {}
    return null;
  }

  static ShareableSession? _tryDecodeBase64(String s) {
    try {
      // Tolerate base64 with or without padding.
      var padded = s;
      while (padded.length % 4 != 0) {
        padded += '=';
      }
      final decoded = utf8.decode(base64Url.decode(padded));
      final j = jsonDecode(decoded);
      if (j is Map<String, dynamic>) {
        return ShareableSession.fromJson(j);
      }
    } catch (_) {}
    return null;
  }
}
