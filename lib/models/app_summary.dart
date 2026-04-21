/// Unified app record surfaced by `/api/apps/*` after the April 2026
/// "no more package vs app" migration. Every field matches the daemon
/// response shape 1:1; older daemons that don't emit some fields fall
/// back to sane defaults so existing callers still compile.
class AppSummary {
  final String appId;
  final String name;
  final String version;
  final String mode;
  final List<String> agents;
  final List<String> modules;
  final int totalTools;
  final int totalCategories;
  final String workspaceMode;
  final String greeting;

  // ── Multi-tenant scope ─────────────────────────────────────────
  /// `"system"` (visible to every user, admin-managed) or
  /// `"user"` (private to [ownerUserId]). Default `"system"` for
  /// back-compat with daemons that haven't emitted the field yet.
  final String scope;

  /// User id that owns this install when [scope] == `"user"`.
  /// Empty string otherwise.
  final String ownerUserId;

  /// Emoji from the YAML (e.g. `'💬'`). Empty string if the app has
  /// none declared — callers should fall back to a Material icon.
  final String icon;

  /// Custom accent colour (e.g. `'#4f8cff'`). Empty string if none.
  final String color;

  /// Free-form author-provided description of the app. Empty string
  /// if none declared.
  final String description;

  /// Category tag from the YAML (e.g. `'general'`, `'data'`).
  final String category;

  /// Free-form tags declared in the YAML, e.g. `['chat', 'assistant']`.
  final List<String> tags;

  /// Author string from the manifest. Empty if none.
  final String author;

  /// True if this app is a built-in / non-removable app (e.g. the
  /// default `digitorn-chat`). Built-in apps cannot be stopped or
  /// deleted — the daemon rejects those operations.
  final bool builtin;

  /// All trigger types wired in this app, e.g. `['cron', 'telegram']`.
  /// Empty for non-background apps. Surfaced in the dashboard hero
  /// chips and used to compute the [SessionPayloadMode].
  final List<String> triggerTypes;

  /// Background apps can either run a single user-scoped session
  /// auto-created on first use (`mono`) or accept many explicit ones
  /// (`multi`).
  final String sessionMode;

  /// Cap when [sessionMode] is `multi`. Zero / null means unlimited.
  final int maxSessionsPerUser;

  /// Raw declarative payload schema from the YAML, when the app
  /// declares one. The client parses this with `PayloadSchema.parse`
  /// to render a typed form; when null, the dashboard falls back to
  /// the generic key/value editor.
  final Map<String, dynamic>? payloadSchema;

  /// First-turn chips shown in the empty state to seed the chat.
  /// Each entry is the opaque map the daemon returned (usually
  /// `{title, message, icon}`) so the UI can render without a
  /// typed model here.
  final List<Map<String, dynamic>> quickPrompts;

  // ── Lifecycle / provenance (April 2026 unified shape) ─────────────────

  /// Runtime state of the deployed app:
  ///   * `"running"` — healthy and serving requests
  ///   * `"disabled"` — admin-disabled; invisible to non-admin users
  ///   * `"broken"` — deploy failed; see [deployError]
  ///   * `"not_deployed"` — installed on disk but never successfully
  ///     deployed (manifest compile failed, optional dependency missing…)
  final String runtimeStatus;

  /// Install lifecycle on the daemon's disk:
  ///   * `"installed"` — files present, hash verified
  ///   * `"broken"` — install on disk is corrupt / hash mismatch
  ///   * `"upgrading"` — an upgrade is in flight
  ///   * `"uninstalling"` — a removal is in flight
  final String installStatus;

  /// Last deploy error message when [runtimeStatus] == `"broken"`.
  /// Null / empty for healthy and not-yet-deployed apps.
  final String? deployError;

  /// Origin of the install:
  ///   * `"builtin"` — bundled with Digitorn
  ///   * `"local"` — imported from a local directory
  ///   * `"hub"` — installed from the public hub (v2)
  ///   * `"git"` — cloned from a Git URL (v2)
  final String sourceType;

  /// Resolvable URI where this app was fetched from. Shape depends on
  /// [sourceType]: `file://…`, `bundle://…`, `hub://owner/name@ver`,
  /// `git+https://…`. Surfaced in the "View source" admin panel.
  final String sourceUri;

  /// Absolute path where the daemon unpacked the app's files on disk.
  /// Surfaced in the "View source" panel and in uninstall confirmations.
  final String installDir;

  /// SHA-256 of the installed content. When a deploy re-compiles the
  /// manifest the hash is cross-checked against [driftCurrentHash];
  /// any mismatch lights up the "drifted from source" badge.
  final String hash;

  /// User id that performed the install / last upgrade. Empty when
  /// the installer isn't known (older installs, system boot).
  final String installedBy;

  /// ISO-8601 timestamp of the original install, passed through as a
  /// String so we don't lose precision if the daemon is in a
  /// different timezone than the client.
  final String installedAt;

  /// Whether the live install has drifted from the source registry
  /// (hash mismatch). Only populated for deployed apps; false for
  /// built-ins and never-deployed installs.
  final bool drifted;

  /// The hash the daemon recomputed on its side at drift-check time;
  /// compared with [hash] to decide [drifted].
  final String driftCurrentHash;

  AppSummary({
    required this.appId,
    required this.name,
    required this.version,
    this.mode = '',
    this.agents = const [],
    this.modules = const [],
    this.totalTools = 0,
    this.totalCategories = 0,
    this.workspaceMode = 'auto',
    this.greeting = '',
    this.icon = '',
    this.color = '',
    this.description = '',
    this.category = '',
    this.tags = const [],
    this.author = '',
    this.builtin = false,
    this.triggerTypes = const [],
    this.sessionMode = 'mono',
    this.maxSessionsPerUser = 1,
    this.payloadSchema,
    this.quickPrompts = const [],
    this.scope = 'system',
    this.ownerUserId = '',
    this.runtimeStatus = 'running',
    this.installStatus = 'installed',
    this.deployError,
    // Default to empty so a missing `source_type` from an older
    // daemon never pollutes the Hub "Built-in" bucket. The adapter
    // in `PackageService._summaryToPackage` folds empty into
    // `"local"` on the way to the UI.
    this.sourceType = '',
    this.sourceUri = '',
    this.installDir = '',
    this.hash = '',
    this.installedBy = '',
    this.installedAt = '',
    this.drifted = false,
    this.driftCurrentHash = '',
  });

  /// True when this install is private to a user (not system-wide).
  bool get isUserScope => scope == 'user';
  bool get isSystemScope => scope == 'system';

  /// Runtime-state shortcuts for the Hub tabs.
  bool get isRunning => runtimeStatus == 'running';
  bool get isDisabled => runtimeStatus == 'disabled';
  bool get isBroken => runtimeStatus == 'broken';
  bool get isNotDeployed => runtimeStatus == 'not_deployed';

  /// True when the card should show a "launch" affordance — the only
  /// runtime state the user can actually open a session against.
  bool get isLaunchable => isRunning;

  /// True when the Hub should prompt "Delete / Reinstall" — the install
  /// or runtime state is in an error shape that needs the user's
  /// attention.
  bool get needsAttention => isBroken || installStatus == 'broken';

  /// Pretty-print the provenance for the admin / View-source dialog.
  /// Null-safe: returns an empty string when fields are missing.
  String get sourceLabel {
    switch (sourceType) {
      case 'builtin':
        return 'Built-in';
      case 'local':
        return 'Local folder';
      case 'hub':
        return 'Hub';
      case 'git':
        return 'Git';
      default:
        return sourceType;
    }
  }

  factory AppSummary.fromJson(Map<String, dynamic> json) {
    final raw = json['payload_schema'];
    final drift = json['drift'];
    final driftMap = drift is Map
        ? drift.cast<String, dynamic>()
        : const <String, dynamic>{};
    final quick = json['quick_prompts'];
    final quickList = <Map<String, dynamic>>[];
    if (quick is List) {
      for (final q in quick) {
        if (q is Map) quickList.add(q.cast<String, dynamic>());
      }
    }
    return AppSummary(
      appId: json['app_id'] ?? '',
      name: json['name'] ?? '',
      version: json['version'] ?? '',
      mode: json['mode'] ?? '',
      agents: List<String>.from(json['agents'] ?? const []),
      modules: List<String>.from(json['modules'] ?? const []),
      totalTools: (json['total_tools'] as num?)?.toInt() ?? 0,
      totalCategories: (json['total_categories'] as num?)?.toInt() ?? 0,
      workspaceMode: json['workspace_mode'] ?? 'auto',
      greeting: json['greeting'] ?? '',
      icon: json['icon'] ?? '',
      color: json['color'] ?? '',
      description: json['description'] ?? '',
      category: json['category'] ?? '',
      tags: List<String>.from(json['tags'] ?? const []),
      author: json['author'] ?? '',
      builtin: json['builtin'] == true || json['source_type'] == 'builtin',
      triggerTypes: List<String>.from(json['trigger_types'] ?? const []),
      sessionMode: json['session_mode'] as String? ?? 'mono',
      maxSessionsPerUser:
          (json['max_sessions_per_user'] as num?)?.toInt() ?? 1,
      payloadSchema: raw is Map<String, dynamic>
          ? raw
          : (raw is Map ? raw.cast<String, dynamic>() : null),
      quickPrompts: quickList,
      scope: (json['scope'] as String?)?.toLowerCase() == 'user'
          ? 'user'
          : 'system',
      ownerUserId: (json['owner_user_id'] as String?) ?? '',
      runtimeStatus: (json['runtime_status'] as String?) ?? 'running',
      installStatus: (json['install_status'] as String?) ?? 'installed',
      deployError: (json['deploy_error'] as String?)?.isEmpty == true
          ? null
          : json['deploy_error'] as String?,
      // Empty fallback when the daemon didn't emit the field. Never
      // default to `"builtin"` — that would inflate the Hub's
      // Built-in chip with every unlabeled install.
      sourceType: (json['source_type'] as String?) ?? '',
      sourceUri: (json['source_uri'] as String?) ?? '',
      installDir: (json['install_dir'] as String?) ?? '',
      hash: (json['hash'] as String?) ?? '',
      installedBy: (json['installed_by'] as String?) ?? '',
      installedAt: (json['installed_at'] as String?) ?? '',
      drifted: driftMap['drifted'] == true,
      driftCurrentHash:
          (driftMap['current_hash'] as String?) ?? '',
    );
  }

  AppSummary copyWith({
    String? name,
    String? version,
    String? runtimeStatus,
    String? installStatus,
    String? deployError,
    bool? drifted,
    String? driftCurrentHash,
  }) =>
      AppSummary(
        appId: appId,
        name: name ?? this.name,
        version: version ?? this.version,
        mode: mode,
        agents: agents,
        modules: modules,
        totalTools: totalTools,
        totalCategories: totalCategories,
        workspaceMode: workspaceMode,
        greeting: greeting,
        icon: icon,
        color: color,
        description: description,
        category: category,
        tags: tags,
        author: author,
        builtin: builtin,
        triggerTypes: triggerTypes,
        sessionMode: sessionMode,
        maxSessionsPerUser: maxSessionsPerUser,
        payloadSchema: payloadSchema,
        quickPrompts: quickPrompts,
        scope: scope,
        ownerUserId: ownerUserId,
        runtimeStatus: runtimeStatus ?? this.runtimeStatus,
        installStatus: installStatus ?? this.installStatus,
        deployError: deployError ?? this.deployError,
        sourceType: sourceType,
        sourceUri: sourceUri,
        installDir: installDir,
        hash: hash,
        installedBy: installedBy,
        installedAt: installedAt,
        drifted: drifted ?? this.drifted,
        driftCurrentHash: driftCurrentHash ?? this.driftCurrentHash,
      );
}
