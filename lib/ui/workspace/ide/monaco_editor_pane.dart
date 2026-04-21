/// Flutter wrapper around Monaco (the editor powering VS Code).
/// Embeds `assets/monaco/editor.html` inside a platform WebView and
/// exchanges postMessage envelopes with it.
///
/// Platform selection:
///   * Windows / Linux → `webview_windows` (Chromium WebView2)
///   * macOS / iOS / Android → `webview_flutter`
///   * Web → not supported yet. The widget shows a "not available"
///     placeholder on this platform.
///
/// Messages the host sends to Monaco:
///   `{type:"setModel", path, content, language?, readOnly?}`
///   `{type:"setTheme", theme:"dark"|"light"}`
///   `{type:"focus"}`
///   `{type:"goToLine", line, column?}`
///
/// Messages Monaco sends back:
///   `{type:"ready"}`
///   `{type:"contentChanged", path, content}`
///   `{type:"save", path}`   — Ctrl/Cmd+S pressed by the user
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:google_fonts/google_fonts.dart';
import 'package:webview_flutter/webview_flutter.dart' as wv_mobile;
import 'package:webview_windows/webview_windows.dart' as wv_win;

import '../../../models/diagnostic.dart';
import '../../../services/file_actions_service.dart';
import '../../../services/lsp_service.dart';
import '../../../services/theme_service.dart';
import '../../../services/workspace_module.dart';
import '../../../theme/app_theme.dart';

/// Private — only MonacoEditorPane needs to know whether the
/// current platform can host a WebView. Web is the single exclusion.
bool get _canHostWebview {
  if (kIsWeb) return false;
  try {
    return Platform.isWindows ||
        Platform.isMacOS ||
        Platform.isLinux ||
        Platform.isAndroid ||
        Platform.isIOS;
  } catch (_) {
    return false;
  }
}

class MonacoEditorPane extends StatefulWidget {
  final String path;
  final String content;
  final String language;
  final bool readOnly;
  /// Initial line to scroll to once Monaco is ready. Null = top.
  final int? initialLine;
  /// Fires when the user blurs the editor or presses Ctrl+S while
  /// `readOnly` is false. Carries the current Monaco buffer so the
  /// caller can PUT it back to the daemon (`/workspace/files/{path}`).
  /// Null = no writeback wire (legacy read-only mode).
  final void Function(String path, String content)? onSaveRequest;
  const MonacoEditorPane({
    super.key,
    required this.path,
    required this.content,
    this.language = '',
    this.readOnly = true,
    this.initialLine,
    this.onSaveRequest,
  });

  @override
  State<MonacoEditorPane> createState() => _MonacoEditorPaneState();
}

class _MonacoEditorPaneState extends State<MonacoEditorPane> {
  // ── Platform-specific controllers (one will be non-null) ──────
  wv_win.WebviewController? _winCtrl;
  wv_mobile.WebViewController? _mobileCtrl;

  bool _ready = false;
  bool _initError = false;
  /// Synchronous "defunct" latch — set at the TOP of [dispose] so
  /// any buffered stream event that lands before the WebView's own
  /// subscription is fully torn down sees a clear "drop me" signal.
  /// `State.mounted` alone is racy here because the platform
  /// controllers are disposed asynchronously.
  bool _disposed = false;
  StreamSubscription? _winMsgSub;
  int _lastRevealRequest = 0;
  int _lastDiagnosticsGeneration = -1;

  /// In-flight LSP requests keyed by the id Monaco generated in the
  /// `lspRequest` envelope. Each request gets its own [CancelToken]
  /// so an `lspCancel` message can drop the HTTP socket (which the
  /// daemon translates into an LSP task cancel within ~100 ms) and
  /// a `/lsp/cancel` REST call is fired as belt-and-suspenders.
  final Map<String, CancelToken> _lspTokens = {};

  /// Last content the JS side reported via `contentChanged`. Used on
  /// blur to decide whether to emit `onSaveRequest` (avoid PUTs when
  /// the user focuses / defocuses without editing).
  String? _lastBuffer;

  bool get _isWindowsLike =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux);

  @override
  void initState() {
    super.initState();
    debugPrint('Monaco.initState path=${widget.path} '
        'contentLen=${widget.content.length}');
    _init();
    // React to theme changes live.
    ThemeService().addListener(_onThemeChanged);
    // React to diagnostics + reveal-target changes.
    WorkspaceModule().addListener(_onWorkspaceChanged);
  }

  void _onThemeChanged() {
    if (_ready) _sendTheme();
  }

  void _onWorkspaceChanged() {
    if (!_ready) return;
    _pushDiagnostics();
    _maybeHandleReveal();
  }

  @override
  void didUpdateWidget(MonacoEditorPane old) {
    super.didUpdateWidget(old);
    if (!_ready) return;
    // Content / path changes → push a new model, then re-apply
    // markers (new path = different model, different marker set).
    if (old.path != widget.path || old.content != widget.content) {
      _pushModel();
      _lastDiagnosticsGeneration = -1;
      _pushDiagnostics();
    }
    if (old.readOnly != widget.readOnly) {
      _pushModel();
    }
  }

  @override
  void dispose() {
    debugPrint('Monaco.dispose path=${widget.path} ready=$_ready');
    // Latch BEFORE anything else so any stream event arriving mid-
    // dispose sees the defunct flag and drops the message.
    _disposed = true;
    ThemeService().removeListener(_onThemeChanged);
    WorkspaceModule().removeListener(_onWorkspaceChanged);
    // Drop every in-flight LSP request — the daemon will see the
    // disconnect and cancel the underlying task. Without this, a
    // long-running reference search keeps the language server busy
    // after the editor is gone.
    for (final tok in _lspTokens.values) {
      if (!tok.isCancelled) tok.cancel('editor disposed');
    }
    _lspTokens.clear();
    _winMsgSub?.cancel();
    _winCtrl?.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final html = await rootBundle.loadString('assets/monaco/editor.html');
      if (_isWindowsLike) {
        final ctrl = wv_win.WebviewController();
        await ctrl.initialize();
        _winCtrl = ctrl;
        _winMsgSub = ctrl.webMessage.listen(_onWinMessage);
        await ctrl.setBackgroundColor(Colors.transparent);
        await ctrl.loadStringContent(html);
      } else {
        final ctrl = wv_mobile.WebViewController()
          ..setJavaScriptMode(wv_mobile.JavaScriptMode.unrestricted)
          ..setBackgroundColor(Colors.transparent);
        ctrl.addJavaScriptChannel(
          'MonacoBridge',
          onMessageReceived: (m) => _onMobileMessage(m.message),
        );
        // Base URL lets Monaco's dynamic worker loader resolve.
        await ctrl.loadHtmlString(html,
            baseUrl: 'https://digitorn.local/');
        _mobileCtrl = ctrl;
      }
    } catch (e) {
      debugPrint('Monaco init failed: $e');
      if (mounted) setState(() => _initError = true);
    }
  }

  // ── Inbound messages ───────────────────────────────────────────

  void _onWinMessage(dynamic data) {
    if (_disposed || !mounted) return;
    if (data is String) {
      _handleMessage(data);
    } else if (data is Map) {
      _handleMessage(jsonEncode(data));
    }
  }

  void _onMobileMessage(String raw) {
    if (_disposed || !mounted) return;
    _handleMessage(raw);
  }

  void _handleMessage(String raw) {
    // Stream subscription cancel is async — messages buffered before
    // dispose can still land. Every path below potentially calls
    // setState, so guard at the top and drop stale messages.
    if (_disposed || !mounted) {
      return;
    }
    Map<String, dynamic> msg;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      msg = decoded.cast<String, dynamic>();
    } catch (_) {
      return;
    }
    if (_disposed || !mounted) return;
    switch (msg['type']) {
      case 'ready':
        if (_disposed || !mounted) return;
        setState(() => _ready = true);
        _pushModel();
        _sendTheme();
        _pushDiagnostics();
        _maybeHandleReveal();
        if (widget.initialLine != null) {
          _send({'type': 'goToLine', 'line': widget.initialLine});
        }
        break;
      case 'save':
        // User hit Ctrl/Cmd+S.
        //   - editable mode  → route to [onSaveRequest] so the
        //     host can PUT the buffer to the daemon.
        //   - read-only mode → preserve the legacy shortcut by
        //     approving the file (snapshot current baseline).
        final path = msg['path'] as String? ?? widget.path;
        final content = msg['content'] as String? ?? widget.content;
        if (!widget.readOnly && widget.onSaveRequest != null) {
          widget.onSaveRequest!(path, content);
        } else {
          FileActionsService().approve(path);
        }
      case 'contentChanged':
        // The host decides what to do with unblurred changes — the
        // scout-confirmed contract is: don't PUT on every keystroke,
        // wait for blur / save to avoid flooding the daemon.
        _lastBuffer = msg['content'] as String? ?? widget.content;
        break;
      case 'editorBlurred':
        // Editor lost focus. In editable mode this is the canonical
        // moment to writeback — but only when the buffer actually
        // differs from what the host initially sent us (avoids a PUT
        // every time the user clicks elsewhere without editing).
        if (!widget.readOnly &&
            widget.onSaveRequest != null &&
            _lastBuffer != null &&
            _lastBuffer != widget.content) {
          widget.onSaveRequest!(widget.path, _lastBuffer!);
        }
        break;
      case 'lspRequest':
        _handleLspRequest(msg);
      case 'lspCancel':
        _handleLspCancel(msg);
    }
  }

  /// Forward an LSP request from Monaco to the daemon and reply to
  /// the WebView with an `lspResponse` carrying the same `id` so the
  /// JS side can resolve its pending-promise map.
  ///
  /// Payload shape from Monaco:
  ///   `{type, id, method, path, params, supersedePrevious}` — the
  ///   `id` doubles as the server-side `request_id` used by
  ///   `/lsp/cancel`, so no second id is needed.
  ///
  /// Reply shape sent back:
  ///   `{type: "lspResponse", id, result, error?}` — same `id` so
  ///   the JS pending-promise map can resolve.
  void _handleLspRequest(Map<String, dynamic> msg) {
    final id = msg['id'] as String?;
    final method = msg['method'] as String?;
    final path = (msg['path'] as String?) ?? widget.path;
    final params =
        (msg['params'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    // Daemon default is `supersede=true`; respect the flag when
    // Monaco explicitly disables it (references / rename).
    final supersede = msg['supersedePrevious'] != false;
    if (id == null || method == null) return;

    // Drop any stale token sitting under this id (shouldn't happen —
    // ids are unique — but defensive).
    _lspTokens.remove(id)?.cancel('reused id');
    final token = CancelToken();
    _lspTokens[id] = token;

    LspService()
        .request(
      path,
      method,
      params,
      requestId: id,
      supersedePrevious: supersede,
      cancelToken: token,
    )
        .then((result) {
      _lspTokens.remove(id);
      _send({
        'type': 'lspResponse',
        'id': id,
        'result': result,
      });
    }).catchError((Object e) {
      _lspTokens.remove(id);
      final cancelled =
          e is LspException && e.message.contains('cancelled');
      _send({
        'type': 'lspResponse',
        'id': id,
        'result': null,
        if (!cancelled) 'error': e.toString(),
        if (cancelled) 'cancelled': true,
      });
    });
  }

  /// Monaco fired `CancellationToken.onCancellationRequested` —
  /// drop the in-flight HTTP (daemon sees the disconnect and cancels
  /// the LSP task) and send an explicit `/lsp/cancel` as a second
  /// line of defence for when sockets are sticky or buffered.
  void _handleLspCancel(Map<String, dynamic> msg) {
    final id = msg['id'] as String?;
    if (id == null) return;
    final tok = _lspTokens.remove(id);
    if (tok != null && !tok.isCancelled) {
      tok.cancel('monaco cancel');
    }
    // Fire-and-forget: don't await — the provider already moved on.
    unawaited(LspService().cancel(id));
  }

  // ── Outbound helpers ───────────────────────────────────────────

  Future<void> _send(Map<String, dynamic> payload) async {
    if (!_ready) {
      debugPrint('Monaco._send SKIP (not ready) type=${payload['type']}');
      return;
    }
    final type = payload['type'];
    if (type == 'setModel') {
      final path = payload['path'];
      final content = payload['content'];
      debugPrint('Monaco._send setModel path=$path '
          'content=${content is String ? content.length : "?"}B');
    }
    final json = jsonEncode(payload);
    try {
      if (_winCtrl != null) {
        await _winCtrl!.postWebMessage(json);
      } else if (_mobileCtrl != null) {
        await _mobileCtrl!.runJavaScript(
          'window.hostMessage(${jsonEncode(json)});',
        );
      }
    } catch (e) {
      debugPrint('Monaco._send error type=$type: $e');
    }
  }

  void _pushModel() {
    final payload = {
      'type': 'setModel',
      'path': widget.path,
      'content': widget.content,
      'language':
          widget.language.isNotEmpty ? widget.language : _guess(widget.path),
      'readOnly': widget.readOnly,
    };
    _send(payload);
  }

  void _sendTheme() {
    final isDark = ThemeService().isDark;
    _send({'type': 'setTheme', 'theme': isDark ? 'dark' : 'light'});
  }

  /// Push the current LSP diagnostics for [widget.path] to Monaco as
  /// marker decorations. Always sends (even when empty) so markers
  /// from a previous revision are cleared the moment the fix lands.
  void _pushDiagnostics() {
    final entry = WorkspaceModule().diagnosticsFor(widget.path);
    final gen = entry?.generation ?? 0;
    // For the same (path, generation) avoid re-sending — the markers
    // don't change. Sending anyway would be harmless but noisy.
    if (gen == _lastDiagnosticsGeneration) return;
    _lastDiagnosticsGeneration = gen;
    _send({
      'type': 'setDiagnostics',
      'path': widget.path,
      'items':
          (entry?.items ?? const <Diagnostic>[]).map((d) => d.toMonacoJson()).toList(),
    });
  }

  /// If a new reveal target has landed on WorkspaceModule for our
  /// path, scroll Monaco to that line. Uses a one-shot request counter
  /// so repeat clicks on the same line still retrigger.
  void _maybeHandleReveal() {
    final ws = WorkspaceModule();
    if (ws.revealRequest == _lastRevealRequest) return;
    if (ws.revealPath != widget.path || ws.revealLine == null) return;
    _lastRevealRequest = ws.revealRequest;
    _send({
      'type': 'goToLine',
      'line': ws.revealLine,
      if (ws.revealColumn != null) 'column': ws.revealColumn,
    });
  }

  static String _guess(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'ts' || 'tsx' => 'typescript',
      'js' || 'jsx' || 'mjs' || 'cjs' => 'javascript',
      'py' => 'python',
      'dart' => 'dart',
      'json' => 'json',
      'yaml' || 'yml' => 'yaml',
      'md' || 'mdx' => 'markdown',
      _ => '',
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (!_canHostWebview) {
      return Container(
        color: c.bg,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.laptop_mac_rounded, size: 22, color: c.textMuted),
            const SizedBox(height: 10),
            Text(
              'Editor requires a desktop or mobile build.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                  fontSize: 12, color: c.textMuted),
            ),
          ],
        ),
      );
    }
    if (_initError) {
      return Container(
        color: c.bg,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded, size: 22, color: c.orange),
            const SizedBox(height: 10),
            Text(
              "Monaco failed to start. Check that Edge WebView2 is "
              'installed and restart the app.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                  fontSize: 12, color: c.textMuted),
            ),
          ],
        ),
      );
    }
    if (!_ready) {
      return Container(
        color: c.bg,
        alignment: Alignment.center,
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
              strokeWidth: 1.5, color: c.textMuted),
        ),
      );
    }
    if (_winCtrl != null) {
      return wv_win.Webview(_winCtrl!);
    }
    if (_mobileCtrl != null) {
      return wv_mobile.WebViewWidget(controller: _mobileCtrl!);
    }
    return const SizedBox.shrink();
  }
}
