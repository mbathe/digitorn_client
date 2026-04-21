/// Typed mirror of the daemon's universal credentials system.
///
/// Every app declares a `credentials_schema:` block in its YAML. The
/// daemon compiles it and serves it through:
///
///   GET /api/apps/{app_id}/credentials/schema
///
/// This file contains the Dart models the client parses from that
/// endpoint. Rendering logic lives in `lib/ui/credentials/*`.
///
/// Provider types
///   * `api_key`           single secret + optional extras
///   * `multi_field`       several named fields (Slack, AWS, Twilio)
///   * `oauth2`            external browser consent flow
///   * `connection_string` single URL + optional test
///   * `mcp_server`        subprocess with credentials + lifecycle
///   * `custom`            daemon-specific handler (rendered as api_key)
///
/// Statuses used by the status chip:
///   pending | filled | valid | expired | invalid | refreshing | error
library;

import 'package:flutter/material.dart';

class CredentialSchema {
  final String appId;
  final bool required;
  final bool complete;
  final List<String> missingRequired;
  final List<CredentialProvider> providers;

  const CredentialSchema({
    required this.appId,
    required this.required,
    required this.complete,
    required this.missingRequired,
    required this.providers,
  });

  static const empty = CredentialSchema(
    appId: '',
    required: false,
    complete: true,
    missingRequired: [],
    providers: [],
  );

  factory CredentialSchema.fromJson(Map<String, dynamic> j) {
    final schemaBlock = j['credentials_schema'] as Map? ?? const {};
    final providerDefs = (schemaBlock['providers'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();

    final runtimeProviders = (j['providers'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();

    // Merge the runtime state (filled, masked_fields, status, oauth) onto
    // the YAML-declared shape so the form has everything in one object.
    final merged = <CredentialProvider>[];
    for (final runtime in runtimeProviders) {
      final name = runtime['name'] as String? ?? '';
      final def = providerDefs.firstWhere(
        (d) => d['name'] == name,
        orElse: () => <String, dynamic>{},
      );
      merged.add(CredentialProvider.fromJson({...def, ...runtime}));
    }
    // Defensive: if the runtime list is empty, fall back to the declared
    // providers so the user can at least fill the form.
    if (merged.isEmpty) {
      for (final def in providerDefs) {
        merged.add(CredentialProvider.fromJson(def));
      }
    }

    return CredentialSchema(
      appId: j['app_id'] as String? ?? '',
      required: schemaBlock['required'] == true,
      complete: j['complete'] == true,
      missingRequired: (j['missing_required'] as List? ?? const [])
          .map((e) => e.toString())
          .toList(),
      providers: merged,
    );
  }

  bool get hasProviders => providers.isNotEmpty;

  int get requiredMissingCount => missingRequired.length;
}

class CredentialProvider {
  /// Canonical id ("openai", "notion", "notion-mcp"). Used in URL paths.
  final String name;
  final String label;

  /// api_key | multi_field | oauth2 | connection_string | mcp_server | custom
  final String type;

  /// per_user | per_app_shared | system_wide
  final String scope;

  final bool required;
  final bool filled;
  final String status;

  /// Preview of each secret field — e.g. `{api_key: "sk-...x4ab"}`.
  final Map<String, String> maskedFields;
  final String? lastUpdated;

  // ── OAuth-specific ──────────────────────────────────────────────
  final String? oauthStatus;
  final String? oauthAccount;
  final List<String> oauthScopes;
  final String? oauthExpiresAt;

  // ── MCP-specific ────────────────────────────────────────────────
  final bool? mcpRunning;
  final int? mcpToolsCount;
  final String? mcpLastError;
  final String? mcpTransportType;

  /// YAML-declared field definitions. Drives the form rendering.
  final List<CredentialField> fields;

  /// Optional help text shown above the form.
  final String description;

  /// Optional URL shown as "Where do I get this?" link.
  final String docsUrl;

  /// Provider-specific extras (OAuth scopes list, MCP command, etc.)
  /// Kept as a raw map so the UI can pull whatever it needs without
  /// adding a new field to this class every time.
  final Map<String, dynamic> extras;

  const CredentialProvider({
    required this.name,
    required this.label,
    required this.type,
    this.scope = 'per_user',
    this.required = false,
    this.filled = false,
    this.status = 'pending',
    this.maskedFields = const {},
    this.lastUpdated,
    this.oauthStatus,
    this.oauthAccount,
    this.oauthScopes = const [],
    this.oauthExpiresAt,
    this.mcpRunning,
    this.mcpToolsCount,
    this.mcpLastError,
    this.mcpTransportType,
    this.fields = const [],
    this.description = '',
    this.docsUrl = '',
    this.extras = const {},
  });

  factory CredentialProvider.fromJson(Map<String, dynamic> j) {
    final rawFields = (j['fields'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => CredentialField.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);

    return CredentialProvider(
      name: j['name'] as String? ?? '',
      label: (j['label'] as String?)?.trim().isNotEmpty == true
          ? j['label'] as String
          : _humanise(j['name'] as String? ?? ''),
      type: j['type'] as String? ?? 'api_key',
      scope: j['scope'] as String? ?? 'per_user',
      required: j['required'] == true,
      filled: j['filled'] == true,
      status: j['status'] as String? ?? 'pending',
      maskedFields: (j['masked_fields'] as Map? ?? const {})
          .map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')),
      lastUpdated: j['last_updated'] as String?,
      oauthStatus: j['oauth_status'] as String?,
      oauthAccount: j['oauth_account'] as String?,
      oauthScopes: (j['oauth_scopes'] as List? ?? const [])
          .map((e) => e.toString())
          .toList(),
      oauthExpiresAt: j['oauth_expires_at'] as String?,
      mcpRunning: j['mcp_running'] as bool?,
      mcpToolsCount: (j['mcp_tools_count'] as num?)?.toInt(),
      mcpLastError: j['mcp_last_error'] as String?,
      mcpTransportType: j['mcp_transport_type'] as String?,
      fields: rawFields,
      description: j['description'] as String? ?? '',
      docsUrl: j['docs_url'] as String? ?? '',
      extras: Map<String, dynamic>.from(j['extras'] as Map? ?? const {}),
    );
  }

  bool get isOAuth => type == 'oauth2';
  bool get isMcp => type == 'mcp_server';
  bool get isConnectionString => type == 'connection_string';
  bool get isMultiField => type == 'multi_field';
  bool get isApiKey => type == 'api_key' || type == 'custom';

  /// Used by the admin-only lock: a regular user cannot write to
  /// per_app_shared or system_wide — the UI has to show a banner.
  bool get isEditableByEndUser => scope == 'per_user';

  bool get blocksActivation =>
      required && (!filled || status == 'invalid' || status == 'expired');

  CredentialProvider withMcpStatus({
    bool? running,
    int? toolsCount,
    String? lastError,
  }) =>
      CredentialProvider(
        name: name,
        label: label,
        type: type,
        scope: scope,
        required: required,
        filled: filled,
        status: status,
        maskedFields: maskedFields,
        lastUpdated: lastUpdated,
        oauthStatus: oauthStatus,
        oauthAccount: oauthAccount,
        oauthScopes: oauthScopes,
        oauthExpiresAt: oauthExpiresAt,
        mcpRunning: running ?? mcpRunning,
        mcpToolsCount: toolsCount ?? mcpToolsCount,
        mcpLastError: lastError ?? mcpLastError,
        mcpTransportType: mcpTransportType,
        fields: fields,
        description: description,
        docsUrl: docsUrl,
        extras: extras,
      );
}

class CredentialField {
  final String name;

  /// secret | string | url | select | connection_string | int | bool
  final String type;

  final String label;
  final bool required;
  final String placeholder;
  final String description;
  final String helpText;
  final String validationRegex;
  final List<String> options;

  /// Optional URL to documentation explaining where to get this value.
  final String docsUrl;

  const CredentialField({
    required this.name,
    required this.type,
    this.label = '',
    this.required = false,
    this.placeholder = '',
    this.description = '',
    this.helpText = '',
    this.validationRegex = '',
    this.options = const [],
    this.docsUrl = '',
  });

  factory CredentialField.fromJson(Map<String, dynamic> j) => CredentialField(
        name: j['name'] as String? ?? '',
        type: j['type'] as String? ?? 'string',
        label: (j['label'] as String?)?.trim().isNotEmpty == true
            ? j['label'] as String
            : _humanise(j['name'] as String? ?? ''),
        required: j['required'] == true,
        placeholder: j['placeholder'] as String? ?? '',
        description: j['description'] as String? ?? '',
        helpText: j['help_text'] as String? ?? '',
        validationRegex: j['validation_regex'] as String? ?? '',
        options: (j['options'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        docsUrl: j['docs_url'] as String? ?? '',
      );

  bool get isSecret => type == 'secret';
  bool get isSelect => type == 'select';
  bool get isUrl => type == 'url' || type == 'connection_string';

  /// Live client-side validation. Returns null when ok, error string
  /// otherwise. The server re-validates so this is just a fast path.
  String? validate(String value) {
    if (required && value.isEmpty) return 'Required';
    if (value.isEmpty) return null;
    if (validationRegex.isNotEmpty) {
      try {
        if (!RegExp(validationRegex).hasMatch(value)) {
          return 'Invalid format';
        }
      } catch (_) {
        // Bad regex from daemon — fall through silently.
      }
    }
    if (isUrl) {
      final u = Uri.tryParse(value);
      if (u == null || u.scheme.isEmpty || u.host.isEmpty) {
        return 'Invalid URL';
      }
    }
    return null;
  }
}

/// One row in the "My Credentials" global dashboard. This is what
/// `GET /api/users/me/credentials` returns per entry.
class UserCredentialEntry {
  final String appId;
  final String providerName;
  final String providerLabel;
  final String type;
  final String scope;
  final String status;
  final bool filled;
  final Map<String, String> maskedFields;
  final String? lastUpdated;

  const UserCredentialEntry({
    required this.appId,
    required this.providerName,
    required this.providerLabel,
    required this.type,
    required this.scope,
    required this.status,
    required this.filled,
    required this.maskedFields,
    this.lastUpdated,
  });

  factory UserCredentialEntry.fromJson(Map<String, dynamic> j) =>
      UserCredentialEntry(
        appId: j['app_id'] as String? ?? '_global',
        providerName: j['provider'] as String? ?? j['name'] as String? ?? '',
        providerLabel: (j['label'] as String?)?.trim().isNotEmpty == true
            ? j['label'] as String
            : _humanise(j['provider'] as String? ?? j['name'] as String? ?? ''),
        type: j['type'] as String? ?? 'api_key',
        scope: j['scope'] as String? ?? 'per_user',
        status: j['status'] as String? ?? 'pending',
        filled: j['filled'] == true,
        maskedFields: (j['masked_fields'] as Map? ?? const {})
            .map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')),
        lastUpdated: j['last_updated'] as String?,
      );

  bool get isGlobal => appId == '_global' || appId.isEmpty;
}

/// Colour palette for the status chip — called from every form widget
/// so the colours stay consistent.
@immutable
class CredentialStatusStyle {
  final Color fg;
  final Color bg;
  final String label;
  const CredentialStatusStyle(this.fg, this.bg, this.label);
}

String _humanise(String snake) {
  if (snake.isEmpty) return '';
  return snake
      .split(RegExp(r'[_\-]'))
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');
}
