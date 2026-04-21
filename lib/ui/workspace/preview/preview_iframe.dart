/// Platform-abstracted "iframe" for the preview dev server.
///
/// Routes to the right WebView backend at runtime:
///   * Web        → ideally HtmlElementView with an <iframe> (stub
///                  for now, falls through to placeholder)
///   * Windows    → `webview_windows` (WebView2 / Edge Chromium)
///   * Android    → `webview_flutter` (Android WebView)
///   * iOS        → `webview_flutter` (WKWebView)
///   * macOS      → `webview_flutter` (WKWebView)
///   * Linux      → placeholder ("unsupported")
///
/// The caller bumps `epoch` to force a full remount when the URL
/// changes (see `PreviewWorkspaceProvider.reloadIframe()`).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:webview_flutter/webview_flutter.dart' as wvf;
import 'package:webview_windows/webview_windows.dart' as wvw;

import '../../../theme/app_theme.dart';

enum _Backend { windows, flutterWebview, web, unsupported }

_Backend _pickBackend() {
  if (kIsWeb) return _Backend.web;
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
      return _Backend.windows;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return _Backend.flutterWebview;
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return _Backend.unsupported;
  }
}

class PreviewIframe extends StatefulWidget {
  final String url;
  final int epoch;
  const PreviewIframe({
    super.key,
    required this.url,
    required this.epoch,
  });

  @override
  State<PreviewIframe> createState() => _PreviewIframeState();
}

class _PreviewIframeState extends State<PreviewIframe> {
  late final _Backend _backend;

  wvw.WebviewController? _wvwController;
  wvf.WebViewController? _wvfController;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _backend = _pickBackend();
    _init();
  }

  Future<void> _init() async {
    try {
      switch (_backend) {
        case _Backend.windows:
          final ctrl = wvw.WebviewController();
          await ctrl.initialize();
          await ctrl.loadUrl(widget.url);
          _wvwController = ctrl;
          break;
        case _Backend.flutterWebview:
          final ctrl = wvf.WebViewController()
            ..setJavaScriptMode(wvf.JavaScriptMode.unrestricted)
            ..setBackgroundColor(const Color(0x00000000))
            ..loadRequest(Uri.parse(widget.url));
          _wvfController = ctrl;
          break;
        case _Backend.web:
        case _Backend.unsupported:
          break;
      }
      if (!mounted) return;
      setState(() => _ready = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  void didUpdateWidget(covariant PreviewIframe old) {
    super.didUpdateWidget(old);
    if (old.url == widget.url && old.epoch == widget.epoch) return;
    if (!_ready) return;
    try {
      switch (_backend) {
        case _Backend.windows:
          _wvwController?.loadUrl(widget.url);
          break;
        case _Backend.flutterWebview:
          _wvfController?.loadRequest(Uri.parse(widget.url));
          break;
        case _Backend.web:
        case _Backend.unsupported:
          break;
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    try {
      _wvwController?.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (_backend == _Backend.unsupported || _backend == _Backend.web) {
      return _unsupported(c);
    }
    if (_error != null) {
      return Container(
        color: c.bg,
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'WebView init failed:\n$_error',
            textAlign: TextAlign.center,
            style: GoogleFonts.firaCode(fontSize: 11, color: c.red),
          ),
        ),
      );
    }
    if (!_ready) {
      return Container(
        color: c.bg,
        alignment: Alignment.center,
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2, color: c.blue),
        ),
      );
    }
    switch (_backend) {
      case _Backend.windows:
        return wvw.Webview(_wvwController!);
      case _Backend.flutterWebview:
        return wvf.WebViewWidget(controller: _wvfController!);
      case _Backend.web:
      case _Backend.unsupported:
        return _unsupported(c);
    }
  }

  Widget _unsupported(AppColors c) => Container(
        color: c.bg,
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.desktop_access_disabled_rounded,
                  size: 42, color: c.orange),
              const SizedBox(height: 14),
              Text(
                'Preview unavailable on this platform',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: c.textBright,
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: 320,
                child: Text(
                  'The embedded dev-server preview runs on Windows, '
                  'macOS, Android and iOS. Web and Linux fall back to '
                  'opening the preview URL in the system browser.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                      fontSize: 11.5, color: c.textMuted, height: 1.5),
                ),
              ),
            ],
          ),
        ),
      );
}
