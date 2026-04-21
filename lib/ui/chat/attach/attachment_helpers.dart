import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pasteboard/pasteboard.dart';

import '../../../services/api_client.dart';

/// Shape of an attachment carried in the composer's `_attachments`
/// list. Kept as a record in the chat panel for historical reasons;
/// this helper class mirrors it so every attach callsite has a
/// single place to inspect / format / clone.
typedef AttachmentEntry = ({String name, String path, bool isImage});

/// Extensions we render as images in the attachment bar (thumbnail
/// preview) and route through the `images` payload on send instead
/// of `files`. Lower-case with leading dot.
const Set<String> kImageExtensions = {
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
  '.bmp',
  '.avif',
  '.heic',
};

bool isImagePath(String path) {
  final lower = path.toLowerCase();
  for (final ext in kImageExtensions) {
    if (lower.endsWith(ext)) return true;
  }
  return false;
}

String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// Rough MIME family → icon map for the attachment pill. Kept
/// minimal — we don't need mime sniffing, just the extension.
IconData iconForExtension(String path) {
  final ext = _ext(path);
  if (kImageExtensions.contains(ext)) return Icons.image_rounded;
  if (_video.contains(ext)) return Icons.movie_outlined;
  if (_audio.contains(ext)) return Icons.audiotrack_rounded;
  if (_code.contains(ext)) return Icons.code_rounded;
  if (_doc.contains(ext)) return Icons.article_outlined;
  if (_archive.contains(ext)) return Icons.folder_zip_outlined;
  if (_data.contains(ext)) return Icons.data_object_rounded;
  if (ext == '.pdf') return Icons.picture_as_pdf_outlined;
  return Icons.attach_file_rounded;
}

String _ext(String p) {
  final normalised = p.toLowerCase();
  final dot = normalised.lastIndexOf('.');
  if (dot < 0 || dot == normalised.length - 1) return '';
  return normalised.substring(dot);
}

const _video = {'.mp4', '.webm', '.mov', '.mkv', '.avi', '.m4v'};
const _audio = {'.mp3', '.wav', '.flac', '.ogg', '.m4a', '.aac'};
const _code = {
  '.dart', '.js', '.ts', '.tsx', '.jsx', '.py', '.rb', '.go', '.rs',
  '.java', '.kt', '.swift', '.c', '.cpp', '.h', '.cs', '.php', '.sh',
  '.bash', '.zsh', '.ps1', '.sql', '.html', '.css', '.scss', '.yaml',
  '.yml', '.toml',
};
const _doc = {'.md', '.txt', '.rtf', '.doc', '.docx', '.odt'};
const _archive = {'.zip', '.tar', '.gz', '.bz2', '.7z', '.rar'};
const _data = {'.json', '.csv', '.tsv', '.xml', '.parquet'};

/// Grab any image currently sitting on the OS clipboard and write it
/// to a tmp file. Returns the absolute path or `null` when the
/// clipboard has no image (common when the user last copied text).
///
/// Used by both the composer's `Ctrl/Cmd+V` intent handler and the
/// attach menu's "Paste from clipboard" entry.
Future<String?> clipboardImageToTempFile() async {
  try {
    final bytes = await Pasteboard.image;
    if (bytes == null || bytes.isEmpty) return null;
    return await _writeTempPng(bytes);
  } catch (e) {
    debugPrint('clipboardImageToTempFile failed: $e');
    return null;
  }
}

Future<String> _writeTempPng(Uint8List bytes) async {
  final dir = await getTemporaryDirectory();
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final path = '${dir.path}${Platform.pathSeparator}paste-$stamp.png';
  await File(path).writeAsBytes(bytes, flush: true);
  return path;
}

/// Trigger the OS's interactive screenshot UI and return the path
/// of the captured PNG.
///
/// Platform behaviour:
///   * macOS   — `screencapture -i -c` opens the marquee selection,
///               waits synchronously, copies to clipboard. We read
///               the clipboard immediately after.
///   * Windows — launches `ms-screenclip:` (Snipping Tool overlay,
///               ships with Win 10/11). We then poll the clipboard
///               for up to 45 seconds for the captured image.
///   * Linux   — best-effort via `gnome-screenshot -a -c`, fallback
///               is `null` (the UI will tell the user to use their
///               own tool + paste).
///
/// Returns `null` when the user cancelled, the OS tool is missing,
/// or the clipboard ended up empty.
Future<String?> captureScreenshot() async {
  if (kIsWeb) return null;
  try {
    if (Platform.isMacOS) {
      final result = await Process.run('screencapture', ['-i', '-c']);
      if (result.exitCode != 0) return null;
      await Future.delayed(const Duration(milliseconds: 160));
      return await clipboardImageToTempFile();
    }
    if (Platform.isWindows) {
      // `explorer.exe` resolves URI schemes — `ms-screenclip:` opens
      // the Snipping Tool overlay. We launch async (can't await the
      // overlay) and poll the clipboard until an image lands.
      unawaited(Process.run('explorer.exe', ['ms-screenclip:']));
      return await _pollClipboardForImage(
          timeout: const Duration(seconds: 45));
    }
    if (Platform.isLinux) {
      try {
        final r = await Process.run('gnome-screenshot', ['-a', '-c']);
        if (r.exitCode == 0) {
          return await clipboardImageToTempFile();
        }
      } catch (_) {}
      return null;
    }
  } catch (e) {
    debugPrint('captureScreenshot failed: $e');
  }
  return null;
}

Future<String?> _pollClipboardForImage({
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await Future.delayed(const Duration(milliseconds: 350));
    final path = await clipboardImageToTempFile();
    if (path != null) return path;
  }
  return null;
}

/// Fetch a file that lives on the daemon's workspace side and write
/// it to a local tmp path so it can flow through the existing
/// `_attachments → enqueueMessage(files: [...])` plumbing (which
/// reads from disk via path). Returns the tmp path on success,
/// `null` if the fetch / write failed.
///
/// [workspacePath] is the absolute path inside the session's
/// workspace — exactly what `WorkspaceFile.path` holds.
Future<String?> downloadWorkspaceFileToTemp({
  required String appId,
  required String sessionId,
  required String workspacePath,
}) async {
  if (kIsWeb) {
    // Web builds can't write tmp files directly; fall back to
    // pushing a data URI via the caller. For now we just abort.
    return null;
  }
  try {
    final result = await DigitornApiClient()
        .fetchFileContent(appId, sessionId, workspacePath);
    if (result == null) return null;
    final content = result.file.content;
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final base = workspacePath
        .split(RegExp(r'[\\/]'))
        .where((s) => s.isNotEmpty)
        .last;
    final tmpPath = '${dir.path}${Platform.pathSeparator}ws-$stamp-$base';
    await File(tmpPath).writeAsBytes(utf8.encode(content), flush: true);
    return tmpPath;
  } catch (e) {
    debugPrint('downloadWorkspaceFileToTemp failed: $e');
    return null;
  }
}
