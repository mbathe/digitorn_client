/// Minimal asset browser for a deployed app's bundle. Lists the
/// files inside each of the bundle's well-known sub-directories
/// (`prompts/`, `skills/`, `assets/`, `fragments/`) and lets the
/// user open one to see its raw bytes / text content. Reserved
/// for future in-app editor workflows — nothing heavy, just a
/// read-only inspector so the user can verify what the daemon
/// compiled.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/assets_service.dart';
import '../../theme/app_theme.dart';

Future<void> showAssetBrowser(
  BuildContext context, {
  required String appId,
  required String appName,
}) {
  return showDialog(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (_) =>
        _AssetBrowserDialog(appId: appId, appName: appName),
  );
}

class _AssetBrowserDialog extends StatefulWidget {
  final String appId;
  final String appName;
  const _AssetBrowserDialog({
    required this.appId,
    required this.appName,
  });

  @override
  State<_AssetBrowserDialog> createState() => _AssetBrowserDialogState();
}

class _AssetBrowserDialogState extends State<_AssetBrowserDialog>
    with SingleTickerProviderStateMixin {
  static const _subdirs = ['prompts', 'skills', 'assets', 'fragments'];
  late final TabController _tabs =
      TabController(length: _subdirs.length, vsync: this);
  final _svc = AssetsService();
  final Map<String, List<BundleFile>> _files = {};
  final Map<String, bool> _loading = {};

  @override
  void initState() {
    super.initState();
    for (final s in _subdirs) {
      _loadFolder(s);
    }
  }

  Future<void> _loadFolder(String subdir) async {
    setState(() => _loading[subdir] = true);
    final list =
        await _svc.listAppFiles(widget.appId, subdir: subdir);
    if (!mounted) return;
    setState(() {
      _files[subdir] = list;
      _loading[subdir] = false;
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 680),
        child: Container(
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: c.border),
          ),
          child: Column(
            children: [
              _buildHeader(c),
              Divider(height: 1, color: c.border),
              TabBar(
                controller: _tabs,
                isScrollable: true,
                indicatorColor: c.blue,
                indicatorWeight: 2,
                labelColor: c.blue,
                unselectedLabelColor: c.textMuted,
                labelStyle: GoogleFonts.firaCode(
                    fontSize: 11, fontWeight: FontWeight.w700),
                tabs: [
                  for (final s in _subdirs) Tab(text: s.toUpperCase()),
                ],
              ),
              Divider(height: 1, color: c.border),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    for (final s in _subdirs) _buildList(c, s),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(AppColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 14),
      child: Row(
        children: [
          Icon(Icons.folder_outlined, size: 18, color: c.blue),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Bundle · ${widget.appName}',
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: c.textBright,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.appId,
                  style: GoogleFonts.firaCode(
                      fontSize: 10.5, color: c.textMuted),
                ),
              ],
            ),
          ),
          IconButton(
            iconSize: 16,
            icon: Icon(Icons.close_rounded, color: c.textMuted),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _buildList(AppColors c, String subdir) {
    if (_loading[subdir] ?? true) {
      return Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
              strokeWidth: 1.5, color: c.textMuted),
        ),
      );
    }
    final files = _files[subdir] ?? const [];
    if (files.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(30),
          child: Text(
            'No files in $subdir/',
            style: GoogleFonts.firaCode(fontSize: 11, color: c.textMuted),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: files.length,
      separatorBuilder: (_, _) => Divider(height: 1, color: c.border),
      itemBuilder: (_, i) {
        final f = files[i];
        return ListTile(
          dense: true,
          leading: Icon(
            _iconFor(f.name),
            size: 16,
            color: c.textMuted,
          ),
          title: Text(
            f.name,
            style: GoogleFonts.firaCode(
                fontSize: 12, color: c.textBright),
          ),
          subtitle: Text(
            '${_humanSize(f.size)}${f.contentType != null ? " · ${f.contentType}" : ""}',
            style: GoogleFonts.firaCode(fontSize: 9.5, color: c.textMuted),
          ),
          trailing: Icon(Icons.chevron_right_rounded,
              size: 14, color: c.textDim),
          onTap: () => _openFile(subdir, f),
        );
      },
    );
  }

  Future<void> _openFile(String subdir, BundleFile file) async {
    final bytes =
        await _svc.fetchAppAsset(widget.appId, '$subdir/${file.path}');
    if (!mounted || bytes == null) return;
    // Try decoding as utf8 — works for prompts/skills/fragments.
    // Binary assets (images) get a "binary (X KB)" placeholder.
    String content;
    try {
      content = utf8.decode(bytes);
    } catch (_) {
      content = '<binary · ${_humanSize(bytes.length)}>';
    }
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (_) => _FilePreviewDialog(
        path: '$subdir/${file.path}',
        content: content,
      ),
    );
  }

  IconData _iconFor(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.md')) return Icons.description_outlined;
    if (lower.endsWith('.yaml') || lower.endsWith('.yml')) {
      return Icons.data_object_rounded;
    }
    if (lower.endsWith('.png') || lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') || lower.endsWith('.svg')) {
      return Icons.image_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  String _humanSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
}

class _FilePreviewDialog extends StatelessWidget {
  final String path;
  final String content;
  const _FilePreviewDialog({required this.path, required this.content});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780, maxHeight: 640),
        child: Container(
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.border),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 12, 12),
                child: Row(
                  children: [
                    Icon(Icons.code_rounded, size: 14, color: c.blue),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        path,
                        style: GoogleFonts.firaCode(
                          fontSize: 12,
                          color: c.textBright,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      iconSize: 14,
                      icon: Icon(Icons.close_rounded, color: c.textMuted),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: c.border),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(18),
                  child: SelectableText(
                    content,
                    style: GoogleFonts.firaCode(
                        fontSize: 11.5, color: c.text, height: 1.55),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
