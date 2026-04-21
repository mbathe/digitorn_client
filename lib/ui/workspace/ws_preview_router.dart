import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../../services/workspace_module.dart';
import '../../services/auth_service.dart';
import '../../services/preview_availability_service.dart';
import '../../services/session_service.dart';
import '../../main.dart';
import '../../theme/app_theme.dart';
import 'canvas/canvas_registry.dart';
import 'ide/monaco_editor_pane.dart';
import 'preview/preview_iframe.dart';

class WsPreviewRouter extends StatelessWidget {
  const WsPreviewRouter({super.key});

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WorkspaceModule>();
    final c = context.colors;

    if (!ws.hasMeta && !ws.hasFiles) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.visibility_rounded, size: 32, color: c.textDim),
            const SizedBox(height: 12),
            Text('Preview will appear here',
                style: GoogleFonts.inter(color: c.textDim, fontSize: 13)),
            const SizedBox(height: 4),
            Text('when the agent starts writing files',
                style: GoogleFonts.inter(color: c.textDim, fontSize: 11)),
          ],
        ),
      );
    }

    // Built-in renderers handle `react` (iframe to Vite dev server),
    // `html` (inline HTML assembly), `markdown`, `slides`, `code`.
    // Everything else — including `builder` and any future derived-
    // graph modes — is dispatched through `CanvasRegistry`, letting
    // apps plug in custom client-side renderers without forking this
    // file. Code preview remains the final fallback.
    final mode = ws.meta.renderMode;
    return switch (mode) {
      'react' => _ReactPreview(ws: ws),
      'html' => _HtmlPreview(ws: ws),
      'markdown' => _MarkdownPreview(ws: ws),
      'slides' => _SlidesPreview(ws: ws),
      'code' => _CodePreview(ws: ws),
      _ => _resolveCanvas(context, mode, ws),
    };
  }

  Widget _resolveCanvas(
      BuildContext context, String mode, WorkspaceModule ws) {
    final canvas = CanvasRegistry.resolve(mode);
    if (canvas != null) return canvas(context);
    return _CodePreview(ws: ws);
  }
}

// ── React — WebView loads the preview server ─────────────────────────────────

class _ReactPreview extends StatefulWidget {
  final WorkspaceModule ws;
  const _ReactPreview({required this.ws});

  @override
  State<_ReactPreview> createState() => _ReactPreviewState();
}

class _ReactPreviewState extends State<_ReactPreview> {
  // Manual listener — the earlier `ListenableBuilder` variant caused
  // re-entrant retakes of inactive Elements during the layout swap
  // (framework asserts at 2168/4735). A plain addListener +
  // microtask-deferred setState keeps the pane swap strictly in a
  // single frame without any ListenableBuilder stack in between.
  @override
  void initState() {
    super.initState();
    PreviewAvailabilityService().addListener(_onChanged);
  }

  @override
  void dispose() {
    PreviewAvailabilityService().removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    scheduleMicrotask(() {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final appId = context.read<AppState>().activeApp?.appId ?? '';
    final available = PreviewAvailabilityService().isAvailable(appId);
    if (available == null) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (!available) return const _PreviewUnavailable();

    final sessionId = SessionService().activeSession?.sessionId ?? '';
    final base = AuthService().baseUrl;
    final token = AuthService().accessToken ?? '';
    final url = '$base/api/apps/$appId/preview/'
        '?session_id=$sessionId&token=$token';

    return PreviewIframe(url: url, epoch: 0);
  }
}

class _PreviewUnavailable extends StatelessWidget {
  const _PreviewUnavailable();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.visibility_off_rounded, size: 28, color: c.textDim),
          const SizedBox(height: 10),
          Text('No preview for this app',
              style: GoogleFonts.inter(color: c.textDim, fontSize: 12)),
        ],
      ),
    );
  }
}

// ── HTML — inject HTML from files ────────────────────────────────────────────

class _HtmlPreview extends StatelessWidget {
  final WorkspaceModule ws;
  const _HtmlPreview({required this.ws});

  @override
  Widget build(BuildContext context) {
    final entry = ws.entryFile;
    if (entry == null) {
      return const Center(child: Text('No entry file'));
    }

    // Build a complete HTML document inlining CSS/JS from other files.
    var html = entry.content;

    for (final f in ws.files.values) {
      if (f.extension == 'css') {
        html = html.replaceFirst(
          '</head>',
          '<style>${f.content}</style></head>',
        );
      }
    }
    for (final f in ws.files.values) {
      if (f.extension == 'js' || f.extension == 'mjs') {
        html = html.replaceFirst(
          '</body>',
          '<script>${f.content}</script></body>',
        );
      }
    }

    final dataUrl =
        'data:text/html;base64,${base64Encode(utf8.encode(html))}';
    return PreviewIframe(url: dataUrl, epoch: html.hashCode);
  }
}

// ── Markdown — native Flutter rendering ──────────────────────────────────────

class _MarkdownPreview extends StatelessWidget {
  final WorkspaceModule ws;
  const _MarkdownPreview({required this.ws});

  @override
  Widget build(BuildContext context) {
    final entry = ws.entryFile;
    if (entry == null) {
      return const Center(child: Text('No entry file'));
    }

    return Markdown(
      data: entry.content,
      selectable: true,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        codeblockDecoration: BoxDecoration(
          color: context.colors.surfaceAlt,
          borderRadius: BorderRadius.circular(6),
        ),
        code: GoogleFonts.firaCode(fontSize: 12),
      ),
    );
  }
}

// ── Slides — PageView with Markdown per slide ────────────────────────────────

class _SlidesPreview extends StatefulWidget {
  final WorkspaceModule ws;
  const _SlidesPreview({required this.ws});

  @override
  State<_SlidesPreview> createState() => _SlidesPreviewState();
}

class _SlidesPreviewState extends State<_SlidesPreview> {
  int _currentSlide = 0;
  late PageController _pageCtrl;

  @override
  void initState() {
    super.initState();
    _pageCtrl = PageController();
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  List<WorkspaceFile> get _slides {
    return widget.ws.files.entries
        .where((e) => e.key.startsWith('slides/') || e.key.contains('/slides/'))
        .map((e) => e.value)
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  @override
  Widget build(BuildContext context) {
    final slides = _slides;
    final c = context.colors;

    if (slides.isEmpty) {
      return const Center(child: Text('No slides found'));
    }

    return Column(
      children: [
        // Slide counter
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left_rounded),
                onPressed: _currentSlide > 0
                    ? () {
                        _pageCtrl.previousPage(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut);
                      }
                    : null,
                iconSize: 20,
              ),
              Text('${_currentSlide + 1} / ${slides.length}',
                  style: GoogleFonts.inter(
                      fontSize: 12, color: c.textMuted, fontWeight: FontWeight.w600)),
              IconButton(
                icon: const Icon(Icons.chevron_right_rounded),
                onPressed: _currentSlide < slides.length - 1
                    ? () {
                        _pageCtrl.nextPage(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut);
                      }
                    : null,
                iconSize: 20,
              ),
            ],
          ),
        ),
        // Slides
        Expanded(
          child: PageView.builder(
            controller: _pageCtrl,
            itemCount: slides.length,
            onPageChanged: (i) => setState(() => _currentSlide = i),
            itemBuilder: (context, i) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Markdown(
                  data: slides[i].content,
                  selectable: true,
                  styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                      .copyWith(
                    h1: GoogleFonts.inter(
                        fontSize: 28, fontWeight: FontWeight.w700),
                    h2: GoogleFonts.inter(
                        fontSize: 22, fontWeight: FontWeight.w600),
                    code: GoogleFonts.firaCode(fontSize: 12),
                  ),
                ),
              );
            },
          ),
        ),
        // Dots
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(slides.length, (i) {
              return Container(
                width: 6, height: 6,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i == _currentSlide ? c.blue : c.textDim,
                ),
              );
            }),
          ),
        ),
      ],
    );
  }
}

// ── Code — syntax highlighted view ───────────────────────────────────────────

class _CodePreview extends StatelessWidget {
  final WorkspaceModule ws;
  const _CodePreview({required this.ws});

  @override
  Widget build(BuildContext context) {
    final entry = ws.entryFile;
    if (entry == null) {
      return const Center(child: Text('No file to display'));
    }

    return MonacoEditorPane(
      path: entry.path,
      content: entry.content,
      readOnly: true,
    );
  }
}
