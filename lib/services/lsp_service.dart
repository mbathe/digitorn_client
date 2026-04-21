/// High-level wrapper around the LSP RPC endpoint
/// `POST /api/apps/{app_id}/sessions/{sid}/lsp/request` and its
/// companion `POST .../lsp/cancel`.
///
/// Each helper (hover, definition, references, completion, rename)
/// returns the raw LSP result payload (decoded JSON), or `null` when
/// the request errored — the Monaco provider convention expects
/// `null` to mean "nothing to show", never a thrown exception.
///
/// ## Supersession
///
/// The daemon auto-cancels any in-flight request for the same
/// `(session, path, method)` triple when a new one arrives, unless
/// [request] is called with `supersedePrevious: false`. Per-method
/// helpers pick the right default:
///
///   * hover / definition / completion / signatureHelp / symbols
///     → `supersede=true`  — fast-typing UX, stale results are noise
///   * references / rename
///     → `supersede=false` — user-initiated, results always matter
///
/// ## Client-side cancellation
///
/// Every helper accepts an optional [CancelToken]. Cancel the token
/// and the Dio socket drops; the daemon detects the disconnect
/// (≤100 ms) and cancels the underlying LSP task. The helper also
/// sends an explicit `/lsp/cancel` as belt-and-suspenders when a
/// [requestId] is known.
///
/// The escape hatch [request] throws [LspException] on errors so
/// callers that care can handle them; typed helpers return null.
library;

import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'session_service.dart';

class LspService {
  static final LspService _i = LspService._();
  factory LspService() => _i;
  LspService._();

  /// Returns true when we have an active session — LSP calls short
  /// circuit when there isn't one.
  bool get available => SessionService().activeSession != null;

  /// `textDocument/hover` — returns the raw LSP Hover object
  /// (`{contents: MarkupContent | MarkedString[], range?}`) or null.
  Future<dynamic> hover(
    String path,
    LspPosition pos, {
    String? requestId,
    CancelToken? cancelToken,
  }) =>
      _safe(
        path: path,
        method: 'textDocument/hover',
        params: {'position': pos.toJson()},
        requestId: requestId,
        cancelToken: cancelToken,
        supersedePrevious: true,
      );

  /// `textDocument/definition` — returns `Location | Location[] | null`.
  Future<dynamic> definition(
    String path,
    LspPosition pos, {
    String? requestId,
    CancelToken? cancelToken,
  }) =>
      _safe(
        path: path,
        method: 'textDocument/definition',
        params: {'position': pos.toJson()},
        requestId: requestId,
        cancelToken: cancelToken,
        supersedePrevious: true,
      );

  /// `textDocument/references` — returns `Location[] | null`.
  /// User-initiated: defaults to [supersedePrevious] = false so a
  /// second click does not discard the first's results.
  Future<dynamic> references(
    String path,
    LspPosition pos, {
    bool includeDeclaration = true,
    String? requestId,
    CancelToken? cancelToken,
  }) =>
      _safe(
        path: path,
        method: 'textDocument/references',
        params: {
          'position': pos.toJson(),
          'context': {'includeDeclaration': includeDeclaration},
        },
        requestId: requestId,
        cancelToken: cancelToken,
        supersedePrevious: false,
      );

  /// `textDocument/completion` — returns `CompletionList | CompletionItem[] | null`.
  Future<dynamic> completion(
    String path,
    LspPosition pos, {
    String? triggerCharacter,
    String? requestId,
    CancelToken? cancelToken,
  }) =>
      _safe(
        path: path,
        method: 'textDocument/completion',
        params: {
          'position': pos.toJson(),
          if (triggerCharacter != null)
            'context': {
              'triggerKind': 2, // TriggerCharacter
              'triggerCharacter': triggerCharacter,
            },
        },
        requestId: requestId,
        cancelToken: cancelToken,
        supersedePrevious: true,
      );

  /// `textDocument/rename` — returns a `WorkspaceEdit` or null.
  /// User-initiated: no supersession.
  Future<dynamic> rename(
    String path,
    LspPosition pos,
    String newName, {
    String? requestId,
    CancelToken? cancelToken,
  }) =>
      _safe(
        path: path,
        method: 'textDocument/rename',
        params: {
          'position': pos.toJson(),
          'newName': newName,
        },
        requestId: requestId,
        cancelToken: cancelToken,
        supersedePrevious: false,
      );

  /// `textDocument/signatureHelp` — returns a `SignatureHelp` or null.
  Future<dynamic> signatureHelp(
    String path,
    LspPosition pos, {
    String? requestId,
    CancelToken? cancelToken,
  }) =>
      _safe(
        path: path,
        method: 'textDocument/signatureHelp',
        params: {'position': pos.toJson()},
        requestId: requestId,
        cancelToken: cancelToken,
        supersedePrevious: true,
      );

  /// `textDocument/documentSymbol` — returns
  /// `DocumentSymbol[] | SymbolInformation[] | null`.
  Future<dynamic> documentSymbols(
    String path, {
    String? requestId,
    CancelToken? cancelToken,
  }) =>
      _safe(
        path: path,
        method: 'textDocument/documentSymbol',
        params: const {},
        requestId: requestId,
        cancelToken: cancelToken,
        supersedePrevious: true,
      );

  /// Escape hatch — send any LSP method. Throws [LspException] on
  /// errors. Pass a [cancelToken] to tie the HTTP call to a client-
  /// side cancellation; the daemon cancels the LSP task on socket
  /// disconnect.
  Future<dynamic> request(
    String path,
    String method,
    Map<String, dynamic> params, {
    int? timeoutSeconds,
    String? requestId,
    bool supersedePrevious = true,
    CancelToken? cancelToken,
  }) async {
    final session = SessionService().activeSession;
    if (session == null) {
      throw const LspException('No active session');
    }
    final res = await DigitornApiClient().lspRequest(
      session.appId,
      session.sessionId,
      path: path,
      method: method,
      params: params,
      timeoutSeconds: timeoutSeconds,
      requestId: requestId,
      supersedePrevious: supersedePrevious,
      cancelToken: cancelToken,
    );
    if (res.cancelled) {
      throw const LspException('cancelled');
    }
    if (!res.success) {
      throw LspException(res.error ?? 'LSP request failed');
    }
    return res.result;
  }

  /// Best-effort cancellation of an in-flight request by its id.
  /// Returns true on transport success (the daemon may still reply
  /// `{success: false, error: "request not found"}` if the task had
  /// already settled — treated as a no-op).
  Future<bool> cancel(String requestId) async {
    final session = SessionService().activeSession;
    if (session == null) return false;
    return DigitornApiClient().lspCancel(
      session.appId,
      session.sessionId,
      requestId,
    );
  }

  /// Generate a request id unique per client. Format:
  ///   `lsp-<ms>-<rand>` — collision-free enough for a single
  /// process and compact enough to keep network payloads small.
  static String newRequestId() {
    final ms = DateTime.now().microsecondsSinceEpoch;
    final r = _rng.nextInt(1 << 32).toRadixString(36);
    return 'lsp-$ms-$r';
  }

  static final math.Random _rng = math.Random();

  /// Internal helper — the null-on-error variant the Monaco providers
  /// consume. Cancellation returns null silently; other errors are
  /// logged at debug level only (400 "No LSP server" is common and
  /// expected on non-code files).
  Future<dynamic> _safe({
    required String path,
    required String method,
    required Map<String, dynamic> params,
    required bool supersedePrevious,
    String? requestId,
    CancelToken? cancelToken,
  }) async {
    final session = SessionService().activeSession;
    if (session == null) return null;
    try {
      final res = await DigitornApiClient().lspRequest(
        session.appId,
        session.sessionId,
        path: path,
        method: method,
        params: params,
        requestId: requestId,
        supersedePrevious: supersedePrevious,
        cancelToken: cancelToken,
      );
      if (res.cancelled) return null;
      if (!res.success) {
        debugPrint('LSP $method($path) failed: ${res.error}');
        return null;
      }
      return res.result;
    } catch (e) {
      debugPrint('LSP $method($path) crashed: $e');
      return null;
    }
  }
}

/// Position within a document, LSP-style (0-based line / character).
/// Monaco emits 1-based coordinates — the Dart-side Monaco bridge
/// does the -1 conversion before calling into [LspService] (see
/// `monaco_editor_pane.dart::_handleLspRequest`).
class LspPosition {
  final int line;
  final int character;
  const LspPosition(this.line, this.character);
  Map<String, dynamic> toJson() => {
        'line': line,
        'character': character,
      };
}

class LspException implements Exception {
  final String message;
  const LspException(this.message);
  @override
  String toString() => 'LspException: $message';
}
