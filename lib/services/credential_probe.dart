/// Per-provider "test connection" probes — hits the real API the
/// user is configuring against, with the secret they just typed,
/// and reports OK / 401 / 403 / network error.
///
/// All probes are read-only (list models, get user profile, etc.) so
/// they cost nothing measurable and never mutate state. Adding a new
/// provider = adding one entry to [_recipes].
library;

import 'package:dio/dio.dart';

class CredentialProbeResult {
  final bool ok;
  final String message;
  final int? statusCode;
  final int latencyMs;
  const CredentialProbeResult({
    required this.ok,
    required this.message,
    this.statusCode,
    this.latencyMs = 0,
  });
}

class CredentialProbe {
  static final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 10),
    validateStatus: (_) => true,
  ));

  /// Probes [providerName] using whatever fields are in [fields].
  /// Returns null when the provider is not in the recipe book —
  /// the UI should hide the Test button in that case.
  static Future<CredentialProbeResult?> probe(
    String providerName,
    Map<String, String> fields,
  ) async {
    final recipe = _recipes[providerName.toLowerCase()];
    if (recipe == null) return null;
    final started = DateTime.now();
    try {
      final r = await recipe(fields, _dio);
      final ms = DateTime.now().difference(started).inMilliseconds;
      return CredentialProbeResult(
        ok: r.statusCode != null && r.statusCode! >= 200 && r.statusCode! < 300,
        statusCode: r.statusCode,
        latencyMs: ms,
        message: _summarise(r),
      );
    } on DioException catch (e) {
      return CredentialProbeResult(
        ok: false,
        statusCode: e.response?.statusCode,
        latencyMs: DateTime.now().difference(started).inMilliseconds,
        message: e.response?.statusMessage ?? e.message ?? e.type.name,
      );
    } catch (e) {
      return CredentialProbeResult(
        ok: false,
        latencyMs: DateTime.now().difference(started).inMilliseconds,
        message: e.toString(),
      );
    }
  }

  static String _summarise(Response r) {
    final code = r.statusCode ?? 0;
    if (code >= 200 && code < 300) return 'OK';
    if (code == 401) return 'Invalid credentials (401 Unauthorized)';
    if (code == 403) return 'Forbidden — key valid but lacks scope (403)';
    if (code == 429) return 'Rate-limited (429) — try again in a moment';
    return 'Unexpected status $code';
  }

  /// One probe recipe per provider. Each recipe builds its own
  /// authenticated request from the [fields] map and returns the
  /// raw [Response] for the caller to interpret.
  static final Map<String,
          Future<Response<dynamic>> Function(Map<String, String>, Dio)>
      _recipes = {
    'openai': (f, dio) => dio.get(
          'https://api.openai.com/v1/models',
          options: Options(headers: {
            'Authorization': 'Bearer ${f['api_key'] ?? ''}',
            if (f['organization']?.isNotEmpty == true)
              'OpenAI-Organization': f['organization'],
          }),
        ),
    'anthropic': (f, dio) => dio.get(
          'https://api.anthropic.com/v1/models',
          options: Options(headers: {
            'x-api-key': f['api_key'] ?? '',
            'anthropic-version': '2023-06-01',
          }),
        ),
    'serpapi': (f, dio) => dio.get(
          'https://serpapi.com/account.json',
          queryParameters: {'api_key': f['api_key'] ?? ''},
        ),
    'github': (f, dio) => dio.get(
          'https://api.github.com/user',
          options: Options(headers: {
            'Authorization': 'Bearer ${f['api_key'] ?? f['token'] ?? ''}',
            'Accept': 'application/vnd.github+json',
          }),
        ),
    'telegram': (f, dio) => dio.get(
          'https://api.telegram.org/bot${f['bot_token'] ?? ''}/getMe',
        ),
    'notion': (f, dio) => dio.get(
          'https://api.notion.com/v1/users/me',
          options: Options(headers: {
            'Authorization': 'Bearer ${f['api_key'] ?? ''}',
            'Notion-Version': '2022-06-28',
          }),
        ),
    'slack': (f, dio) => dio.get(
          'https://slack.com/api/auth.test',
          options: Options(headers: {
            'Authorization':
                'Bearer ${f['bot_token'] ?? f['api_key'] ?? ''}',
          }),
        ),
  };

  /// True when the client knows how to probe this provider. Hides the
  /// Test button cleanly when false.
  static bool canProbe(String providerName) =>
      _recipes.containsKey(providerName.toLowerCase());
}
