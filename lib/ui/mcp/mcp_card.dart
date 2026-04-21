/// Reusable card for MCP entries — works for both the catalogue
/// (Discover) and the installed/running views. Same visual
/// language as `PackageCard` so the two stores feel consistent.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/mcp_server.dart';
import '../../theme/app_theme.dart';

class McpCard extends StatefulWidget {
  /// Either a catalogue entry (browseable, not installed) OR an
  /// installed server (with status + tools count). Exactly one of
  /// the two should be passed.
  final McpCatalogueEntry? entry;
  final McpServer? server;

  /// True when the corresponding catalogue entry is already
  /// installed (used by the Discover view to flip the action).
  final bool installed;

  final VoidCallback onTap;
  final VoidCallback? onInstall;
  final VoidCallback? onStart;
  final VoidCallback? onStop;
  final VoidCallback? onUninstall;
  final VoidCallback? onTest;

  const McpCard({
    super.key,
    this.entry,
    this.server,
    this.installed = false,
    required this.onTap,
    this.onInstall,
    this.onStart,
    this.onStop,
    this.onUninstall,
    this.onTest,
  }) : assert(entry != null || server != null,
            'McpCard needs an entry or a server');

  @override
  State<McpCard> createState() => _McpCardState();
}

class _McpCardState extends State<McpCard> {
  bool _h = false;

  String get _name => widget.entry?.label ?? widget.server?.name ?? '';
  String get _description =>
      widget.entry?.description ?? widget.server?.description ?? '';
  String get _author =>
      widget.entry?.author ?? widget.server?.author ?? '';
  String get _icon =>
      widget.entry?.icon ?? widget.server?.icon ?? '🔌';
  List<String> get _tags =>
      widget.entry?.tags ?? widget.server?.tags ?? const [];

  Color get _seedColor {
    final hash = _name.hashCode;
    return HSLColor.fromAHSL(1, (hash % 360).toDouble(), 0.55, 0.45)
        .toColor();
  }

  bool get _featured => widget.entry?.featured ?? false;
  int get _popularity => widget.entry?.popularity ?? 0;

  String? get _status {
    final s = widget.server?.status;
    if (s == null) return null;
    return s;
  }

  Color _statusTint(AppColors c, String status) {
    switch (status) {
      case 'running':
        return c.green;
      case 'starting':
        return c.blue;
      case 'error':
        return c.red;
      case 'installed':
      case 'stopped':
        return c.textMuted;
      default:
        return c.textMuted;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final status = _status;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          transform: Matrix4.identity()
            ..translateByDouble(0.0, _h ? -2.0 : 0.0, 0.0, 1.0),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _h ? c.borderHover : c.border,
              width: _h ? 1.4 : 1,
            ),
            boxShadow: _h
                ? [
                    BoxShadow(
                      color: _seedColor.withValues(alpha: 0.25),
                      blurRadius: 22,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : [],
          ),
          padding: const EdgeInsets.all(9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          _seedColor,
                          _seedColor.withValues(alpha: 0.65),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: _seedColor.withValues(alpha: 0.35),
                          blurRadius: 6,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: _iconChild(),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                _name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: c.textBright,
                                  letterSpacing: -0.2,
                                  height: 1.15,
                                ),
                              ),
                            ),
                            if (_featured) ...[
                              const SizedBox(width: 3),
                              Icon(Icons.star_rounded,
                                  size: 11,
                                  color: Colors.amber.shade600),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _author.isNotEmpty ? _author : 'unknown',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.firaCode(
                            fontSize: 9.5,
                            color: c.textMuted,
                            height: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Text(
                  _description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    color: c.text,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 3,
                runSpacing: 3,
                children: [
                  if (status != null)
                    _Tag(
                      label: status.toUpperCase(),
                      tint: _statusTint(c, status),
                    ),
                  if (widget.entry != null)
                    _Tag(
                      label: widget.entry!.transport.toUpperCase(),
                      tint: c.purple,
                    ),
                  if (widget.server != null && widget.server!.toolsCount > 0)
                    _Tag(
                      label: '${widget.server!.toolsCount} tools',
                      tint: c.cyan,
                    ),
                  for (final tag in _tags.take(2))
                    _Tag(label: tag, tint: c.textMuted),
                ],
              ),
              const SizedBox(height: 7),
              Row(
                children: [
                  if (_popularity > 0)
                    Row(
                      children: [
                        Icon(Icons.download_done_rounded,
                            size: 11, color: c.textMuted),
                        const SizedBox(width: 3),
                        Text(_formatPopularity(_popularity),
                            style: GoogleFonts.firaCode(
                                fontSize: 9.5,
                                color: c.textMuted,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  const Spacer(),
                  ..._buildActions(c),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconChild() {
    final raw = _icon.trim();
    final looksLikeEmoji = raw.isNotEmpty &&
        raw.length <= 4 &&
        !raw.contains('/') &&
        !raw.contains('.') &&
        !RegExp(r'^[A-Za-z0-9_\-]+$').hasMatch(raw);
    if (looksLikeEmoji) {
      return FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(raw,
            style: const TextStyle(fontSize: 24, height: 1)),
      );
    }
    final fallbackIcon =
        widget.entry?.fallbackIcon ?? Icons.electrical_services_rounded;
    return Icon(fallbackIcon, size: 22, color: Colors.white);
  }

  List<Widget> _buildActions(AppColors c) {
    // Installed server: Start / Stop / Test / Open detail
    if (widget.server != null) {
      final s = widget.server!;
      return [
        if (s.isRunning && widget.onStop != null)
          _OutlineBtn(
            label: 'Stop',
            icon: Icons.stop_rounded,
            tint: c.orange,
            onTap: widget.onStop!,
          )
        else if (widget.onStart != null)
          _PrimaryBtn(
            label: 'Start',
            icon: Icons.play_arrow_rounded,
            tint: c.green,
            onTap: widget.onStart!,
          ),
        if (widget.onTest != null) ...[
          const SizedBox(width: 6),
          _OutlineBtn(
            label: 'Test',
            icon: Icons.bolt_outlined,
            tint: c.blue,
            onTap: widget.onTest!,
          ),
        ],
      ];
    }
    // Catalogue entry: Install / Installed badge
    if (widget.installed) {
      return [
        _OutlineBtn(
          label: 'Installed',
          icon: Icons.check_rounded,
          tint: c.text,
          onTap: widget.onTap,
        ),
      ];
    }
    return [
      if (widget.onInstall != null)
        _PrimaryBtn(
          label: 'Install',
          icon: Icons.download_rounded,
          tint: c.blue,
          onTap: widget.onInstall!,
        ),
    ];
  }

  String _formatPopularity(int n) {
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}

class _Tag extends StatelessWidget {
  final String label;
  final Color tint;
  const _Tag({required this.label, required this.tint});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: GoogleFonts.firaCode(
          fontSize: 8.5,
          color: tint,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _PrimaryBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color tint;
  final VoidCallback onTap;
  const _PrimaryBtn({
    required this.label,
    required this.icon,
    required this.tint,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 13, color: Colors.white),
      label: Text(
        label,
        style: GoogleFonts.inter(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: Colors.white),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: tint,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: const Size(0, 30),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6)),
      ),
    );
  }
}

class _OutlineBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color tint;
  final VoidCallback onTap;
  const _OutlineBtn({
    required this.label,
    required this.icon,
    required this.tint,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 13, color: tint),
      label: Text(
        label,
        style: GoogleFonts.inter(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: tint),
      ),
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: c.border),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        minimumSize: const Size(0, 30),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6)),
      ),
    );
  }
}
