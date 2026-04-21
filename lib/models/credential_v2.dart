/// Typed mirror of the daemon's **unified credential model** —
/// every credential is owned by the user (or by the daemon admin)
/// and granted to apps explicitly. Replaces the older per-app
/// schema declared in `credential_schema.dart` (kept for the
/// legacy form, dead-ended for new code).
///
/// See FLUTTER_CREDENTIALS_FORMS_v2.md for the full backend
/// contract. The shapes in this file are 1:1 with the JSON the
/// daemon returns under `data.credentials[]`, `data.grants[]`, etc.
library;

import 'package:flutter/material.dart';

class CredentialV2 {
  /// Stable id assigned by the daemon (e.g. `c_abc123`).
  final String id;

  /// User-given label — `personal`, `work`, etc. May be empty when
  /// the user didn't pick one (we'll default to "default" in the UI).
  final String label;

  /// `user` | `system`. System creds are admin-managed and read-only
  /// for regular users.
  final String ownerType;

  /// `api_key` | `multi_field` | `oauth2` | `connection_string` | `mcp_server`
  final String providerType;

  /// `openai`, `notion`, etc. Maps to the recipe in
  /// `credential_probe.dart` for the test-connection button.
  final String providerName;

  /// Friendly provider label — used in the picker headline.
  /// Daemon may not always send it; we fall back to `_humanise(providerName)`.
  final String providerLabel;

  /// `pending` | `filled` | `valid` | `expired` | `invalid` | `error`
  final String status;

  /// Per-field masked previews — daemon returns last-4 of secret
  /// fields keyed by their canonical name (e.g. `OPENAI_API_KEY: "sk-...x4ab"`).
  final Map<String, String> maskedFields;

  /// OAuth-only — the linked third-party account, e.g. `marie@notion.so`.
  final String? oauthAccount;

  /// OAuth-only — the scopes already granted on this credential.
  final List<String> oauthScopes;

  /// OAuth-only — token expiry (ISO8601 string).
  final String? oauthExpiresAt;

  /// `created_at`, `updated_at` from the daemon — both ISO8601.
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// True when this is an admin-owned credential. The UI must hide
  /// edit / delete affordances for it.
  bool get isSystem => ownerType == 'system';

  /// True when this is an OAuth credential. Drives picker layout.
  bool get isOauth => providerType == 'oauth2';

  const CredentialV2({
    required this.id,
    required this.label,
    required this.ownerType,
    required this.providerType,
    required this.providerName,
    this.providerLabel = '',
    this.status = 'pending',
    this.maskedFields = const {},
    this.oauthAccount,
    this.oauthScopes = const [],
    this.oauthExpiresAt,
    this.createdAt,
    this.updatedAt,
  });

  factory CredentialV2.fromJson(Map<String, dynamic> j) {
    final masked = <String, String>{};
    final raw = j['masked_fields'] ??
        (j['display_metadata'] is Map
            ? (j['display_metadata'] as Map)['masked_fields']
            : null);
    if (raw is Map) {
      raw.forEach((k, v) {
        masked[k.toString()] = v?.toString() ?? '';
      });
    }
    return CredentialV2(
      id: j['id'] as String? ?? '',
      label: (j['label'] as String?)?.trim().isNotEmpty == true
          ? j['label'] as String
          : 'default',
      ownerType: j['owner_type'] as String? ?? 'user',
      providerType: j['provider_type'] as String? ?? 'api_key',
      providerName: j['provider_name'] as String? ?? '',
      providerLabel: j['provider_label'] as String? ?? '',
      status: j['status'] as String? ?? 'filled',
      maskedFields: masked,
      oauthAccount: j['oauth_account'] as String?,
      oauthScopes: (j['oauth_scopes'] as List? ?? const [])
          .map((e) => e.toString())
          .toList(),
      oauthExpiresAt: j['oauth_expires_at'] as String?,
      createdAt: _parseDate(j['created_at']),
      updatedAt: _parseDate(j['updated_at']),
    );
  }

  String get displayProviderLabel =>
      providerLabel.isNotEmpty ? providerLabel : _humanise(providerName);

  /// First non-empty masked preview — used by tile subtitles.
  String? get firstMaskedPreview {
    for (final v in maskedFields.values) {
      if (v.isNotEmpty) return v;
    }
    return null;
  }
}

/// One row from `GET /api/credentials/{id}/grants` or
/// `GET /api/credentials-grants` — links a credential to an app.
class CredentialGrant {
  final String credentialId;
  final String appId;

  /// Optional friendly name pulled from `applications` join when the
  /// daemon returns an enriched payload.
  final String? appName;

  /// OAuth-only — the subset of scopes actually granted to this
  /// app (may be narrower than the credential's union of scopes).
  final List<String> scopesGranted;

  final DateTime? grantedAt;

  const CredentialGrant({
    required this.credentialId,
    required this.appId,
    this.appName,
    this.scopesGranted = const [],
    this.grantedAt,
  });

  factory CredentialGrant.fromJson(Map<String, dynamic> j) => CredentialGrant(
        credentialId: j['credential_id'] as String? ?? '',
        appId: j['app_id'] as String? ?? '',
        appName: j['app_name'] as String?,
        scopesGranted: (j['scopes_granted'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        grantedAt: _parseDate(j['granted_at']),
      );
}

/// One field a provider expects when creating / editing a credential.
/// Pulled from the `field_spec` block of either:
///  - the auth-required SSE error (when the daemon prompts for it), or
///  - a separate `GET /api/credentials/providers/{provider_name}` call
///    used by the standalone manager.
class ProviderFieldSpec {
  final String name;

  /// `secret` | `string` | `url` | `select` | `int` | `bool`
  final String type;
  final String label;
  final bool required;
  final String placeholder;
  final String description;
  final String validationRegex;
  final List<String> options;
  final String docsUrl;

  const ProviderFieldSpec({
    required this.name,
    this.type = 'string',
    this.label = '',
    this.required = false,
    this.placeholder = '',
    this.description = '',
    this.validationRegex = '',
    this.options = const [],
    this.docsUrl = '',
  });

  factory ProviderFieldSpec.fromJson(Map<String, dynamic> j) =>
      ProviderFieldSpec(
        name: j['name'] as String? ?? '',
        type: j['type'] as String? ?? 'string',
        label: (j['label'] as String?)?.trim().isNotEmpty == true
            ? j['label'] as String
            : _humanise(j['name'] as String? ?? ''),
        required: j['required'] == true,
        placeholder: j['placeholder'] as String? ?? '',
        description: j['description'] as String? ?? '',
        validationRegex: j['validation_regex'] as String? ?? '',
        options: (j['options'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        docsUrl: j['docs_url'] as String? ?? '',
      );

  bool get isSecret => type == 'secret';
  bool get isSelect => type == 'select';
  bool get isUrl => type == 'url';

  String? validate(String value) {
    if (required && value.isEmpty) return 'Required';
    if (value.isEmpty) return null;
    if (validationRegex.isNotEmpty) {
      try {
        if (!RegExp(validationRegex).hasMatch(value)) return 'Invalid format';
      } catch (_) {}
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

/// Decoded form of the SSE event the daemon emits when a turn
/// stops because of a missing / invalid credential. Covers both:
///
///   * `type: "credential_required"` — no credential at all
///     (create-or-reuse flow)
///   * `type: "credential_auth_required"` — first-use with no grant
///     yet (has [candidates] to reuse)
///
/// Both codes funnel through the same picker, only the UX copy
/// changes.
class CredentialAuthRequiredEvent {
  final String provider;
  final String providerType;
  final String appId;
  final String userId;

  /// The `code` on the daemon payload. Either `credential_required`
  /// or `credential_auth_required`. Lets the picker pick the right
  /// headline ("Access required" vs "Credential expired").
  final String code;

  /// The single missing secret key when known (e.g. `DEEPSEEK_API_KEY`).
  /// Null when the daemon only sent provider-level info.
  final String? field;

  /// Human-facing error message from the daemon, shown verbatim
  /// inside the picker as a yellow banner.
  final String? errorMessage;

  final List<CredentialV2> candidates;
  final List<ProviderFieldSpec> fieldSpec;

  /// Provider-level label from the `field_spec.label`, used when
  /// the well-known catalogue doesn't know this provider.
  final String providerLabel;

  /// The agent that asked for this credential (e.g. `builder`).
  /// The daemon now passes it alongside `provider` so the picker
  /// can render "Builder asks for a DeepSeek key" instead of the
  /// generic "DeepSeek access required".
  final String? agentId;

  /// Internal daemon provider id (e.g. `builder_brain`). Not shown
  /// to the user — kept for debugging / telemetry only.
  final String? providerId;

  final List<String> oauthMissingScopes;
  final String? detail;

  const CredentialAuthRequiredEvent({
    required this.provider,
    required this.providerType,
    required this.appId,
    required this.userId,
    this.code = 'credential_auth_required',
    this.field,
    this.errorMessage,
    this.candidates = const [],
    this.fieldSpec = const [],
    this.providerLabel = '',
    this.agentId,
    this.providerId,
    this.oauthMissingScopes = const [],
    this.detail,
  });

  /// Build from the daemon SSE payload. Tolerant to two shapes:
  ///   * new: `{ provider, provider_type, field, field_spec: { name, label, type, fields:[...] } }`
  ///   * legacy: `{ provider, provider_type, field_spec: [...] }`
  factory CredentialAuthRequiredEvent.fromJson(Map<String, dynamic> j) {
    final candidatesRaw = j['candidates'] as List? ?? const [];
    final candidates = candidatesRaw
        .whereType<Map>()
        .map((m) => CredentialV2.fromJson(m.cast<String, dynamic>()))
        .toList();
    final spec = j['field_spec'];
    final fields = <ProviderFieldSpec>[];
    String? nestedProvider;
    String? nestedProviderType;
    String nestedProviderLabel = '';
    if (spec is Map) {
      final m = spec.cast<String, dynamic>();
      nestedProvider = m['name'] as String?;
      nestedProviderType = m['type'] as String?;
      nestedProviderLabel = (m['label'] as String?) ?? '';
      final list = m['fields'] as List? ?? const [];
      for (final f in list) {
        if (f is Map) {
          fields.add(ProviderFieldSpec.fromJson(f.cast<String, dynamic>()));
        }
      }
    } else if (spec is List) {
      for (final f in spec) {
        if (f is Map) {
          fields.add(ProviderFieldSpec.fromJson(f.cast<String, dynamic>()));
        }
      }
    }

    // Provider resolution — the daemon sometimes sends the agent id
    // in `provider` (e.g. "builder_brain") while the lookup key at
    // turn time is the real provider ("deepseek"). We try in order:
    //
    //   1. "for provider 'X'" extracted from the error message —
    //      this is what the daemon reports as the lookup key and is
    //      the single most reliable signal.
    //   2. Derive from the field name — `DEEPSEEK_API_KEY` →
    //      `deepseek`, `OPENAI_API_KEY` → `openai`, etc.
    //   3. nested `field_spec.name`.
    //   4. Top-level `provider` (last because the daemon may lie).
    //
    // If the first match disagrees with the top-level provider we
    // log a warning but take the error-derived value, since that's
    // the one the turn manager will use when re-looking-up.
    final errorMessage = j['error'] as String? ?? j['message'] as String?;
    final fieldName = j['field'] as String?;
    final topLevelProvider = (j['provider'] as String?)?.trim();
    final derivedFromError = _extractProviderFromError(errorMessage);
    final derivedFromField = _deriveProviderFromFieldName(fieldName);
    final provider = _pickProvider(
      derivedFromError,
      derivedFromField,
      nestedProvider,
      topLevelProvider,
    );
    final providerType =
        (j['provider_type'] as String?)?.trim().isNotEmpty == true
            ? j['provider_type'] as String
            : (nestedProviderType ?? 'api_key');

    // If the daemon only sent a single `field:` name and no
    // field_spec.fields, synthesise a minimal one so the create form
    // still renders.
    if (fields.isEmpty && fieldName != null && fieldName.isNotEmpty) {
      fields.add(ProviderFieldSpec(
        name: fieldName,
        type: 'secret',
        label: fieldName,
        required: true,
      ));
    }

    return CredentialAuthRequiredEvent(
      provider: provider,
      providerType: providerType,
      appId: j['app_id'] as String? ?? '',
      userId: j['user_id'] as String? ?? '',
      code: j['code'] as String? ?? 'credential_auth_required',
      field: fieldName,
      errorMessage: j['error'] as String? ?? j['message'] as String?,
      candidates: candidates,
      fieldSpec: fields,
      providerLabel: nestedProviderLabel,
      agentId: (j['agent_id'] as String?)?.trim().isNotEmpty == true
          ? j['agent_id'] as String
          : null,
      providerId: (j['provider_id'] as String?)?.trim().isNotEmpty == true
          ? j['provider_id'] as String
          : null,
      oauthMissingScopes: (j['oauth_missing_scopes'] as List? ?? const [])
          .map((e) => e.toString())
          .toList(),
      detail: j['detail'] as String?,
    );
  }

  bool get isOauth => providerType == 'oauth2';

  /// True when this event represents an expired/invalid credential
  /// rather than a first-use grant. Drives the picker's headline
  /// copy ("credential expired" vs "access required").
  bool get isReauth =>
      code == 'credential_required' && candidates.isEmpty &&
      (errorMessage?.toLowerCase().contains('expired') == true ||
          errorMessage?.toLowerCase().contains('invalid') == true);
}

// ── Provider resolution helpers ────────────────────────────────────
// These workaround the daemon bug where `provider` at the top level
// sometimes holds the agent id instead of the real provider key.

/// Try to extract the provider name from an error message like
/// `Missing credential: 'DEEPSEEK_API_KEY' for provider 'deepseek'`.
/// Case-insensitive, single-quote and double-quote tolerant.
String? _extractProviderFromError(String? message) {
  if (message == null || message.isEmpty) return null;
  // Look for "provider 'X'" or "provider \"X\"" or even bare
  // `provider X` as a fallback.
  final quoted = RegExp(
    r"""provider\s+["']([^"']+)["']""",
    caseSensitive: false,
  ).firstMatch(message);
  if (quoted != null) return quoted.group(1);
  final bare = RegExp(
    r'provider\s+([a-z0-9_\-]+)',
    caseSensitive: false,
  ).firstMatch(message);
  return bare?.group(1);
}

/// Derive a provider name from a standard secret key shape like
/// `DEEPSEEK_API_KEY` → `deepseek`. Strips the trailing `_API_KEY`
/// / `_KEY` / `_TOKEN` / `_SECRET` suffix.
String? _deriveProviderFromFieldName(String? field) {
  if (field == null || field.isEmpty) return null;
  final upper = field.toUpperCase();
  const suffixes = [
    '_API_KEY',
    '_ACCESS_KEY',
    '_SECRET_KEY',
    '_SECRET',
    '_TOKEN',
    '_KEY',
  ];
  for (final s in suffixes) {
    if (upper.endsWith(s)) {
      return upper.substring(0, upper.length - s.length).toLowerCase();
    }
  }
  return null;
}

/// Pick the most trustworthy provider among the four sources.
/// Order: error-message > field-name > nested field_spec > top-level.
String _pickProvider(
  String? fromError,
  String? fromField,
  String? fromNested,
  String? fromTopLevel,
) {
  for (final candidate in [fromError, fromField, fromNested, fromTopLevel]) {
    if (candidate != null && candidate.trim().isNotEmpty) {
      return candidate.trim();
    }
  }
  return '';
}

/// Provider catalogue entry — used by the "Add credential" sheet
/// when the user manually creates a credential before being asked.
/// Same shape as field_spec but with a friendly label + icon hint.
class ProviderCatalogueEntry {
  final String name;
  final String label;
  final String type;
  final List<ProviderFieldSpec> fields;
  final String? docsUrl;

  const ProviderCatalogueEntry({
    required this.name,
    required this.label,
    required this.type,
    this.fields = const [],
    this.docsUrl,
  });

  factory ProviderCatalogueEntry.fromJson(Map<String, dynamic> j) =>
      ProviderCatalogueEntry(
        name: j['name'] as String? ?? '',
        label: (j['label'] as String?)?.trim().isNotEmpty == true
            ? j['label'] as String
            : _humanise(j['name'] as String? ?? ''),
        type: j['type'] as String? ?? 'api_key',
        fields: (j['fields'] as List? ?? const [])
            .whereType<Map>()
            .map((m) => ProviderFieldSpec.fromJson(m.cast<String, dynamic>()))
            .toList(),
        docsUrl: j['docs_url'] as String?,
      );

  IconData get icon {
    switch (name.toLowerCase()) {
      case 'openai':
        return Icons.bolt_rounded;
      case 'anthropic':
        return Icons.auto_awesome_rounded;
      case 'notion':
        return Icons.description_outlined;
      case 'gmail':
      case 'google':
        return Icons.mail_outline_rounded;
      case 'slack':
        return Icons.tag_rounded;
      case 'telegram':
        return Icons.send_rounded;
      case 'discord':
        return Icons.chat_bubble_outline_rounded;
      case 'github':
        return Icons.hub_outlined;
      case 'aws':
        return Icons.cloud_outlined;
      case 'twilio':
        return Icons.phone_outlined;
      case 'serpapi':
        return Icons.search_rounded;
      case 'deepseek':
        return Icons.psychology_outlined;
      default:
        if (type == 'oauth2') return Icons.link_rounded;
        if (type == 'mcp_server') return Icons.electrical_services_rounded;
        if (type == 'connection_string') return Icons.storage_rounded;
        return Icons.key_rounded;
    }
  }
}

/// Decoded response from `GET /api/apps/{id}/required-secrets`.
/// Drives the pre-session credentials gate: if [missingCount] > 0
/// the UI must block session creation until the user resolves every
/// missing entry (reuse an existing grant or create a new one).
class RequiredSecretsInfo {
  final int missingCount;
  final List<RequiredSecret> secrets;
  final List<String> unusedKeys;

  const RequiredSecretsInfo({
    required this.missingCount,
    required this.secrets,
    this.unusedKeys = const [],
  });

  factory RequiredSecretsInfo.fromJson(Map<String, dynamic> j) {
    final raw = j['secrets'] as List? ?? const [];
    return RequiredSecretsInfo(
      missingCount: (j['missing_count'] as num?)?.toInt() ?? 0,
      secrets: raw
          .whereType<Map>()
          .map((m) => RequiredSecret.fromJson(m.cast<String, dynamic>()))
          .toList(),
      unusedKeys: (j['unused_keys'] as List? ?? const [])
          .map((e) => e.toString())
          .toList(),
    );
  }

  /// All entries the daemon flagged as missing — these are the ones
  /// the pre-session gate must resolve before opening the app.
  List<RequiredSecret> get missing =>
      secrets.where((s) => !s.isSet).toList();
}

/// One row from the `secrets` array of `/required-secrets`.
class RequiredSecret {
  /// The canonical env-var / secret key, e.g. `DEEPSEEK_API_KEY`.
  final String key;

  /// List of YAML paths that reference this secret — handy for the
  /// "used by" subtitle in the gate UI.
  final List<String> usedBy;

  /// True when the current user already has this secret filled
  /// (either directly or via a granted system credential).
  final bool isSet;

  /// `secret` (stored in the credential vault) or `env` (legacy —
  /// env variable read from process env). Only `secret` entries
  /// participate in the credentials gate; `env` ones are noise here.
  final String referenceType;

  /// Well-known provider id (e.g. `deepseek`) when the daemon was
  /// able to unambiguously map the key to a provider in its
  /// catalogue. Null when either:
  ///
  ///   * the key is custom (no provider mapping known)
  ///   * the key is shared by multiple providers (see [providers])
  ///
  /// Picker flow: when this is non-null, create the credential
  /// directly under this provider. When null but [providers] has
  /// entries, the UI must disambiguate.
  final String? provider;

  /// Full list of providers that reference this key. Usually has
  /// exactly one entry (same as [provider]). Multiple entries mean
  /// the same key is used by several providers — the daemon can't
  /// pick one for us so [provider] is null and the client must
  /// decide (prompt the user, or use the first one by default).
  final List<String> providers;

  /// Agent id that declares this secret, when unambiguous. Used
  /// by the gate to enrich the picker copy ("Builder asks for a
  /// DeepSeek key"). Null when the key is shared across multiple
  /// agents.
  final String? agentId;

  /// Full list of agent ids that reference this key. Same
  /// semantics as [providers].
  final List<String> agentIds;

  /// Where the currently-set value comes from when [isSet] is
  /// true — `system` (admin-created), `user` (own credential),
  /// `env` (process environment). Null when unset.
  final String? source;

  const RequiredSecret({
    required this.key,
    this.usedBy = const [],
    this.isSet = false,
    this.referenceType = 'secret',
    this.provider,
    this.providers = const [],
    this.agentId,
    this.agentIds = const [],
    this.source,
  });

  factory RequiredSecret.fromJson(Map<String, dynamic> j) {
    // Pre-Apr-2026 daemons only sent `provider`. Newer ones also
    // send `providers[]`/`agent_id`/`agent_ids[]`. We tolerate both.
    final rawProviders = (j['providers'] as List? ?? const [])
        .map((e) => e.toString())
        .where((s) => s.isNotEmpty)
        .toList();
    final rawAgents = (j['agent_ids'] as List? ?? const [])
        .map((e) => e.toString())
        .where((s) => s.isNotEmpty)
        .toList();
    // Fall back to the single-value field when the list is absent.
    final singleProvider = (j['provider'] as String?)?.trim();
    final providers = rawProviders.isNotEmpty
        ? rawProviders
        : (singleProvider != null && singleProvider.isNotEmpty
            ? [singleProvider]
            : const <String>[]);
    final singleAgent = (j['agent_id'] as String?)?.trim();
    final agents = rawAgents.isNotEmpty
        ? rawAgents
        : (singleAgent != null && singleAgent.isNotEmpty
            ? [singleAgent]
            : const <String>[]);
    return RequiredSecret(
      key: j['key'] as String? ?? '',
      usedBy: (j['used_by'] as List? ?? const [])
          .map((e) => e.toString())
          .toList(),
      isSet: j['is_set'] == true,
      referenceType: j['reference_type'] as String? ?? 'secret',
      provider: singleProvider != null && singleProvider.isNotEmpty
          ? singleProvider
          : (providers.length == 1 ? providers.first : null),
      providers: providers,
      agentId: singleAgent != null && singleAgent.isNotEmpty
          ? singleAgent
          : (agents.length == 1 ? agents.first : null),
      agentIds: agents,
      source: (j['source'] as String?)?.trim().isEmpty == true
          ? null
          : j['source'] as String?,
    );
  }

  /// True when the key is shared by more than one provider — the
  /// client must disambiguate (show a picker) or pick a default.
  bool get isAmbiguousProvider => providers.length > 1;

  /// True when the key is shared by multiple agents — used for
  /// purely informational display.
  bool get isAmbiguousAgent => agentIds.length > 1;
}

DateTime? _parseDate(dynamic v) {
  if (v == null) return null;
  if (v is String) return DateTime.tryParse(v);
  if (v is num) {
    return DateTime.fromMillisecondsSinceEpoch((v * 1000).toInt());
  }
  return null;
}

String _humanise(String snake) {
  if (snake.isEmpty) return '';
  return snake
      .split(RegExp(r'[_\-]'))
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');
}
