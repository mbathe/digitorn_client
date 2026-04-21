import 'dart:io' as io;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../theme/app_theme.dart';
import 'file_viewer.dart';

/// Renders raster + SVG image files. Uses [Image.network] on web
/// (the daemon serves files over HTTP) and [Image.file] on desktop.
class ImageFileViewer extends FileViewer {
  const ImageFileViewer();

  @override
  String get id => 'image';

  @override
  int get priority => 50;

  @override
  Set<String> get extensions => const {
        'png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp', 'svg', 'ico',
      };

  @override
  Widget build(BuildContext context, ViewerContext vctx) {
    return _ImagePreview(
      path: vctx.buffer.path,
      filename: vctx.buffer.filename,
    );
  }
}

class _ImagePreview extends StatelessWidget {
  final String path;
  final String filename;
  const _ImagePreview({required this.path, required this.filename});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: c.surface,
          child: Row(
            children: [
              Icon(Icons.image_outlined, size: 14, color: c.textMuted),
              const SizedBox(width: 8),
              Text(filename,
                  style: GoogleFonts.firaCode(fontSize: 12, color: c.text)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: c.border,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text('IMAGE',
                    style:
                        GoogleFonts.firaCode(fontSize: 9, color: c.textMuted)),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: c.bg,
            padding: const EdgeInsets.all(16),
            child: Center(
              child: kIsWeb
                  ? Image.network(
                      path,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => _imageError(context),
                    )
                  : Image.file(
                      io.File(path),
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => _imageError(context),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _imageError(BuildContext context) {
    final c = context.colors;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.broken_image_outlined, size: 48, color: c.textMuted),
        const SizedBox(height: 12),
        Text('Cannot load image',
            style: TextStyle(color: c.textMuted, fontSize: 13)),
      ],
    );
  }
}
