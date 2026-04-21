/// Hardcoded fallback catalogue of well-known MCP servers — drawn
/// from Anthropic's `modelcontextprotocol/servers` reference repo
/// plus the most popular community ones. Used by the Discover tab
/// when the daemon's `/api/mcp/catalogue` endpoint is stubbed.
///
/// When the daemon ships a real catalogue, the store hides this
/// list automatically (the service simply returns the daemon's
/// response and `McpStorePage` never reaches this fallback).
library;

import '../../models/mcp_server.dart';

class McpCatalogue {
  static List<McpCatalogueEntry> all() => const [
        // ── Reference servers (Anthropic) ───────────────────────────
        McpCatalogueEntry(
          name: 'filesystem',
          label: 'Filesystem',
          icon: '📁',
          category: 'developer-tools',
          description:
              'Read, write, and search files in a sandboxed directory tree. The most-used MCP — every coding agent ships it.',
          author: 'modelcontextprotocol',
          defaultCommand: 'npx',
          defaultArgs: [
            '-y',
            '@modelcontextprotocol/server-filesystem',
            '/path/to/allowed/dir',
          ],
          repoUrl:
              'https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem',
          tags: ['files', 'read', 'write', 'official'],
          featured: true,
          popularity: 21000,
        ),
        McpCatalogueEntry(
          name: 'fetch',
          label: 'Fetch',
          icon: '🌐',
          category: 'developer-tools',
          description:
              'Generic HTTP fetcher with markdown conversion. Lets agents grab any web page and reason over its content.',
          author: 'modelcontextprotocol',
          defaultCommand: 'uvx',
          defaultArgs: ['mcp-server-fetch'],
          repoUrl:
              'https://github.com/modelcontextprotocol/servers/tree/main/src/fetch',
          tags: ['web', 'http', 'official'],
          popularity: 18450,
        ),
        McpCatalogueEntry(
          name: 'github',
          label: 'GitHub',
          icon: '🐙',
          category: 'developer-tools',
          description:
              'Official GitHub MCP — search code, read PRs, browse issues, comment, and manage releases via your personal token.',
          author: 'modelcontextprotocol',
          defaultCommand: 'npx',
          defaultArgs: ['-y', '@modelcontextprotocol/server-github'],
          requiredEnv: [
            McpEnvVar(
              name: 'GITHUB_PERSONAL_ACCESS_TOKEN',
              label: 'GitHub PAT',
              isSecret: true,
              description: 'From github.com/settings/tokens',
            ),
          ],
          repoUrl:
              'https://github.com/modelcontextprotocol/servers/tree/main/src/github',
          tags: ['github', 'git', 'official'],
          featured: true,
          popularity: 19800,
        ),
        McpCatalogueEntry(
          name: 'gitlab',
          label: 'GitLab',
          icon: '🦊',
          category: 'developer-tools',
          description:
              'Same as the GitHub server, but for GitLab projects, MRs, and pipelines.',
          author: 'modelcontextprotocol',
          defaultCommand: 'npx',
          defaultArgs: ['-y', '@modelcontextprotocol/server-gitlab'],
          requiredEnv: [
            McpEnvVar(
              name: 'GITLAB_PERSONAL_ACCESS_TOKEN',
              label: 'GitLab PAT',
              isSecret: true,
            ),
            McpEnvVar(
              name: 'GITLAB_API_URL',
              label: 'GitLab URL',
              description: 'Default: https://gitlab.com/api/v4',
            ),
          ],
          tags: ['gitlab', 'git', 'official'],
          popularity: 4200,
        ),
        McpCatalogueEntry(
          name: 'sqlite',
          label: 'SQLite',
          icon: '🗄️',
          category: 'data',
          description:
              'Run SQL queries against a local SQLite database. Read-only by default; agents can ask the schema first.',
          author: 'modelcontextprotocol',
          defaultCommand: 'uvx',
          defaultArgs: [
            'mcp-server-sqlite',
            '--db-path',
            '/path/to/db.sqlite',
          ],
          tags: ['sql', 'database', 'official'],
          popularity: 6700,
        ),
        McpCatalogueEntry(
          name: 'postgres',
          label: 'PostgreSQL',
          icon: '🐘',
          category: 'data',
          description:
              'Inspect schemas and run read-only queries against a Postgres instance. Hands the agent a real DB without the risk.',
          author: 'modelcontextprotocol',
          defaultCommand: 'npx',
          defaultArgs: [
            '-y',
            '@modelcontextprotocol/server-postgres',
            'postgres://user:pass@host/db',
          ],
          tags: ['sql', 'database', 'postgres', 'official'],
          popularity: 8200,
        ),
        McpCatalogueEntry(
          name: 'gdrive',
          label: 'Google Drive',
          icon: '📄',
          category: 'productivity',
          description:
              'Search and read Google Drive files. OAuth-authenticated; no scope creep — your account stays in your hands.',
          author: 'modelcontextprotocol',
          defaultCommand: 'npx',
          defaultArgs: ['-y', '@modelcontextprotocol/server-gdrive'],
          requiredEnv: [
            McpEnvVar(
              name: 'GDRIVE_CREDENTIALS_PATH',
              label: 'OAuth credentials JSON path',
            ),
          ],
          tags: ['google', 'docs', 'official'],
          popularity: 5400,
        ),
        McpCatalogueEntry(
          name: 'slack',
          label: 'Slack',
          icon: '💬',
          category: 'communication',
          description:
              'Post messages, fetch channel history, and react in Slack from any agent.',
          author: 'modelcontextprotocol',
          defaultCommand: 'npx',
          defaultArgs: ['-y', '@modelcontextprotocol/server-slack'],
          requiredEnv: [
            McpEnvVar(
              name: 'SLACK_BOT_TOKEN',
              label: 'Slack bot token',
              isSecret: true,
            ),
            McpEnvVar(
              name: 'SLACK_TEAM_ID',
              label: 'Workspace ID',
            ),
          ],
          tags: ['slack', 'chat', 'official'],
          popularity: 7100,
        ),
        McpCatalogueEntry(
          name: 'brave-search',
          label: 'Brave Search',
          icon: '🔍',
          category: 'research',
          description:
              'Privacy-respecting web search via the Brave API. Returns titles + snippets with no tracker payload.',
          author: 'modelcontextprotocol',
          defaultCommand: 'npx',
          defaultArgs: ['-y', '@modelcontextprotocol/server-brave-search'],
          requiredEnv: [
            McpEnvVar(
              name: 'BRAVE_API_KEY',
              label: 'Brave API key',
              isSecret: true,
            ),
          ],
          tags: ['search', 'web', 'official'],
          popularity: 9300,
        ),
        McpCatalogueEntry(
          name: 'puppeteer',
          label: 'Puppeteer',
          icon: '🤖',
          category: 'developer-tools',
          description:
              'Headless Chromium driver for browser automation, screenshots, and full DOM scraping.',
          author: 'modelcontextprotocol',
          defaultCommand: 'npx',
          defaultArgs: ['-y', '@modelcontextprotocol/server-puppeteer'],
          tags: ['browser', 'automation', 'official'],
          popularity: 8900,
        ),
        McpCatalogueEntry(
          name: 'memory',
          label: 'Knowledge Memory',
          icon: '🧠',
          category: 'productivity',
          description:
              'Persistent knowledge graph stored on disk. Lets agents remember facts across sessions.',
          author: 'modelcontextprotocol',
          defaultCommand: 'npx',
          defaultArgs: ['-y', '@modelcontextprotocol/server-memory'],
          tags: ['memory', 'graph', 'official'],
          featured: true,
          popularity: 14500,
        ),
        McpCatalogueEntry(
          name: 'sequential-thinking',
          label: 'Sequential Thinking',
          icon: '🪜',
          category: 'productivity',
          description:
              'Structured chain-of-thought tool that lets the agent plan multi-step reasoning out loud.',
          author: 'modelcontextprotocol',
          defaultCommand: 'npx',
          defaultArgs: [
            '-y',
            '@modelcontextprotocol/server-sequential-thinking',
          ],
          tags: ['reasoning', 'official'],
          popularity: 6200,
        ),
        McpCatalogueEntry(
          name: 'time',
          label: 'Time',
          icon: '⏰',
          category: 'developer-tools',
          description:
              'Tiny clock + timezone server. Useful when the agent needs to schedule something across regions.',
          author: 'modelcontextprotocol',
          defaultCommand: 'uvx',
          defaultArgs: ['mcp-server-time'],
          tags: ['time', 'clock', 'official'],
          popularity: 2800,
        ),
        McpCatalogueEntry(
          name: 'google-maps',
          label: 'Google Maps',
          icon: '🗺️',
          category: 'productivity',
          description:
              'Geocoding, place search, and route planning via the Google Maps Platform APIs.',
          author: 'modelcontextprotocol',
          defaultCommand: 'npx',
          defaultArgs: ['-y', '@modelcontextprotocol/server-google-maps'],
          requiredEnv: [
            McpEnvVar(
              name: 'GOOGLE_MAPS_API_KEY',
              label: 'Google Maps API key',
              isSecret: true,
            ),
          ],
          tags: ['maps', 'geo', 'official'],
          popularity: 3400,
        ),

        // ── Community ───────────────────────────────────────────────
        McpCatalogueEntry(
          name: 'notion',
          label: 'Notion',
          icon: '📝',
          category: 'productivity',
          description:
              'Read pages, create blocks, search your workspace, and update databases via the official Notion API.',
          author: 'community',
          defaultCommand: 'npx',
          defaultArgs: ['-y', 'mcp-notion-server'],
          requiredEnv: [
            McpEnvVar(
              name: 'NOTION_API_KEY',
              label: 'Notion integration token',
              isSecret: true,
              description: 'From notion.so/my-integrations',
            ),
          ],
          tags: ['notion', 'productivity', 'community'],
          featured: true,
          popularity: 11200,
        ),
        McpCatalogueEntry(
          name: 'linear',
          label: 'Linear',
          icon: '📐',
          category: 'productivity',
          description:
              'Manage Linear issues, projects, and cycles from any agent that can speak MCP.',
          author: 'community',
          defaultCommand: 'npx',
          defaultArgs: ['-y', 'mcp-linear'],
          requiredEnv: [
            McpEnvVar(
              name: 'LINEAR_API_KEY',
              label: 'Linear API key',
              isSecret: true,
            ),
          ],
          tags: ['linear', 'tickets', 'community'],
          popularity: 4900,
        ),
        McpCatalogueEntry(
          name: 'youtube-transcript',
          label: 'YouTube Transcript',
          icon: '🎬',
          category: 'research',
          description:
              'Pulls the transcript of any YouTube video so the agent can summarise / search inside it.',
          author: 'community',
          defaultCommand: 'npx',
          defaultArgs: ['-y', '@kimtaeyoon83/mcp-server-youtube-transcript'],
          tags: ['youtube', 'video', 'community'],
          popularity: 5600,
        ),
        McpCatalogueEntry(
          name: 'aws-kb-retrieval',
          label: 'AWS Knowledge Base',
          icon: '☁️',
          category: 'data',
          description:
              'Query AWS Bedrock Knowledge Bases — RAG-as-a-service backed by your own indexed documents.',
          author: 'modelcontextprotocol',
          defaultCommand: 'npx',
          defaultArgs: [
            '-y',
            '@modelcontextprotocol/server-aws-kb-retrieval',
          ],
          requiredEnv: [
            McpEnvVar(name: 'AWS_ACCESS_KEY_ID', isSecret: true),
            McpEnvVar(name: 'AWS_SECRET_ACCESS_KEY', isSecret: true),
            McpEnvVar(name: 'AWS_REGION'),
          ],
          tags: ['aws', 'rag', 'official'],
          popularity: 3100,
        ),
        McpCatalogueEntry(
          name: 'everart',
          label: 'EverArt',
          icon: '🎨',
          category: 'creative',
          description:
              'Generate images via the EverArt API. Lets your agents draft thumbnails, mockups, or covers on the fly.',
          author: 'modelcontextprotocol',
          defaultCommand: 'npx',
          defaultArgs: ['-y', '@modelcontextprotocol/server-everart'],
          requiredEnv: [
            McpEnvVar(name: 'EVERART_API_KEY', isSecret: true),
          ],
          tags: ['image', 'creative', 'official'],
          popularity: 2400,
        ),
      ];

  static const categories = [
    ('all', 'All'),
    ('developer-tools', 'Developer Tools'),
    ('productivity', 'Productivity'),
    ('research', 'Research'),
    ('data', 'Data'),
    ('communication', 'Communication'),
    ('creative', 'Creative'),
  ];
}
