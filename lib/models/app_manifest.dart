/// Strongly-typed representation of an **app manifest** — the YAML
/// file the daemon ships alongside every installed app. The client
/// parses this once per app activation and uses it to **adapt the
/// entire chat UI**:
///
///   * `execution.workspace_mode` → show / hide the workspace panel
///   * `execution.greeting` → welcome text on the empty state
///   * `app.quick_prompts[]` → clickable starter chips
///   * `features.voice` → show / hide the mic button
///   * `features.attachments` → show / hide the attach menu
///   * `capabilities.grant[]` → determines what the agent can actually
///     do, surfaced in the capabilities drawer
///   * `theme.color`, `app.icon` → header accent + emoji
///
/// Anything not declared in the manifest falls back to a sensible
/// default so **older apps that only had an `AppSummary`** keep
/// rendering correctly. The client is never "broken" by a minimal
/// YAML.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:yaml/yaml.dart' as yaml;

/// The three runtime shapes a Digitorn app can take.
///
///  * `conversation` — classic chat. User sends messages, agent
///    replies in turns, session persists. Default.
///  * `oneshot`      — single-run semantics. The app answers once and
///    is done; the user can fire it again but there is no
///    conversation thread. Good for "summarise this link" or
///    "generate a changelog from these commits".
///  * `background`   — autonomous. The app runs without a user
///    composing messages (triggered by cron, webhook, inbox, …).
///    The chat panel hides the composer and shows status instead;
///    monitoring happens via the Background Tasks panel and the
///    activity inbox.
enum ExecutionMode { conversation, oneshot, background }

ExecutionMode _parseExecutionMode(String? raw) {
  switch ((raw ?? 'conversation').toLowerCase()) {
    case 'oneshot':
    case 'one_shot':
    case 'one-shot':
    case 'single':
      return ExecutionMode.oneshot;
    case 'background':
    case 'bg':
    case 'autonomous':
      return ExecutionMode.background;
    case 'conversation':
    case 'chat':
    default:
      return ExecutionMode.conversation;
  }
}

/// How strict the workspace panel should be.
///
///  * `none`      — the app doesn't use the workspace at all. The
///                  panel is hidden; there's no toggle button; the
///                  chat takes the full width.
///  * `optional`  — the workspace is available but not required.
///                  The user can toggle it on / off.
///  * `required`  — the app refuses to send messages until a
///                  workspace path is set. A blocking banner asks
///                  the user to pick one.
///  * `auto`      — daemon picks based on the modules loaded.
enum WorkspaceMode { none, optional, required, auto }

WorkspaceMode _parseWorkspaceMode(String? raw) {
  switch ((raw ?? 'auto').toLowerCase()) {
    case 'none':
    case 'off':
    case 'disabled':
      return WorkspaceMode.none;
    case 'required':
    case 'mandatory':
      return WorkspaceMode.required;
    case 'optional':
      return WorkspaceMode.optional;
    default:
      return WorkspaceMode.auto;
  }
}

/// One starter prompt that appears in the empty-state grid.
class QuickPrompt {
  final String label;
  /// Emoji or icon character (from the YAML). Empty when none.
  final String icon;
  /// Text inserted into the input when the user taps the chip.
  final String message;

  const QuickPrompt({
    required this.label,
    this.icon = '',
    required this.message,
  });

  factory QuickPrompt.fromJson(Map<String, dynamic> json) => QuickPrompt(
        label: (json['label'] ?? '') as String,
        icon: (json['icon'] ?? '') as String,
        message: (json['message'] ?? json['prompt'] ?? '') as String,
      );
}

/// One module → actions grant block. The UI uses this to populate
/// the capabilities drawer ("this app can: search the web, remember
/// facts, …").
class AppGrant {
  final String module;
  final List<String> actions;
  const AppGrant({required this.module, this.actions = const []});

  factory AppGrant.fromJson(Map<String, dynamic> json) => AppGrant(
        module: (json['module'] ?? '') as String,
        actions: List<String>.from(json['actions'] ?? const []),
      );
}

/// Custom slash commands declared by the app. Not in every YAML
/// yet — fallback is an empty list.
class AppSlashCommand {
  /// The trigger without the leading slash, e.g. `'deploy'`.
  final String command;
  final String description;
  /// When present, the UI pre-fills the input with this template
  /// (supports `{argument}` placeholders).
  final String? template;

  const AppSlashCommand({
    required this.command,
    this.description = '',
    this.template,
  });

  factory AppSlashCommand.fromJson(Map<String, dynamic> json) =>
      AppSlashCommand(
        command: (json['command'] ?? json['name'] ?? '') as String,
        description: (json['description'] ?? '') as String,
        template: json['template'] as String? ?? json['prompt'] as String?,
      );
}

/// Feature toggles — one flag per visible UI element. Any flag
/// that's omitted from the YAML **defaults to enabled** so minimal
/// manifests keep today's full-featured chat. An author who wants a
/// stripped-down experience turns them off explicitly:
///
/// ```yaml
/// features:
///   voice: false
///   attachments: false
/// ```
class AppFeatures {
  /// Microphone button in the composer.
  final bool voice;
  /// Paperclip / attach menu in the composer.
  final bool attachments;
  /// Tools browser button.
  final bool toolsPanel;
  /// Snippets library button.
  final bool snippets;
  /// Background tasks button.
  final bool tasksPanel;
  /// Memory drawer (goal / todos / facts).
  final bool memoryPanel;
  /// Context pressure ring.
  final bool contextRing;
  /// Markdown rendering in assistant bubbles.
  final bool markdown;
  /// Slash command palette.
  final bool slashCommands;
  /// Copy / copy-as-markdown / retry action bar on messages.
  final bool messageActions;
  /// Show the "Live / Reconnecting / Interrupted" pills.
  final bool statusPills;
  /// Token counts footer on completed assistant messages.
  final bool tokenBadges;

  const AppFeatures({
    this.voice = true,
    this.attachments = true,
    this.toolsPanel = true,
    this.snippets = true,
    this.tasksPanel = true,
    this.memoryPanel = true,
    this.contextRing = true,
    this.markdown = true,
    this.slashCommands = true,
    this.messageActions = true,
    this.statusPills = true,
    this.tokenBadges = true,
  });

  /// Every feature off — useful as a base when the manifest opts-in
  /// rather than opts-out.
  const AppFeatures.allOff()
      : voice = false,
        attachments = false,
        toolsPanel = false,
        snippets = false,
        tasksPanel = false,
        memoryPanel = false,
        contextRing = false,
        markdown = false,
        slashCommands = false,
        messageActions = false,
        statusPills = false,
        tokenBadges = false;

  factory AppFeatures.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const AppFeatures();
    bool read(String key, bool fallback) {
      final v = json[key];
      if (v is bool) return v;
      if (v is String) {
        final lower = v.toLowerCase();
        if (lower == 'true' || lower == 'yes' || lower == 'on') return true;
        if (lower == 'false' || lower == 'no' || lower == 'off') return false;
      }
      return fallback;
    }

    return AppFeatures(
      voice: read('voice', true),
      attachments: read('attachments', true),
      toolsPanel: read('tools_panel', true),
      snippets: read('snippets', true),
      tasksPanel: read('tasks_panel', true),
      memoryPanel: read('memory_panel', true),
      contextRing: read('context_ring', true),
      markdown: read('markdown', true),
      slashCommands: read('slash_commands', true),
      messageActions: read('message_actions', true),
      statusPills: read('status_pills', true),
      tokenBadges: read('token_badges', true),
    );
  }
}

/// Optional theme overrides. The accent colour already lives in
/// `app.color` — this struct exists for future palette overrides.
class AppTheme {
  /// Accent colour. Parsed from the `#RRGGBB` string in the YAML.
  final Color? accent;
  final Color? background;
  const AppTheme({this.accent, this.background});

  factory AppTheme.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const AppTheme();
    return AppTheme(
      accent: parseHex(json['accent'] as String?),
      background: parseHex(json['background'] as String?),
    );
  }

  static Color? parseHex(String? raw) {
    if (raw == null) return null;
    var hex = raw.trim();
    if (hex.startsWith('#')) hex = hex.substring(1);
    if (hex.length == 6) hex = 'FF$hex';
    if (hex.length != 8) return null;
    final parsed = int.tryParse(hex, radix: 16);
    return parsed == null ? null : Color(parsed);
  }
}

/// The fully-parsed app manifest. Immutable; replace the instance
/// when switching apps.
class AppManifest {
  // ── Identity ──
  final String appId;
  final String name;
  final String version;
  final String description;
  /// Emoji from the YAML (e.g. `"💬"`). Empty → fall back to icon.
  final String icon;
  final String color;
  final String category;
  final String author;
  final List<String> tags;

  // ── Chat UX ──
  final String greeting;
  final List<QuickPrompt> quickPrompts;
  final List<AppSlashCommand> slashCommands;

  // ── Execution ──
  /// How the app behaves at runtime (conversation / oneshot /
  /// background). The UI adapts substantially for each:
  ///   * conversation → standard chat experience
  ///   * oneshot      → single-shot form UX (send once, clear input)
  ///   * background   → no composer, status banner + triggers
  final ExecutionMode mode;
  /// Convenience helpers so call sites don't need to import the enum.
  bool get isConversation => mode == ExecutionMode.conversation;
  bool get isOneshot => mode == ExecutionMode.oneshot;
  bool get isBackground => mode == ExecutionMode.background;
  final int maxTurns;
  final int timeoutSeconds;
  final WorkspaceMode workspaceMode;

  // ── Feature flags driving UI visibility ──
  final AppFeatures features;

  // ── Capabilities (for the drawer / telemetry) ──
  final List<String> modules;
  final List<AppGrant> grants;
  final String defaultPolicy;

  // ── Styling ──
  final AppTheme theme;

  const AppManifest({
    required this.appId,
    this.name = '',
    this.version = '1.0',
    this.description = '',
    this.icon = '',
    this.color = '',
    this.category = '',
    this.author = '',
    this.tags = const [],
    this.greeting = '',
    this.quickPrompts = const [],
    this.slashCommands = const [],
    this.mode = ExecutionMode.conversation,
    this.maxTurns = 20,
    this.timeoutSeconds = 120,
    this.workspaceMode = WorkspaceMode.auto,
    this.features = const AppFeatures(),
    this.modules = const [],
    this.grants = const [],
    this.defaultPolicy = 'auto',
    this.theme = const AppTheme(),
  });

  /// Fallback manifest for when the daemon hasn't (yet) shipped one
  /// or parsing failed — the client still works with every feature
  /// enabled + an auto workspace.
  factory AppManifest.defaults(String appId) => AppManifest(appId: appId);

  /// Parse the YAML string form — what the daemon ships at the
  /// endpoint, identical to the `app.yaml` on disk. Returns a
  /// defaults manifest if the YAML is malformed so the UI never
  /// crashes on a broken app spec.
  factory AppManifest.fromYaml(String source, {String fallbackAppId = ''}) {
    try {
      final doc = yaml.loadYaml(source);
      if (doc is! Map) {
        return AppManifest.defaults(fallbackAppId);
      }
      return AppManifest.fromJson(_yamlToJson(doc) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('AppManifest.fromYaml failed: $e');
      return AppManifest.defaults(fallbackAppId);
    }
  }

  /// Recursively normalise a `YamlMap` / `YamlList` into plain Dart
  /// `Map<String, dynamic>` / `List<dynamic>` — the `yaml` package
  /// returns view objects that don't round-trip through our JSON
  /// parser directly.
  static dynamic _yamlToJson(dynamic node) {
    if (node is yaml.YamlMap) {
      return {
        for (final entry in node.entries)
          entry.key.toString(): _yamlToJson(entry.value),
      };
    }
    if (node is yaml.YamlList) {
      return [for (final e in node) _yamlToJson(e)];
    }
    if (node is Map) {
      return {
        for (final entry in node.entries)
          entry.key.toString(): _yamlToJson(entry.value),
      };
    }
    if (node is List) {
      return [for (final e in node) _yamlToJson(e)];
    }
    return node;
  }

  /// Convenience: the effective accent colour. Prefers `theme.accent`,
  /// then the top-level `app.color`, else null.
  Color? get accent => theme.accent ?? AppTheme.parseHex(color);

  // ── Parser ──────────────────────────────────────────────────────

  factory AppManifest.fromJson(Map<String, dynamic> raw) {
    // The manifest may arrive as the raw YAML-structure (with `app`,
    // `execution`, `capabilities`, `modules`, `agents` top-level
    // blocks) OR as a flat JSON that the daemon pre-flattened. We
    // accept both — check nested first, fall back to flat.
    final app = (raw['app'] as Map?)?.cast<String, dynamic>() ?? raw;
    final execution =
        (raw['execution'] as Map?)?.cast<String, dynamic>() ?? const {};
    final capabilities =
        (raw['capabilities'] as Map?)?.cast<String, dynamic>() ?? const {};
    final modulesBlock = raw['modules'];
    final featuresBlock =
        (raw['features'] as Map?)?.cast<String, dynamic>() ??
            (app['features'] as Map?)?.cast<String, dynamic>();
    final themeBlock =
        (raw['theme'] as Map?)?.cast<String, dynamic>() ??
            (app['theme'] as Map?)?.cast<String, dynamic>();

    List<String> modules;
    if (modulesBlock is Map) {
      modules = modulesBlock.keys.map((k) => k.toString()).toList();
    } else if (modulesBlock is List) {
      modules = modulesBlock.map((m) => m.toString()).toList();
    } else {
      modules = List<String>.from(raw['module_names'] ?? const []);
    }

    final qpList = (app['quick_prompts'] as List?) ??
        (raw['quick_prompts'] as List?) ??
        const [];
    final quickPrompts = <QuickPrompt>[];
    for (final q in qpList) {
      if (q is Map) {
        quickPrompts.add(QuickPrompt.fromJson(q.cast<String, dynamic>()));
      }
    }

    final scList = (raw['slash_commands'] as List?) ??
        (app['slash_commands'] as List?) ??
        const [];
    final slashCommands = <AppSlashCommand>[];
    for (final s in scList) {
      if (s is Map) {
        slashCommands
            .add(AppSlashCommand.fromJson(s.cast<String, dynamic>()));
      }
    }

    final grantList =
        (capabilities['grant'] as List?) ?? const [];
    final grants = <AppGrant>[];
    for (final g in grantList) {
      if (g is Map) grants.add(AppGrant.fromJson(g.cast<String, dynamic>()));
    }

    return AppManifest(
      appId: (app['app_id'] ?? raw['app_id'] ?? '') as String,
      name: (app['name'] ?? raw['name'] ?? '') as String,
      version: (app['version'] ?? raw['version'] ?? '1.0') as String,
      description: (app['description'] ?? raw['description'] ?? '') as String,
      icon: (app['icon'] ?? raw['icon'] ?? '') as String,
      color: (app['color'] ?? raw['color'] ?? '') as String,
      category: (app['category'] ?? raw['category'] ?? '') as String,
      author: (app['author'] ?? raw['author'] ?? '') as String,
      tags: List<String>.from(app['tags'] ?? raw['tags'] ?? const []),
      greeting:
          (execution['greeting'] ?? raw['greeting'] ?? '') as String,
      quickPrompts: quickPrompts,
      slashCommands: slashCommands,
      mode: _parseExecutionMode(
          (execution['mode'] ?? raw['mode']) as String?),
      maxTurns: (execution['max_turns'] as num?)?.toInt() ??
          (raw['max_turns'] as num?)?.toInt() ??
          20,
      timeoutSeconds: (execution['timeout'] as num?)?.toInt() ??
          (raw['timeout'] as num?)?.toInt() ??
          120,
      workspaceMode: _parseWorkspaceMode(
          (execution['workspace_mode'] ?? raw['workspace_mode']) as String?),
      features: AppFeatures.fromJson(featuresBlock),
      modules: modules,
      grants: grants,
      defaultPolicy:
          (capabilities['default_policy'] as String?) ?? 'auto',
      theme: AppTheme.fromJson(themeBlock),
    );
  }
}
