import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import '../../services/background_app_service.dart';
import '../../services/workspace_service.dart';
import '../../theme/app_theme.dart';
import '../workspace/viewers/file_viewer.dart';
import '../workspace/viewers/viewer_registry.dart';

/// Full-screen preview for a downloaded [ArtifactDownload].
///
/// Dispatches to the right viewer based on the filename extension:
/// - `.pdf`  → [SfPdfViewer.memory]
/// - `.png/.jpg/.jpeg/.gif/.bmp/.webp` → [Image.memory]
/// - Any other text-decodable content → wrap in a synthetic
///   [WorkbenchBuffer] and hand off to the [ViewerRegistry] so every
///   code/markdown/csv/json/yaml/toml/xml/notebook/log viewer we've
///   already built works out of the box.
/// - Unknown binary → "Save to disk" fallback.
class ArtifactPreviewPage extends StatelessWidget {
  final ArtifactDownload download;
  const ArtifactPreviewPage({super.key, required this.download});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.surface,
        elevation: 0,
        foregroundColor: c.text,
        title: Text(
          download.filename,
          style: GoogleFonts.firaCode(
              fontSize: 13,
              color: c.text,
              fontWeight: FontWeight.w500),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: Text(
                _sizeLabel(download.bytes.length),
                style: GoogleFonts.firaCode(
                    fontSize: 10, color: c.textMuted),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Copy as text',
            icon: Icon(Icons.copy_rounded, size: 16, color: c.textMuted),
            onPressed: () => _copyAsText(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final ext = _extensionOf(download.filename);
    final bytes = download.bytes;

    // PDF — dedicated viewer, binary.
    if (ext == 'pdf' || download.contentType.contains('application/pdf')) {
      return Container(
        color: context.colors.bg,
        child: SfPdfViewer.memory(
          bytes,
          canShowScrollHead: true,
          canShowScrollStatus: false,
          enableTextSelection: true,
        ),
      );
    }

    // Images — raster formats.
    const imageExts = {'png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp'};
    if (imageExts.contains(ext) ||
        download.contentType.startsWith('image/')) {
      return Container(
        color: context.colors.bg,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        child: InteractiveViewer(
          child: Image.memory(
            bytes,
            errorBuilder: (_, _, _) =>
                _errorState(context, 'Cannot render image'),
          ),
        ),
      );
    }

    // Text-decodable content → use the existing ViewerRegistry.
    String? text;
    try {
      text = utf8.decode(bytes, allowMalformed: false);
    } catch (_) {
      text = null;
    }
    if (text != null) {
      final buffer = WorkbenchBuffer(
        path: download.filename,
        type: 'text',
        content: text,
        previousContent: '',
        lines: text.split('\n').length,
        chars: text.length,
      );
      final viewer = ViewerRegistry.resolve(buffer);
      return _ArtifactTextHost(
        buffer: buffer,
        viewer: viewer,
      );
    }

    // Unknown binary — offer save-to-disk actions.
    return _BinaryFallback(download: download);
  }

  static String _extensionOf(String name) {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1).toLowerCase();
  }

  static String _sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  Future<void> _copyAsText(BuildContext context) async {
    try {
      final text = utf8.decode(download.bytes);
      await Clipboard.setData(ClipboardData(text: text));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Copied to clipboard'),
        duration: Duration(seconds: 2),
      ));
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Cannot copy — binary content'),
        duration: Duration(seconds: 2),
      ));
    }
  }

  static Widget _errorState(BuildContext context, String msg) {
    final c = context.colors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_rounded, size: 32, color: c.textMuted),
          const SizedBox(height: 8),
          Text(msg,
              style: GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
        ],
      ),
    );
  }
}

/// Hosts a text-based [ViewerRegistry] viewer inside the full-screen
/// preview route. The viewer writes via [ViewerContext], same as
/// inside the workspace panel — it just doesn't have a reveal target
/// or diagnostics here.
class _ArtifactTextHost extends StatelessWidget {
  final WorkbenchBuffer buffer;
  final FileViewer viewer;
  const _ArtifactTextHost({required this.buffer, required this.viewer});

  @override
  Widget build(BuildContext context) {
    final vctx = ViewerContext(
      buffer: buffer,
      diagnostics: const [],
      revealTarget: null,
      onRevealConsumed: null,
      ws: WorkspaceService(),
    );
    return viewer.build(context, vctx);
  }
}

class _BinaryFallback extends StatelessWidget {
  final ArtifactDownload download;
  const _BinaryFallback({required this.download});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final bytes = download.bytes;
    // Show a small hex preview + metadata so the user at least has
    // *something* to look at when we can't render the content.
    final preview = bytes.take(256).toList();
    final hex = preview
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.description_outlined,
                      size: 18, color: c.textMuted),
                  const SizedBox(width: 8),
                  Text('Binary file',
                      style: GoogleFonts.inter(
                          fontSize: 13,
                          color: c.textBright,
                          fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'No built-in viewer for "${download.contentType}". '
                'Here are the first 256 bytes:',
                style: GoogleFonts.inter(
                    fontSize: 12, color: c.textMuted, height: 1.5),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: c.border),
                ),
                child: SelectableText(
                  hex,
                  style: GoogleFonts.firaCode(
                      fontSize: 10.5,
                      color: c.text,
                      height: 1.55),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
