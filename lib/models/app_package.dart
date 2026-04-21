/// Typed mirror of the daemon's app-package model. Mirrors the
/// `package.toml` schema documented in `APP_PACKAGES.md` but also
/// captures the runtime fields the daemon exposes via
/// `GET /api/packages` (source, hash, install path, status,
/// update_available, deployed_app_id).
///
/// Every field is optional so partial responses (the manifest-only
/// shape returned by `generate-package-manifest`) parse cleanly.
library;

import 'package:flutter/material.dart';

class AppPackage {
  final String packageId;
  final String name;
  final String version;
  final String description;
  final String author;
  final String? license;
  final String? homepage;
  final String? icon;
  final String? category;

  /// `builtin` | `local` | `hub` | `git`
  final String sourceType;
  final String? sourceUri;

  /// `installed` | `installing` | `broken` | `uninstalling`
  final String status;

  final String? hash;
  final String? installDir;
  final DateTime? installedAt;
  final DateTime? updatedAt;

  /// Set to a version string when an update is available; null
  /// otherwise. Populated by the daemon's `check-updates` pass.
  final String? updateAvailable;

  /// The deployed `app_id` once the package is installed. May be
  /// the same as `packageId` for clean cases, or a fresh id for
  /// renamed installs.
  final String? deployedAppId;

  /// Runtime state of the deployed app (post-unification). One of
  /// `running | disabled | broken | not_deployed`. Distinct from
  /// [status], which describes the install on disk.
  final String runtimeStatus;

  /// Deploy error message when [runtimeStatus] == `"broken"`. Null
  /// for healthy / not-yet-deployed installs.
  final String? deployError;

  /// `user` | `system` — who owns this install. `system` packages
  /// are visible to every user on the daemon and can only be
  /// installed/uninstalled by admins; `user` packages are scoped
  /// to one user. When null the daemon hasn't sent the field yet
  /// (legacy response); treat as `user`.
  final String? scope;

  /// The user id that owns this install. Null for `system` scope
  /// (global packages). Used by the UI to render a "Personal" vs
  /// "System" badge on each card.
  final String? ownerUserId;

  /// Frozen copy of the package.toml manifest. Sub-blocks are kept
  /// raw so the UI can pull anything new the daemon adds without
  /// requiring a model bump.
  final PackageManifest manifest;

  const AppPackage({
    required this.packageId,
    required this.name,
    required this.version,
    this.description = '',
    this.author = '',
    this.license,
    this.homepage,
    this.icon,
    this.category,
    this.sourceType = 'local',
    this.sourceUri,
    this.status = 'installed',
    this.hash,
    this.installDir,
    this.installedAt,
    this.updatedAt,
    this.updateAvailable,
    this.deployedAppId,
    this.runtimeStatus = 'running',
    this.deployError,
    this.scope,
    this.ownerUserId,
    this.manifest = const PackageManifest(),
  });

  factory AppPackage.fromJson(Map<String, dynamic> j) {
    final manifestRaw = j['manifest'] as Map?;
    final pkgMeta = manifestRaw?['package'] as Map? ?? const {};
    return AppPackage(
      packageId: j['package_id'] as String? ??
          pkgMeta['id'] as String? ??
          '',
      name: j['name'] as String? ??
          pkgMeta['name'] as String? ??
          '',
      version: j['version'] as String? ??
          pkgMeta['version'] as String? ??
          '0.0.0',
      description: j['description'] as String? ??
          pkgMeta['description'] as String? ??
          '',
      author: j['author'] as String? ??
          pkgMeta['author'] as String? ??
          '',
      license: pkgMeta['license'] as String?,
      homepage: pkgMeta['homepage'] as String?,
      // Icons may live at the top level (the legacy /api/apps shape
      // surfaces them there) OR nested inside the manifest. Take
      // whichever wins so installed packages render the same emoji
      // as the discover catalogue.
      icon: j['icon'] as String? ?? pkgMeta['icon'] as String?,
      category: j['category'] as String? ?? pkgMeta['category'] as String?,
      sourceType: j['source_type'] as String? ?? 'local',
      sourceUri: j['source_uri'] as String?,
      status: j['status'] as String? ?? 'installed',
      hash: j['hash'] as String?,
      installDir: j['install_dir'] as String?,
      installedAt: _parseDate(j['installed_at']),
      updatedAt: _parseDate(j['updated_at']),
      updateAvailable: j['update_available'] as String?,
      deployedAppId: j['deployed_app_id'] as String?,
      runtimeStatus: j['runtime_status'] as String? ?? 'running',
      deployError: j['deploy_error'] as String?,
      scope: j['scope'] as String?,
      ownerUserId: j['owner_user_id'] as String?,
      manifest: PackageManifest.fromRaw(
          manifestRaw?.cast<String, dynamic>() ?? const {}),
    );
  }

  /// Immutable-with-overrides — used by the Hub Updates tab to stamp
  /// `updateAvailable` back into the list after the per-app
  /// `/check-update` probe lands, without having to reconstruct the
  /// full object from JSON.
  AppPackage copyWith({
    String? status,
    String? updateAvailable,
    String? runtimeStatus,
    String? deployError,
  }) =>
      AppPackage(
        packageId: packageId,
        name: name,
        version: version,
        description: description,
        author: author,
        license: license,
        homepage: homepage,
        icon: icon,
        category: category,
        sourceType: sourceType,
        sourceUri: sourceUri,
        status: status ?? this.status,
        hash: hash,
        installDir: installDir,
        installedAt: installedAt,
        updatedAt: updatedAt,
        updateAvailable: updateAvailable ?? this.updateAvailable,
        deployedAppId: deployedAppId,
        runtimeStatus: runtimeStatus ?? this.runtimeStatus,
        deployError: deployError ?? this.deployError,
        scope: scope,
        ownerUserId: ownerUserId,
        manifest: manifest,
      );

  bool get isBuiltin => sourceType == 'builtin';
  bool get isInstalled => status == 'installed';
  bool get isBroken => status == 'broken' || runtimeStatus == 'broken';
  bool get isRunning => runtimeStatus == 'running';
  bool get isNotDeployed => runtimeStatus == 'not_deployed';
  bool get isDisabled => runtimeStatus == 'disabled';
  bool get hasUpdate => updateAvailable != null;

  /// True when this package was installed at the daemon level and
  /// is visible to every user. Admin-only mutations.
  bool get isSystemScope => scope == 'system';

  /// True when this package belongs to the current user only.
  /// Defaults to true for legacy responses that don't carry scope.
  bool get isUserScope => scope == null || scope == 'user';
}

/// Decoded package.toml manifest. Only the high-leverage sub-blocks
/// are typed; everything else is exposed as raw maps so the UI can
/// pull whatever it needs without a model bump.
class PackageManifest {
  final PackagePermissions permissions;
  final PackageRequirements requirements;
  final PackageCompatibility compatibility;
  final List<String> requiredCredentials;
  final List<String> optionalCredentials;
  final List<String> tags;
  final String? releaseNotes;
  final bool? releaseBreaking;
  final String? releasedAt;

  /// The full raw manifest map for unknown blocks.
  final Map<String, dynamic> raw;

  const PackageManifest({
    this.permissions = const PackagePermissions(),
    this.requirements = const PackageRequirements(),
    this.compatibility = const PackageCompatibility(),
    this.requiredCredentials = const [],
    this.optionalCredentials = const [],
    this.tags = const [],
    this.releaseNotes,
    this.releaseBreaking,
    this.releasedAt,
    this.raw = const {},
  });

  factory PackageManifest.fromRaw(Map<String, dynamic> raw) {
    final pkg = raw['package'] as Map? ?? const {};
    final perms = pkg['permissions'] as Map? ?? const {};
    final reqs = pkg['requirements'] as Map? ?? const {};
    final compat = pkg['compatibility'] as Map? ?? const {};
    final creds = pkg['credentials'] as Map? ?? const {};
    final hub = pkg['hub'] as Map? ?? const {};
    final release = pkg['release'] as Map? ?? const {};

    return PackageManifest(
      permissions: PackagePermissions.fromJson(perms.cast<String, dynamic>()),
      requirements: PackageRequirements.fromJson(reqs.cast<String, dynamic>()),
      compatibility:
          PackageCompatibility.fromJson(compat.cast<String, dynamic>()),
      requiredCredentials:
          (creds['required'] as List? ?? const []).map((e) => e.toString()).toList(),
      optionalCredentials:
          (creds['optional'] as List? ?? const []).map((e) => e.toString()).toList(),
      tags: (hub['tags'] as List? ?? const []).map((e) => e.toString()).toList(),
      releaseNotes: release['release_notes'] as String?,
      releaseBreaking: release['breaking'] as bool?,
      releasedAt: release['released_at'] as String?,
      raw: raw,
    );
  }
}

class PackagePermissions {
  /// `low` | `medium` | `high`
  final String riskLevel;
  final bool networkAccess;
  final List<String> filesystemAccess; // [], ["read"], ["read","write"]
  final List<String> filesystemScopes;
  final List<String> requiresApproval;

  const PackagePermissions({
    this.riskLevel = 'low',
    this.networkAccess = false,
    this.filesystemAccess = const [],
    this.filesystemScopes = const [],
    this.requiresApproval = const [],
  });

  factory PackagePermissions.fromJson(Map<String, dynamic> j) =>
      PackagePermissions(
        riskLevel: j['risk_level'] as String? ?? 'low',
        networkAccess: j['network_access'] == true,
        filesystemAccess: (j['filesystem_access'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        filesystemScopes: (j['filesystem_scopes'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        requiresApproval: (j['requires_approval'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
      );

  Color color(BuildContext context) {
    final mat = Theme.of(context);
    switch (riskLevel) {
      case 'high':
        return mat.colorScheme.error;
      case 'medium':
        return Colors.orange;
      default:
        return Colors.green;
    }
  }
}

class PackageRequirements {
  final List<String> modules;
  final List<String> recommendedModels;
  final int? minDiskMb;
  final int? minMemoryMb;
  final List<String> externalTools;

  const PackageRequirements({
    this.modules = const [],
    this.recommendedModels = const [],
    this.minDiskMb,
    this.minMemoryMb,
    this.externalTools = const [],
  });

  factory PackageRequirements.fromJson(Map<String, dynamic> j) =>
      PackageRequirements(
        modules: (j['modules'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        recommendedModels: (j['recommended_models'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        minDiskMb: (j['min_disk_mb'] as num?)?.toInt(),
        minMemoryMb: (j['min_memory_mb'] as num?)?.toInt(),
        externalTools: (j['external_tools'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}

class PackageCompatibility {
  final String? digitornMin;
  final String? digitornMax;
  final String? pythonMin;
  final List<String> platforms;

  const PackageCompatibility({
    this.digitornMin,
    this.digitornMax,
    this.pythonMin,
    this.platforms = const [],
  });

  factory PackageCompatibility.fromJson(Map<String, dynamic> j) =>
      PackageCompatibility(
        digitornMin: j['digitorn_min'] as String?,
        digitornMax: j['digitorn_max'] as String?,
        pythonMin: j['python_min'] as String?,
        platforms: (j['platforms'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}

/// Returned from `POST /api/packages/install` with the 409
/// `permissions_required` body. The client shows a consent dialog
/// and re-posts with `accept_permissions: true` once approved.
class PermissionsRequired {
  final PackagePermissions permissions;
  final List<String> requiredCredentials;
  final String? upgradeFromVersion;
  final List<String>? newPermissionsSinceUpgrade;

  const PermissionsRequired({
    required this.permissions,
    this.requiredCredentials = const [],
    this.upgradeFromVersion,
    this.newPermissionsSinceUpgrade,
  });

  factory PermissionsRequired.fromJson(Map<String, dynamic> j) {
    final perms = j['permissions'] as Map? ?? const {};
    return PermissionsRequired(
      permissions:
          PackagePermissions.fromJson(perms.cast<String, dynamic>()),
      requiredCredentials: (j['required_credentials'] as List? ?? const [])
          .map((e) => e.toString())
          .toList(),
      upgradeFromVersion: j['upgrade_from'] as String?,
      newPermissionsSinceUpgrade: j['new_permissions'] != null
          ? (j['new_permissions'] as List).map((e) => e.toString()).toList()
          : null,
    );
  }
}

DateTime? _parseDate(dynamic v) {
  if (v == null) return null;
  if (v is String) return DateTime.tryParse(v);
  if (v is num) {
    return DateTime.fromMillisecondsSinceEpoch((v * 1000).toInt());
  }
  return null;
}
