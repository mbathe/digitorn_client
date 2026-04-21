import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Result of loading an app bundle: the YAML bytes to upload as the
/// `file` form field, plus a map of relative-path → UTF-8 content to
/// send as the JSON-encoded `assets` form field.
class AppBundle {
  final Uint8List yamlBytes;
  final String yamlFilename;
  final Map<String, String> assets;

  const AppBundle({
    required this.yamlBytes,
    required this.yamlFilename,
    required this.assets,
  });

  int get totalAssetBytes =>
      assets.values.fold<int>(0, (acc, s) => acc + utf8.encode(s).length);
}

/// Raised when the picked file can't be turned into an [AppBundle].
class AppBundleException implements Exception {
  final String message;
  const AppBundleException(this.message);
  @override
  String toString() => 'AppBundleException: $message';
}

/// Platform-agnostic bundle loader — works identically on Flutter Web
/// (where `dart:io` is unavailable) and on Desktop.
///
/// Input contract: give it the raw bytes of whatever the user picked
/// plus the original filename. The loader decides between two modes:
///
/// - **Raw YAML** (`.yaml` / `.yml`) → the bundle is just the file
///   itself with an empty asset map. Works for apps that reference no
///   external files. If the daemon later complains about a missing
///   skill, the user knows they need to upload a ZIP instead.
///
/// - **ZIP archive** (`.zip`) → unpacks the archive, treats the first
///   `.yaml` / `.yml` file found as the app manifest, and maps every
///   other file inside the same directory tree to the asset map with
///   keys normalised to forward-slash, relative-to-YAML paths (matching
///   the daemon's contract).
///
/// All error paths throw [AppBundleException] with a human-readable
/// message so the deploy flow can surface it in its copy-friendly
/// error dialog.
AppBundle loadAppBundle({
  required Uint8List bytes,
  required String filename,
}) {
  final name = filename.toLowerCase();
  if (name.endsWith('.zip')) {
    return _loadFromZip(bytes);
  }
  if (name.endsWith('.yaml') || name.endsWith('.yml')) {
    return AppBundle(
      yamlBytes: bytes,
      yamlFilename: filename,
      assets: const {},
    );
  }
  throw AppBundleException(
    'Unsupported file "$filename". Pick a .yaml / .yml file, or a .zip '
    'archive containing app.yaml + its skills.',
  );
}

/// Unzip + classify archive entries.
///
/// Layout handled:
/// ```
/// my-app/
///   app.yaml               ← becomes yamlBytes
///   skills/commit.md       ← becomes assets['skills/commit.md']
///   skills/review.md       ← becomes assets['skills/review.md']
///   prompts/main.md        ← becomes assets['prompts/main.md']
/// ```
///
/// The top-level `my-app/` prefix is stripped automatically so keys
/// match the relative paths the YAML uses (e.g. `./skills/commit.md`).
/// Zips with no wrapping folder (files at the archive root) also work.
AppBundle _loadFromZip(Uint8List bytes) {
  final ZipDecoder decoder = ZipDecoder();
  late final Archive archive;
  try {
    archive = decoder.decodeBytes(bytes, verify: true);
  } catch (e) {
    throw AppBundleException('Invalid ZIP archive: $e');
  }

  // Find the first YAML file — we prefer shallow-most so a file called
  // `app.yaml` at the root wins over a nested `examples/other.yaml`.
  ArchiveFile? yamlEntry;
  var yamlDepth = 1 << 30;
  for (final f in archive) {
    if (!f.isFile) continue;
    final n = f.name.replaceAll('\\', '/').toLowerCase();
    if (!n.endsWith('.yaml') && !n.endsWith('.yml')) continue;
    final depth = '/'.allMatches(n).length;
    if (depth < yamlDepth) {
      yamlDepth = depth;
      yamlEntry = f;
    }
  }
  if (yamlEntry == null) {
    throw const AppBundleException(
      'No .yaml / .yml file found inside the archive.',
    );
  }

  // Determine the directory prefix of the YAML, if any. Everything
  // under this prefix becomes a candidate asset; paths are rewritten
  // to be relative to the YAML directory.
  final yamlPath = yamlEntry.name.replaceAll('\\', '/');
  final lastSlash = yamlPath.lastIndexOf('/');
  final prefix = lastSlash >= 0 ? yamlPath.substring(0, lastSlash + 1) : '';
  final yamlFilename = lastSlash >= 0
      ? yamlPath.substring(lastSlash + 1)
      : yamlPath;

  // Extract YAML bytes.
  final yamlData = yamlEntry.content;
  if (yamlData is! List<int>) {
    throw const AppBundleException(
      'Could not read YAML entry from the archive.',
    );
  }
  final yamlBytes = Uint8List.fromList(yamlData);

  // Collect all other files as assets.
  final assets = <String, String>{};
  for (final f in archive) {
    if (!f.isFile) continue;
    if (identical(f, yamlEntry)) continue;

    var name = f.name.replaceAll('\\', '/');
    if (prefix.isNotEmpty) {
      if (!name.startsWith(prefix)) {
        // Outside the YAML's directory tree — skip.
        continue;
      }
      name = name.substring(prefix.length);
    }
    if (name.isEmpty || name.startsWith('/') || name.contains('..')) continue;
    if (name.length > 512) {
      throw AppBundleException('Asset path too long: $name');
    }

    final data = f.content;
    if (data is! List<int>) continue;

    try {
      assets[name] = utf8.decode(data);
    } catch (_) {
      // Binary / non-UTF-8 asset — skip silently. The current daemon
      // contract only supports text assets (skills & prompts are .md).
    }
  }

  // Enforce the daemon's 5 MB cumulative asset cap client-side so we
  // fail fast with a clear message.
  const maxAssetBytes = 5 * 1024 * 1024;
  var total = 0;
  for (final v in assets.values) {
    total += utf8.encode(v).length;
  }
  if (total > maxAssetBytes) {
    throw AppBundleException(
      'Assets total ${(total / 1024 / 1024).toStringAsFixed(2)} MB '
      '(limit 5 MB). Trim your bundle and retry.',
    );
  }

  return AppBundle(
    yamlBytes: yamlBytes,
    yamlFilename: yamlFilename,
    assets: assets,
  );
}
