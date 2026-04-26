/// Digitorn Hub — Dart models for the marketplace.
///
/// Mirror of the daemon's pydantic schemas (`packages/digitorn/core/api/hub.py`)
/// and the web models (`digitorn_web/src/models/hub.ts`). Hand-written
/// (not freezed) for zero codegen overhead — the project standard for
/// data-class dust like this. Equality is value-based via `==` on the
/// raw payload Map when needed; UI compares by id.
///
/// The client never talks to https://hub.digitorn.ai directly — every
/// call routes through the daemon's `/api/hub/*` proxy.
library;

// ─── Risk + sort + report reasons ────────────────────────────────────────────

enum HubRiskLevel { low, medium, high }

HubRiskLevel hubRiskFromString(String? raw) {
  switch ((raw ?? '').toLowerCase()) {
    case 'high':
      return HubRiskLevel.high;
    case 'medium':
      return HubRiskLevel.medium;
    default:
      return HubRiskLevel.low;
  }
}

String hubRiskToString(HubRiskLevel r) =>
    r.toString().split('.').last; // "low" / "medium" / "high"

enum HubReviewSort { recent, ratingDesc, ratingAsc }

String hubReviewSortToQuery(HubReviewSort s) {
  switch (s) {
    case HubReviewSort.ratingDesc:
      return 'rating_desc';
    case HubReviewSort.ratingAsc:
      return 'rating_asc';
    case HubReviewSort.recent:
      return 'recent';
  }
}

enum HubReportReason { malware, spam, abuse, copyright, broken, other }

String hubReportReasonToString(HubReportReason r) =>
    r.toString().split('.').last;

HubReportReason hubReportReasonFromString(String? raw) {
  switch ((raw ?? '').toLowerCase()) {
    case 'malware':
      return HubReportReason.malware;
    case 'spam':
      return HubReportReason.spam;
    case 'abuse':
      return HubReportReason.abuse;
    case 'copyright':
      return HubReportReason.copyright;
    case 'broken':
      return HubReportReason.broken;
    default:
      return HubReportReason.other;
  }
}

// ─── Session ────────────────────────────────────────────────────────────────

class HubUser {
  final String id;
  final String email;
  const HubUser({required this.id, required this.email});

  factory HubUser.fromJson(Map<String, dynamic> j) => HubUser(
        id: (j['id'] as String?) ?? '',
        email: (j['email'] as String?) ?? '',
      );
}

class HubSession {
  final bool loggedIn;
  final String hubUrl;
  final HubUser? hubUser;

  /// ISO timestamp of when the cached hub session token expires.
  final String? expiresAt;

  /// True when the daemon is configured to auto-provision Hub sessions
  /// on the user's behalf (no email/password form needed). The UI
  /// should hide the sign-in form and treat `loggedIn: false` as a
  /// transient state instead of a hard "please log in" prompt.
  final bool bridgeEnabled;

  const HubSession({
    required this.loggedIn,
    required this.hubUrl,
    this.hubUser,
    this.expiresAt,
    this.bridgeEnabled = false,
  });

  factory HubSession.fromJson(Map<String, dynamic> j) {
    final user = j['hub_user'];
    return HubSession(
      loggedIn: (j['logged_in'] as bool?) ?? false,
      hubUrl: (j['hub_url'] as String?) ?? '',
      hubUser: user is Map
          ? HubUser.fromJson(user.cast<String, dynamic>())
          : null,
      expiresAt: j['expires_at'] as String?,
      bridgeEnabled: (j['bridge_enabled'] as bool?) ?? false,
    );
  }
}

// ─── Search hits + package detail ───────────────────────────────────────────

class HubSearchHit {
  final String id;
  final String publisherSlug;
  final bool publisherVerified;
  final String packageId;
  final String name;
  final String description;
  final String category;
  final String? iconUrl;
  final String latestVersion;
  final HubRiskLevel riskLevel;
  final int totalDownloads;

  /// 1-5 with 2 decimals — null if no reviews yet.
  final double? avgRating;
  final int reviewCount;
  final List<String> tags;
  final String updatedAt;
  final double score;

  const HubSearchHit({
    required this.id,
    required this.publisherSlug,
    required this.publisherVerified,
    required this.packageId,
    required this.name,
    required this.description,
    required this.category,
    required this.iconUrl,
    required this.latestVersion,
    required this.riskLevel,
    required this.totalDownloads,
    required this.avgRating,
    required this.reviewCount,
    required this.tags,
    required this.updatedAt,
    required this.score,
  });

  factory HubSearchHit.fromJson(Map<String, dynamic> j) => HubSearchHit(
        id: (j['id'] as String?) ?? '',
        publisherSlug: (j['publisher_slug'] as String?) ?? '',
        publisherVerified: (j['publisher_verified'] as bool?) ?? false,
        packageId: (j['package_id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        description: (j['description'] as String?) ?? '',
        category: (j['category'] as String?) ?? '',
        iconUrl: j['icon_url'] as String?,
        latestVersion: (j['latest_version'] as String?) ?? '',
        riskLevel: hubRiskFromString(j['risk_level'] as String?),
        totalDownloads: (j['total_downloads'] as num?)?.toInt() ?? 0,
        avgRating: (j['avg_rating'] as num?)?.toDouble(),
        reviewCount: (j['review_count'] as num?)?.toInt() ?? 0,
        tags: ((j['tags'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        updatedAt: (j['updated_at'] as String?) ?? '',
        score: (j['score'] as num?)?.toDouble() ?? 0,
      );
}

class HubSearchResponse {
  final String query;
  final int total;
  final int page;
  final int pageSize;
  final List<HubSearchHit> hits;

  const HubSearchResponse({
    required this.query,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.hits,
  });

  factory HubSearchResponse.fromJson(Map<String, dynamic> j) =>
      HubSearchResponse(
        query: (j['query'] as String?) ?? '',
        total: (j['total'] as num?)?.toInt() ?? 0,
        page: (j['page'] as num?)?.toInt() ?? 1,
        pageSize: (j['page_size'] as num?)?.toInt() ?? 20,
        hits: ((j['hits'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => HubSearchHit.fromJson(m.cast<String, dynamic>()))
            .toList(growable: false),
      );
}

class HubPackageVersion {
  final String id;
  final String version;
  final int archiveSize;
  final String archiveSha256;
  final bool yanked;
  final String? yankedReason;
  final int downloads;
  final String releasedAt;

  const HubPackageVersion({
    required this.id,
    required this.version,
    required this.archiveSize,
    required this.archiveSha256,
    required this.yanked,
    required this.yankedReason,
    required this.downloads,
    required this.releasedAt,
  });

  factory HubPackageVersion.fromJson(Map<String, dynamic> j) =>
      HubPackageVersion(
        id: (j['id'] as String?) ?? '',
        version: (j['version'] as String?) ?? '',
        archiveSize: (j['archive_size'] as num?)?.toInt() ?? 0,
        archiveSha256: (j['archive_sha256'] as String?) ?? '',
        yanked: (j['yanked'] as bool?) ?? false,
        yankedReason: j['yanked_reason'] as String?,
        downloads: (j['downloads'] as num?)?.toInt() ?? 0,
        releasedAt: (j['released_at'] as String?) ?? '',
      );
}

class HubPackageDetail extends HubSearchHit {
  final List<HubPackageVersion> versions;

  /// Raw package.toml as JSON. Shape is package-specific.
  final Map<String, dynamic> manifest;

  const HubPackageDetail({
    required super.id,
    required super.publisherSlug,
    required super.publisherVerified,
    required super.packageId,
    required super.name,
    required super.description,
    required super.category,
    required super.iconUrl,
    required super.latestVersion,
    required super.riskLevel,
    required super.totalDownloads,
    required super.avgRating,
    required super.reviewCount,
    required super.tags,
    required super.updatedAt,
    required super.score,
    required this.versions,
    required this.manifest,
  });

  factory HubPackageDetail.fromJson(Map<String, dynamic> j) {
    final base = HubSearchHit.fromJson(j);
    return HubPackageDetail(
      id: base.id,
      publisherSlug: base.publisherSlug,
      publisherVerified: base.publisherVerified,
      packageId: base.packageId,
      name: base.name,
      description: base.description,
      category: base.category,
      iconUrl: base.iconUrl,
      latestVersion: base.latestVersion,
      riskLevel: base.riskLevel,
      totalDownloads: base.totalDownloads,
      avgRating: base.avgRating,
      reviewCount: base.reviewCount,
      tags: base.tags,
      updatedAt: base.updatedAt,
      score: base.score,
      versions: ((j['versions'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => HubPackageVersion.fromJson(m.cast<String, dynamic>()))
          .toList(growable: false),
      manifest: (j['manifest'] is Map)
          ? (j['manifest'] as Map).cast<String, dynamic>()
          : <String, dynamic>{},
    );
  }
}

// ─── Reviews ────────────────────────────────────────────────────────────────

class HubReviewItem {
  final String id;
  final String packageId;
  final String userId;
  final String userDisplayName;
  final int rating; // 1-5
  final String? body;
  final bool hidden;
  final String createdAt;
  final String updatedAt;

  const HubReviewItem({
    required this.id,
    required this.packageId,
    required this.userId,
    required this.userDisplayName,
    required this.rating,
    required this.body,
    required this.hidden,
    required this.createdAt,
    required this.updatedAt,
  });

  factory HubReviewItem.fromJson(Map<String, dynamic> j) => HubReviewItem(
        id: (j['id'] as String?) ?? '',
        packageId: (j['package_id'] as String?) ?? '',
        userId: (j['user_id'] as String?) ?? '',
        userDisplayName: (j['user_display_name'] as String?) ?? '',
        rating: (j['rating'] as num?)?.toInt() ?? 0,
        body: j['body'] as String?,
        hidden: (j['hidden'] as bool?) ?? false,
        createdAt: (j['created_at'] as String?) ?? '',
        updatedAt: (j['updated_at'] as String?) ?? '',
      );
}

class HubReviewListResponse {
  final int total;
  final int page;
  final int pageSize;
  final double? avgRating;
  final int reviewCount;

  /// Map of "1".."5" → count. Use [distributionFor] for typed access.
  final Map<String, int> distribution;
  final List<HubReviewItem> items;

  const HubReviewListResponse({
    required this.total,
    required this.page,
    required this.pageSize,
    required this.avgRating,
    required this.reviewCount,
    required this.distribution,
    required this.items,
  });

  int distributionFor(int star) => distribution['$star'] ?? 0;

  factory HubReviewListResponse.fromJson(Map<String, dynamic> j) {
    final dist = <String, int>{};
    final raw = j['distribution'];
    if (raw is Map) {
      raw.forEach((k, v) {
        dist[k.toString()] = (v as num?)?.toInt() ?? 0;
      });
    }
    return HubReviewListResponse(
      total: (j['total'] as num?)?.toInt() ?? 0,
      page: (j['page'] as num?)?.toInt() ?? 1,
      pageSize: (j['page_size'] as num?)?.toInt() ?? 20,
      avgRating: (j['avg_rating'] as num?)?.toDouble(),
      reviewCount: (j['review_count'] as num?)?.toInt() ?? 0,
      distribution: dist,
      items: ((j['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => HubReviewItem.fromJson(m.cast<String, dynamic>()))
          .toList(growable: false),
    );
  }
}

// ─── Reports ────────────────────────────────────────────────────────────────

class HubReportOut {
  final String id;
  final HubReportReason reason;
  final String status;
  final String createdAt;

  const HubReportOut({
    required this.id,
    required this.reason,
    required this.status,
    required this.createdAt,
  });

  factory HubReportOut.fromJson(Map<String, dynamic> j) => HubReportOut(
        id: (j['id'] as String?) ?? '',
        reason: hubReportReasonFromString(j['reason'] as String?),
        status: (j['status'] as String?) ?? 'open',
        createdAt: (j['created_at'] as String?) ?? '',
      );
}

// ─── Stats ──────────────────────────────────────────────────────────────────

class HubStatsPoint {
  final String date; // "YYYY-MM-DD"
  final int downloads;
  const HubStatsPoint({required this.date, required this.downloads});

  factory HubStatsPoint.fromJson(Map<String, dynamic> j) => HubStatsPoint(
        date: (j['date'] as String?) ?? '',
        downloads: (j['downloads'] as num?)?.toInt() ?? 0,
      );
}

class HubPackageStats {
  final String publisherSlug;
  final String packageId;
  final int rangeDays;
  final int totalDownloadsInRange;
  final double avgPerDay;
  final List<HubStatsPoint> series;
  final Map<String, int> byVersion;

  const HubPackageStats({
    required this.publisherSlug,
    required this.packageId,
    required this.rangeDays,
    required this.totalDownloadsInRange,
    required this.avgPerDay,
    required this.series,
    required this.byVersion,
  });

  factory HubPackageStats.fromJson(Map<String, dynamic> j) {
    final versions = <String, int>{};
    final raw = j['by_version'];
    if (raw is Map) {
      raw.forEach((k, v) {
        versions[k.toString()] = (v as num?)?.toInt() ?? 0;
      });
    }
    return HubPackageStats(
      publisherSlug: (j['publisher_slug'] as String?) ?? '',
      packageId: (j['package_id'] as String?) ?? '',
      rangeDays: (j['range_days'] as num?)?.toInt() ?? 30,
      totalDownloadsInRange:
          (j['total_downloads_in_range'] as num?)?.toInt() ?? 0,
      avgPerDay: (j['avg_per_day'] as num?)?.toDouble() ?? 0,
      series: ((j['series'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => HubStatsPoint.fromJson(m.cast<String, dynamic>()))
          .toList(growable: false),
      byVersion: versions,
    );
  }
}

// ─── Install ────────────────────────────────────────────────────────────────

enum HubInstallScope { user, system }

String hubInstallScopeToString(HubInstallScope s) =>
    s == HubInstallScope.system ? 'system' : 'user';

class HubInstallSuccess {
  final String packageId;
  final String version;
  final HubInstallScope scope;
  final bool deployed;

  const HubInstallSuccess({
    required this.packageId,
    required this.version,
    required this.scope,
    required this.deployed,
  });

  factory HubInstallSuccess.fromJson(Map<String, dynamic> j) =>
      HubInstallSuccess(
        packageId: (j['package_id'] as String?) ?? '',
        version: (j['version'] as String?) ?? '',
        scope: (j['scope'] as String?) == 'system'
            ? HubInstallScope.system
            : HubInstallScope.user,
        deployed: (j['deployed'] as bool?) ?? false,
      );
}

class HubPermissionsBreakdown {
  final HubRiskLevel riskLevel;
  final bool networkAccess;
  final List<String> filesystemAccess;
  final List<String> filesystemScopes;
  final List<String> requiresApproval;

  const HubPermissionsBreakdown({
    required this.riskLevel,
    required this.networkAccess,
    required this.filesystemAccess,
    required this.filesystemScopes,
    required this.requiresApproval,
  });

  factory HubPermissionsBreakdown.fromJson(Map<String, dynamic> j) =>
      HubPermissionsBreakdown(
        riskLevel: hubRiskFromString(j['risk_level'] as String?),
        networkAccess: (j['network_access'] as bool?) ?? false,
        filesystemAccess: ((j['filesystem_access'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        filesystemScopes: ((j['filesystem_scopes'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        requiresApproval: ((j['requires_approval'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
      );
}

/// Result of [HubService.install] — the 409 "permissions required" path
/// is modelled as a sealed-style union so callers branch cleanly.
sealed class HubInstallResult {
  const HubInstallResult();
}

class HubInstallOk extends HubInstallResult {
  final HubInstallSuccess data;
  const HubInstallOk(this.data);
}

class HubInstallNeedsConsent extends HubInstallResult {
  final HubPermissionsBreakdown permissions;
  const HubInstallNeedsConsent(this.permissions);
}
