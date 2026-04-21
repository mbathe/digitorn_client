/// Authenticated remote-icon loader. Fetches `/api/apps/{id}/icon`
/// (or `/api/packages/{id}/icon`) using the current bearer token,
/// caches the bytes in memory, and falls back to the provided
/// emoji / initial when the daemon returns 404.
///
/// Used by every store / sidebar / chat header that needs to show
/// the official icon of an installed app or package.
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';

enum RemoteIconKind { app, package }

class RemoteIcon extends StatefulWidget {
  final String id;
  final RemoteIconKind kind;
  final double size;
  final double borderRadius;

  /// Emoji shown while loading or when no remote icon is available.
  final String? emojiFallback;

  /// First-letter fallback when [emojiFallback] is null too.
  final String? nameFallback;

  /// Background gradient used by the fallback. When null we derive
  /// a colour from a hash of [id] so each app has a stable look.
  final List<Color>? gradient;

  /// When true, drop every background decoration (gradient, fill,
  /// shadow, border-radius clip) so the widget just renders the
  /// raw image OR the bare emoji / initial without any chrome.
  /// This is now the default — official brand icons already carry
  /// their own visual identity, the extra gradient box was noise.
  /// Callers that WANT the gradient chrome (e.g. the old hash-
  /// colour placeholders) opt in via `transparent: false`.
  final bool transparent;

  const RemoteIcon({
    super.key,
    required this.id,
    required this.kind,
    this.size = 48,
    this.borderRadius = 12,
    this.emojiFallback,
    this.nameFallback,
    this.gradient,
    this.transparent = true,
  });

  @override
  State<RemoteIcon> createState() => _RemoteIconState();
}

class _RemoteIconState extends State<RemoteIcon> {
  static final _RemoteIconCache _cache = _RemoteIconCache();
  static final Dio _dio = Dio(BaseOptions(
    receiveTimeout: const Duration(seconds: 10),
    validateStatus: (s) => s != null && s < 500 && s != 401,
  ));

  Uint8List? _bytes;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant RemoteIcon old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id || old.kind != widget.kind) {
      _load();
    }
  }

  Future<void> _load() async {
    final cacheKey = '${widget.kind.name}:${widget.id}';
    final cached = _cache.get(cacheKey);
    if (cached != null) {
      setState(() {
        _bytes = cached;
        _loading = false;
        });
      return;
    }
    if (_cache.isMissing(cacheKey)) {
      setState(() {
        _loading = false;
        });
      return;
    }
    setState(() {
      _loading = true;
    });
    try {
      final base = AuthService().baseUrl;
      final path = widget.kind == RemoteIconKind.app
          ? '/api/apps/${widget.id}/icon'
          : '/api/packages/${widget.id}/icon';
      final r = await _dio.get<List<int>>(
        '$base$path',
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            ...AuthService().authImageHeaders,
            'Accept': 'image/*',
          },
        ),
      );
      if (r.statusCode == 200 && r.data != null && r.data!.isNotEmpty) {
        final bytes = Uint8List.fromList(r.data!);
        _cache.put(cacheKey, bytes);
        if (!mounted) return;
        setState(() {
          _bytes = bytes;
          _loading = false;
            });
        return;
      }
      _cache.markMissing(cacheKey);
      if (!mounted) return;
      setState(() {
        _loading = false;
        });
    } catch (_) {
      _cache.markMissing(cacheKey);
      if (!mounted) return;
      setState(() {
        _loading = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hash = widget.id.hashCode;
    final auto = [
      HSLColor.fromAHSL(1, (hash % 360).toDouble(), 0.55, 0.5).toColor(),
      HSLColor.fromAHSL(1, ((hash ~/ 7) % 360).toDouble(), 0.55, 0.4)
          .toColor(),
    ];
    final colors = widget.gradient ?? auto;

    // Transparent variant: no fill, no gradient, no shadow, no
    // background — just the raw image or bare emoji on the page
    // background. Used by the dashboard's quick-launch chips.
    if (widget.transparent) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: _buildChild(c),
      );
    }

    final box = Container(
      width: widget.size,
      height: widget.size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: _bytes == null
            ? LinearGradient(
                colors: colors,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: _bytes != null ? c.surfaceAlt : null,
        borderRadius: BorderRadius.circular(widget.borderRadius),
        boxShadow: _bytes == null
            ? [
                BoxShadow(
                  color: colors.first.withValues(alpha: 0.3),
                  blurRadius: widget.size * 0.15,
                  offset: Offset(0, widget.size * 0.06),
                ),
              ]
            : null,
      ),
      clipBehavior: _bytes != null ? Clip.antiAlias : Clip.none,
      child: _buildChild(c),
    );
    return box;
  }

  Widget _buildChild(AppColors c) {
    if (_bytes != null) {
      return Image.memory(_bytes!, fit: BoxFit.cover);
    }
    if (_loading) {
      // Subtle white spinner that fades into the gradient — keeps
      // the box from looking empty during the brief fetch.
      return SizedBox(
        width: widget.size * 0.32,
        height: widget.size * 0.32,
        child: const CircularProgressIndicator(
          strokeWidth: 1.5,
          color: Colors.white60,
        ),
      );
    }
    final emoji = widget.emojiFallback?.trim() ?? '';
    if (_isEmoji(emoji)) {
      return FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          emoji,
          style: TextStyle(
            fontSize: widget.size * 0.55,
            height: 1,
          ),
        ),
      );
    }
    final initial = (widget.nameFallback?.trim().isNotEmpty == true
            ? widget.nameFallback!.trim()[0]
            : '?')
        .toUpperCase();
    // Transparent variant uses the page foreground colour instead
    // of white-on-gradient so the initial is readable on any
    // theme background.
    if (widget.transparent) {
      return Text(
        initial,
        style: GoogleFonts.inter(
          fontSize: widget.size * 0.5,
          fontWeight: FontWeight.w800,
          color: c.textBright,
          height: 1,
          letterSpacing: -0.5,
        ),
      );
    }
    return Text(
      initial,
      style: GoogleFonts.inter(
        fontSize: widget.size * 0.5,
        fontWeight: FontWeight.w800,
        color: Colors.white,
        height: 1,
        letterSpacing: -0.5,
        shadows: [
          Shadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 6,
            offset: const Offset(0, 1),
          ),
        ],
      ),
    );
  }

  static bool _isEmoji(String s) {
    if (s.isEmpty) return false;
    if (s.length > 4) return false;
    if (s.contains('/') || s.contains('.')) return false;
    if (RegExp(r'^[A-Za-z0-9_\-]+$').hasMatch(s)) return false;
    return true;
  }
}

class _RemoteIconCache {
  final Map<String, Uint8List> _bytes = {};
  final Set<String> _missing = {};

  Uint8List? get(String key) => _bytes[key];
  bool isMissing(String key) => _missing.contains(key);

  void put(String key, Uint8List bytes) {
    _bytes[key] = bytes;
    _missing.remove(key);
  }

  void markMissing(String key) {
    _missing.add(key);
  }
}
