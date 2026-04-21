/// Three user-facing actions on a session's workspace:
///
///   * [saveCopy]  — export the snapshot and write it to a `.json`
///                   file picked by the user.
///   * [fork]      — create a new session with a copy of the current
///                   workspace; navigate to it on success.
///   * [importFromFile] — pick a `.json` envelope from disk and push
///                   it into the current session. A confirmation
///                   modal warns the user when the session already
///                   has files.
///
/// All three share:
///   * the singleton [WorkspaceSnapshotService] for API calls + busy
///     state;
///   * consistent toast UX (success + failure);
///   * null-safe guards so calling with a missing active session
///     does nothing loudly instead of crashing silently.
library;

import 'dart:convert';
import 'dart:io' show File;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/api_client.dart';
import '../../services/preview_store.dart';
import '../../services/session_service.dart';
import '../../services/workspace_snapshot_service.dart';
import '../../theme/app_theme.dart';

class WorkspaceSnapshotActions {
  WorkspaceSnapshotActions._();

  /// Returns the active (appId, sessionId) tuple or null, and toasts
  /// if anything is missing — centralised so each action doesn't
  /// repeat the same null checks.
  static ({String appId, String sessionId})? _resolve(
      BuildContext context) {
    final session = SessionService().activeSession;
    if (session == null) {
      _toast(context, 'No active session.', error: true);
      return null;
    }
    return (appId: session.appId, sessionId: session.sessionId);
  }

  // ── Save a copy ────────────────────────────────────────────────

  /// Export the workspace, let the user pick a save location, and
  /// write a pretty-printed JSON envelope to disk.
  static Future<void> saveCopy(BuildContext context) async {
    final res = _resolve(context);
    if (res == null) return;
    final envelope = await WorkspaceSnapshotService().export(
      appId: res.appId,
      sessionId: res.sessionId,
    );
    if (envelope == null) {
      if (context.mounted) {
        _toast(context,
            WorkspaceSnapshotService().lastError ?? 'Export failed.',
            error: true);
      }
      return;
    }
    if (!context.mounted) return;
    final suggested =
        'digitorn-${envelope.sourceSessionId.split('-').last}.json';
    try {
      if (kIsWeb) {
        // Web: can't write to arbitrary paths. Fall through to the
        // platform channel used by the `file_selector` plugin;
        // it triggers a browser download.
      }
      final location = await getSaveLocation(
        suggestedName: suggested,
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Digitorn snapshot', extensions: ['json']),
        ],
      );
      if (location == null) return;
      final bytes = Uint8List.fromList(
        utf8.encode(const JsonEncoder.withIndent('  ').convert(envelope.toJson())),
      );
      final file = XFile.fromData(
        bytes,
        name: suggested,
        mimeType: 'application/json',
      );
      await file.saveTo(location.path);
      if (context.mounted) {
        _toast(context,
            'Saved · ${envelope.totalResources} file${envelope.totalResources == 1 ? '' : 's'}');
      }
    } catch (e) {
      if (context.mounted) {
        _toast(context, 'Save failed: $e', error: true);
      }
    }
  }

  // ── Fork ────────────────────────────────────────────────────────

  /// Ask the daemon to copy the workspace into a new session, then
  /// switch the app to it. The user stays in the same app; only the
  /// active session changes.
  static Future<void> fork(BuildContext context, {String? title}) async {
    final res = _resolve(context);
    if (res == null) return;
    final result = await WorkspaceSnapshotService().fork(
      appId: res.appId,
      sessionId: res.sessionId,
      title: title,
    );
    if (result == null) {
      if (context.mounted) {
        _toast(context,
            WorkspaceSnapshotService().lastError ?? 'Fork failed.',
            error: true);
      }
      return;
    }
    if (!context.mounted) return;
    // Switch to the forked session. The daemon already created it;
    // we just need to make it the active one client-side so the
    // chat panel replays its (freshly copied) history.
    final forkedSession = AppSession(
      sessionId: result.sessionId,
      appId: res.appId,
      title: title ?? 'Fork',
    );
    SessionService().setActiveSession(forkedSession);
    _toast(
      context,
      'Forked · ${result.files} file${result.files == 1 ? '' : 's'} copied',
    );
  }

  // ── Import from file ────────────────────────────────────────────

  /// Open a native file picker, parse the envelope, and push it into
  /// the current session. If the session already has workspace state
  /// a confirm modal warns about the replacement.
  static Future<void> importFromFile(BuildContext context) async {
    final res = _resolve(context);
    if (res == null) return;
    XFile? file;
    try {
      file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Digitorn snapshot', extensions: ['json']),
        ],
      );
    } catch (e) {
      if (context.mounted) {
        _toast(context, 'Could not open file picker: $e', error: true);
      }
      return;
    }
    if (file == null) return;

    WorkspaceSnapshotEnvelope envelope;
    try {
      final text = kIsWeb
          ? utf8.decode(await file.readAsBytes())
          : await File(file.path).readAsString();
      final json = jsonDecode(text);
      if (json is! Map) throw const FormatException('Not a JSON object');
      envelope =
          WorkspaceSnapshotEnvelope.fromJson(json.cast<String, dynamic>());
      if (envelope.format != 'digitorn.workspace.snapshot') {
        throw const FormatException('Not a Digitorn workspace snapshot');
      }
    } catch (e) {
      if (context.mounted) {
        _toast(context, 'Invalid snapshot: $e', error: true);
      }
      return;
    }

    if (!context.mounted) return;

    // Count what the current session already has — warn if we're
    // about to replace work in progress.
    final existingFiles = PreviewStore().resources['files']?.length ?? 0;
    if (existingFiles > 0) {
      final confirm = await _confirmReplace(
        context,
        existingFiles: existingFiles,
        incomingFiles: envelope.totalResources,
      );
      if (confirm != true) return;
    }

    final ok = await WorkspaceSnapshotService().import(
      appId: res.appId,
      sessionId: res.sessionId,
      envelope: envelope,
      replace: true,
    );
    if (!context.mounted) return;
    if (ok) {
      _toast(context,
          'Imported · ${envelope.totalResources} file${envelope.totalResources == 1 ? '' : 's'}');
    } else {
      _toast(
        context,
        WorkspaceSnapshotService().lastError ?? 'Import failed.',
        error: true,
      );
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────

  static Future<bool?> _confirmReplace(
    BuildContext context, {
    required int existingFiles,
    required int incomingFiles,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (dctx) {
        final c = dctx.colors;
        return AlertDialog(
          backgroundColor: c.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: c.orange, size: 20),
              const SizedBox(width: 8),
              Text('Replace workspace?',
                  style: GoogleFonts.inter(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Text(
              'This will replace $existingFiles file${existingFiles == 1 ? '' : 's'} '
              'in the current session with $incomingFiles from the snapshot. '
              'The current state cannot be recovered — consider Save a copy '
              'first if you want to keep it.',
              style: GoogleFonts.inter(
                  fontSize: 13, color: c.textMuted, height: 1.55),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(false),
              child: Text('Cancel',
                  style: GoogleFonts.inter(color: c.textMuted)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: c.orange,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(dctx).pop(true),
              child: const Text('Replace'),
            ),
          ],
        );
      },
    );
  }

  static void _toast(BuildContext context, String message,
      {bool error = false}) {
    final c = context.colors;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Row(children: [
          Icon(
            error
                ? Icons.error_outline_rounded
                : Icons.check_circle_rounded,
            size: 14,
            color: error ? c.red : c.green,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: GoogleFonts.inter(fontSize: 12.5, color: c.text),
            ),
          ),
        ]),
        backgroundColor: c.surfaceAlt,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8)),
        margin: const EdgeInsets.all(16),
        duration: Duration(seconds: error ? 5 : 2),
      ));
  }
}
