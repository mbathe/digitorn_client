/// Typed mirror of the daemon's MCP server registry. Each entry
/// represents one Model Context Protocol server the user can
/// install, configure, start, and stop. The shapes follow the
/// `mcpServers` JSON conventions from Anthropic's reference
/// `modelcontextprotocol` repos so we can swap to the daemon's
/// real endpoints without renaming fields.
library;

import 'package:flutter/material.dart';

/// One MCP server installed on the daemon.
class McpServer {
  final String id;
  final String name;
  final String description;
  final String author;

  /// `stdio` | `http` | `ws`
  final String transport;

  /// stdio command (e.g. `npx`)
  final String? command;

  /// stdio args (e.g. `["-y", "@modelcontextprotocol/server-filesystem", "/path"]`)
  final List<String> args;

  /// Environment variables required to start the process. Stored
  /// as a flat map; secret values come back masked from the daemon.
  final Map<String, String> env;

  /// `installed` | `starting` | `running` | `stopped` | `error`
  final String status;

  /// Number of tools the server exposes once started. 0 when
  /// stopped or unknown.
  final int toolsCount;

  /// Last error message when `status == 'error'`.
  final String? lastError;

  /// Where the server came from — `catalogue` | `local` | `manual`.
  final String source;

  final String? icon;
  final List<String> tags;

  const McpServer({
    required this.id,
    required this.name,
    this.description = '',
    this.author = '',
    this.transport = 'stdio',
    this.command,
    this.args = const [],
    this.env = const {},
    this.status = 'stopped',
    this.toolsCount = 0,
    this.lastError,
    this.source = 'manual',
    this.icon,
    this.tags = const [],
  });

  factory McpServer.fromJson(Map<String, dynamic> j) => McpServer(
        id: j['id'] as String? ?? j['name'] as String? ?? '',
        name: j['name'] as String? ?? '',
        description: j['description'] as String? ?? '',
        author: j['author'] as String? ?? '',
        transport: j['transport'] as String? ?? 'stdio',
        command: j['command'] as String?,
        args: (j['args'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        env: (j['env'] as Map? ?? const {})
            .map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')),
        status: j['status'] as String? ?? 'stopped',
        toolsCount: (j['tools_count'] as num?)?.toInt() ?? 0,
        lastError: j['last_error'] as String?,
        source: j['source'] as String? ?? 'manual',
        icon: j['icon'] as String?,
        tags: (j['tags'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
      );

  bool get isRunning => status == 'running';
  bool get isError => status == 'error';
}

/// One entry in the discoverable MCP catalog. Matches the daemon's
/// `GET /api/mcp/catalog` (singular — the `/catalogue` path is
/// deprecated) and carries the richer metadata the store page
/// needs: OAuth provider, env-mapping, per-key descriptions,
/// install counts, verified badge, categories.
class McpCatalogueEntry {
  /// Unique slug — `filesystem`, `github`, `notion`, etc.
  final String name;
  final String label;
  final String description;
  final String author;

  /// `stdio` | `http` | `ws`
  final String transport;

  /// Default command + args used when the user clicks Install.
  final String defaultCommand;
  final List<String> defaultArgs;

  /// Env vars the user must fill before the server can start.
  /// Each entry is `(envName, label, isSecret, description)`.
  final List<McpEnvVar> requiredEnv;

  /// Optional env vars (not blocking install).
  final List<McpEnvVar> optionalEnv;

  /// Source repository / docs.
  final String? repoUrl;

  /// Tags for filtering / search.
  final List<String> tags;

  /// Display icon — emoji recommended.
  final String icon;

  /// Soft category for the chips bar — `productivity`, `developer-tools`, etc.
  final String category;

  /// Featured in the hero banner.
  final bool featured;

  /// Approximate downloads / popularity (used for sorting).
  final int popularity;

  /// Non-null when the server authenticates via OAuth. The value is
  /// the provider slug the daemon knows about (`google`, `github`,
  /// `slack`, etc.); install flow becomes "click Connect → pop
  /// browser → daemon handles callback".
  final String? oauthProvider;

  /// Optional mapping from catalog env var names → the canonical
  /// credential slot names the daemon stores. E.g.
  /// `{ 'GITHUB_TOKEN': 'github_personal_access_token' }`. When set,
  /// the install form can pre-fill from the user's credential store.
  final Map<String, String> envMapping;

  /// Verified badge — the daemon has vetted this entry (signed by
  /// the hub, known author). Drives the checkmark in the card.
  final bool verified;

  /// Total installs across the workspace — used to rank in the
  /// "Popular" sort order.
  final int installCount;

  /// Long-form README / setup guide. Fetched lazily via the
  /// catalog-detail endpoint before the install form opens so the
  /// user sees real instructions, not a generic placeholder.
  final String? longDescription;

  const McpCatalogueEntry({
    required this.name,
    required this.label,
    required this.description,
    required this.author,
    this.transport = 'stdio',
    required this.defaultCommand,
    this.defaultArgs = const [],
    this.requiredEnv = const [],
    this.optionalEnv = const [],
    this.repoUrl,
    this.tags = const [],
    this.icon = '🔌',
    this.category = 'developer-tools',
    this.featured = false,
    this.popularity = 0,
    this.oauthProvider,
    this.envMapping = const {},
    this.verified = false,
    this.installCount = 0,
    this.longDescription,
  });

  bool get usesOAuth => oauthProvider != null && oauthProvider!.isNotEmpty;

  IconData get fallbackIcon {
    switch (name.toLowerCase()) {
      case 'github':
      case 'gitlab':
        return Icons.hub_outlined;
      case 'filesystem':
      case 'gdrive':
        return Icons.folder_outlined;
      case 'fetch':
      case 'puppeteer':
        return Icons.public_rounded;
      case 'sqlite':
      case 'postgres':
        return Icons.storage_rounded;
      case 'slack':
        return Icons.tag_rounded;
      case 'notion':
        return Icons.description_outlined;
      case 'memory':
        return Icons.psychology_outlined;
      case 'time':
        return Icons.schedule_rounded;
      case 'brave-search':
      case 'youtube-transcript':
        return Icons.search_rounded;
      case 'google-maps':
        return Icons.map_outlined;
      default:
        return Icons.electrical_services_rounded;
    }
  }
}

class McpEnvVar {
  final String name;
  final String label;
  final bool isSecret;
  final String description;
  final String? placeholder;

  const McpEnvVar({
    required this.name,
    String? label,
    this.isSecret = false,
    this.description = '',
    this.placeholder,
  }) : label = label ?? name;
}
