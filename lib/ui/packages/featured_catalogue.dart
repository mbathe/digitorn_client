/// Hardcoded showcase of community / official packages used by the
/// store's Discover tab when the daemon's hub source is still
/// stubbed. The instant the daemon ships the hub these entries are
/// silently replaced with whatever `GET /api/packages/available`
/// returns — same shape, no UI change.
///
/// Treat this file as a temporary fixture, not as long-term
/// product copy.
library;

import '../../models/app_package.dart';

class FeaturedCatalogue {
  static List<AppPackage> all() {
    return [
      _make(
        id: 'job-hunter',
        name: 'Job Hunter',
        version: '2.1.0',
        author: 'Digitorn community',
        description:
            'Scans LinkedIn, Indeed, and YC Jobs every morning, ranks new offers against your CV, and delivers a digest to your inbox.',
        category: 'productivity',
        icon: '💼',
        risk: 'medium',
        modules: ['web', 'memory', 'llm_provider', 'filesystem'],
        requiredCreds: ['anthropic', 'serpapi'],
        tags: ['cron', 'job-hunt', 'productivity'],
        downloads: 12340,
        rating: 4.7,
        featured: true,
      ),
      _make(
        id: 'sql-architect',
        name: 'SQL Architect',
        version: '1.4.2',
        author: 'datatools.dev',
        description:
            'Multi-agent SQL writer that explores your schema, drafts the query, runs it in a sandbox, and explains the result in plain English.',
        category: 'developer-tools',
        icon: '🗃️',
        risk: 'high',
        modules: ['llm_provider', 'memory', 'agent_spawn', 'database'],
        requiredCreds: ['anthropic', 'postgres'],
        tags: ['sql', 'database', 'multi-agent'],
        downloads: 8902,
        rating: 4.5,
      ),
      _make(
        id: 'meeting-scribe',
        name: 'Meeting Scribe',
        version: '0.9.0',
        author: 'lila@indie',
        description:
            'Joins your Google Meet via webhook, transcribes it live, and posts a structured summary + action items to Notion.',
        category: 'productivity',
        icon: '📝',
        risk: 'medium',
        modules: ['web', 'memory', 'llm_provider'],
        requiredCreds: ['anthropic', 'notion', 'google'],
        tags: ['meetings', 'transcription', 'notion'],
        downloads: 5430,
        rating: 4.8,
      ),
      _make(
        id: 'gh-triager',
        name: 'GitHub Triager',
        version: '3.0.1',
        author: 'oss-tools',
        description:
            'Classifies new issues, suggests labels, links similar tickets, and pings the right reviewer based on CODEOWNERS.',
        category: 'developer-tools',
        icon: '🔧',
        risk: 'medium',
        modules: ['web', 'memory', 'llm_provider'],
        requiredCreds: ['github', 'anthropic'],
        tags: ['github', 'issues', 'automation'],
        downloads: 14201,
        rating: 4.6,
      ),
      _make(
        id: 'invoice-bot',
        name: 'Invoice Reader',
        version: '1.2.0',
        author: 'finflow',
        description:
            'Watches your Gmail inbox for invoice attachments, extracts vendor / amount / due date, and pushes them to your accounting tool.',
        category: 'productivity',
        icon: '🧾',
        risk: 'medium',
        modules: ['filesystem', 'memory', 'llm_provider'],
        requiredCreds: ['gmail', 'anthropic'],
        tags: ['finance', 'gmail', 'invoice'],
        downloads: 3120,
        rating: 4.3,
      ),
      _make(
        id: 'chess-coach',
        name: 'Chess Coach',
        version: '0.5.0',
        author: 'gambit-labs',
        description:
            'Reviews your last 10 lichess games, identifies recurring mistakes, and drills you on the right tactics.',
        category: 'creative',
        icon: '♟️',
        risk: 'low',
        modules: ['web', 'memory', 'llm_provider'],
        requiredCreds: ['anthropic', 'lichess'],
        tags: ['chess', 'coaching', 'games'],
        downloads: 1820,
        rating: 4.9,
      ),
      _make(
        id: 'rss-digest',
        name: 'Smart RSS Digest',
        version: '2.0.0',
        author: 'reader-lab',
        description:
            'Aggregates 30+ RSS feeds, clusters them by topic, summarises the must-reads, and sends you a 5-minute morning brief.',
        category: 'research',
        icon: '📰',
        risk: 'low',
        modules: ['web', 'memory', 'llm_provider'],
        requiredCreds: ['anthropic'],
        tags: ['rss', 'news', 'digest'],
        downloads: 9870,
        rating: 4.4,
      ),
      _make(
        id: 'sales-prospector',
        name: 'Sales Prospector',
        version: '1.7.3',
        author: 'pipeline.io',
        description:
            'Enriches a list of leads with company size, recent funding, tech stack, and drafts a personalised outreach email per row.',
        category: 'productivity',
        icon: '📈',
        risk: 'medium',
        modules: ['web', 'memory', 'llm_provider'],
        requiredCreds: ['anthropic', 'apollo', 'linkedin'],
        tags: ['sales', 'crm', 'outreach'],
        downloads: 6750,
        rating: 4.2,
      ),
    ];
  }

  /// All distinct categories present in the catalogue, with a
  /// nice display label.
  static const categories = [
    ('all', 'All'),
    ('productivity', 'Productivity'),
    ('developer-tools', 'Developer Tools'),
    ('research', 'Research'),
    ('creative', 'Creative'),
    ('data', 'Data'),
    ('communication', 'Communication'),
  ];

  static AppPackage _make({
    required String id,
    required String name,
    required String version,
    required String author,
    required String description,
    required String category,
    required String icon,
    required String risk,
    required List<String> modules,
    required List<String> requiredCreds,
    required List<String> tags,
    int downloads = 0,
    double rating = 0.0,
    bool featured = false,
  }) {
    return AppPackage(
      packageId: id,
      name: name,
      version: version,
      description: description,
      author: author,
      icon: icon,
      category: category,
      sourceType: 'hub',
      sourceUri: 'hub://$author/$id@$version',
      manifest: PackageManifest(
        permissions: PackagePermissions(
          riskLevel: risk,
          networkAccess: true,
          filesystemAccess: const ['read', 'write'],
        ),
        requirements: PackageRequirements(modules: modules),
        requiredCredentials: requiredCreds,
        tags: tags,
        raw: {
          'package': {
            'hub': {
              'downloads': downloads,
              'rating': rating,
              'featured': featured,
            },
          },
        },
      ),
    );
  }

  /// Read the (downloads, rating, featured) tuple from the manifest
  /// raw map. Used by the discover view for sorting + display.
  static ({int downloads, double rating, bool featured}) statsFor(
      AppPackage pkg) {
    final raw = pkg.manifest.raw['package'] as Map? ?? const {};
    final hub = raw['hub'] as Map? ?? const {};
    return (
      downloads: (hub['downloads'] as num?)?.toInt() ?? 0,
      rating: (hub['rating'] as num?)?.toDouble() ?? 0.0,
      featured: hub['featured'] == true,
    );
  }
}
