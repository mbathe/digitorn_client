/// Digitorn Widgets v1 — `type: html` primitive.
///
/// Escape hatch for the 5% of use cases where a declarative tree
/// isn't enough. Same cross-platform routing story as the preview
/// iframe: `webview_windows` on Windows, `webview_flutter` on
/// mobile/macOS, placeholder on Linux/Web.
///
/// Accepts either:
///   * `src:` — a fully-qualified URL (http[s]:)
///   * `html:` — an inline HTML string, wrapped in a data: URL
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:webview_flutter/webview_flutter.dart' as wvf;
import 'package:webview_windows/webview_windows.dart' as wvw;

import '../../theme/app_theme.dart';
import '../bindings.dart';
import '../models.dart';
import '../runtime.dart';

enum _Backend { windows, flutterWebview, unsupported }

_Backend _pickBackend() {
  if (kIsWeb) return _Backend.unsupported;
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
      return _Backend.windows;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return _Backend.flutterWebview;
    default:
      return _Backend.unsupported;
  }
}

Widget buildHtml(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return _HtmlStateful(node: node, runtime: runtime, extra: extra);
}

class _HtmlStateful extends StatefulWidget {
  final WidgetNode node;
  final WidgetRuntime runtime;
  final Map<String, dynamic>? extra;
  const _HtmlStateful({
    required this.node,
    required this.runtime,
    this.extra,
  });

  @override
  State<_HtmlStateful> createState() => _HtmlStatefulState();
}

class _HtmlStatefulState extends State<_HtmlStateful> {
  late final _Backend _backend;
  wvw.WebviewController? _wvwController;
  wvf.WebViewController? _wvfController;
  bool _ready = false;
  String? _error;
  String _lastUrl = '';

  String _resolveSource() {
    final scope = widget.runtime.state.buildScope(extra: widget.extra);
    final src = widget.node.props['src'] as String?;
    if (src != null && src.isNotEmpty) {
      return evalTemplate(src, scope);
    }
    final inline = widget.node.props['html'] as String?;
    if (inline != null && inline.isNotEmpty) {
      final rendered = evalTemplate(inline, scope);
      final encoded = base64Encode(utf8.encode(rendered));
      return 'data:text/html;base64,$encoded';
    }
    return '';
  }

  @override
  void initState() {
    super.initState();
    _backend = _pickBackend();
    if (_backend != _Backend.unsupported) _init();
  }

  Future<void> _init() async {
    try {
      final url = _resolveSource();
      _lastUrl = url;
      switch (_backend) {
        case _Backend.windows:
          final ctrl = wvw.WebviewController();
          await ctrl.initialize();
          if (url.isNotEmpty) await ctrl.loadUrl(url);
          _wvwController = ctrl;
          break;
        case _Backend.flutterWebview:
          final ctrl = wvf.WebViewController()
            ..setJavaScriptMode(wvf.JavaScriptMode.unrestricted)
            ..setBackgroundColor(const Color(0x00000000));
          if (url.isNotEmpty) {
            await ctrl.loadRequest(Uri.parse(url));
          }
          _wvfController = ctrl;
          break;
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
  void didUpdateWidget(covariant _HtmlStateful old) {
    super.didUpdateWidget(old);
    if (!_ready) return;
    final next = _resolveSource();
    if (next == _lastUrl || next.isEmpty) return;
    _lastUrl = next;
    try {
      switch (_backend) {
        case _Backend.windows:
          _wvwController?.loadUrl(next);
          break;
        case _Backend.flutterWebview:
          _wvfController?.loadRequest(Uri.parse(next));
          break;
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
    final height = asDouble(widget.node.props['height']) ?? 360;
    final radius = asDouble(widget.node.props['radius']) ?? 8;

    Widget body;
    if (_backend == _Backend.unsupported) {
      body = _placeholder(c, 'HTML embed unavailable on this platform');
    } else if (_error != null) {
      body = Container(
        color: c.bg,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        child: Text(
          'HTML init failed:\n$_error',
          textAlign: TextAlign.center,
          style: GoogleFonts.firaCode(fontSize: 11, color: c.red),
        ),
      );
    } else if (!_ready) {
      body = Container(
        color: c.bg,
        alignment: Alignment.center,
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: c.blue,
          ),
        ),
      );
    } else {
      switch (_backend) {
        case _Backend.windows:
          body = wvw.Webview(_wvwController!);
          break;
        case _Backend.flutterWebview:
          body = wvf.WebViewWidget(controller: _wvfController!);
          break;
        case _Backend.unsupported:
          body = _placeholder(c, 'HTML embed unavailable');
      }
    }

    return SizedBox(
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: c.border),
            borderRadius: BorderRadius.circular(radius),
          ),
          child: body,
        ),
      ),
    );
  }

  Widget _placeholder(AppColors c, String message) {
    return Container(
      color: c.surfaceAlt,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.public_off_rounded, size: 30, color: c.textMuted),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(fontSize: 12, color: c.textMuted),
          ),
        ],
      ),
    );
  }
}
