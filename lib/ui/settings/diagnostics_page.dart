/// Diagnostics dashboard — probes every service the client talks to
/// and reports health, latency, and last error per service. Used to
/// debug production issues without opening devtools.
///
/// Probes run in parallel on enter and on every Refresh tap. Nothing
/// mutates server state — all calls are idempotent GETs.
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';

class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  List<_Probe> _probes = const [];
  bool _running = false;
  DateTime? _lastRunAt;

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 6),
    receiveTimeout: const Duration(seconds: 8),
    validateStatus: (_) => true,
  ))..interceptors.add(AuthService().authInterceptor);

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() => _running = true);
    final baseUrl = AuthService().baseUrl;
    final probes = <_ProbeSpec>[
      _ProbeSpec(
        label: 'Daemon root',
        endpoint: '$baseUrl/',
        description: 'Health ping (should return 200 or 404 fast)',
      ),
      _ProbeSpec(
        label: 'Auth · /auth/me',
        endpoint: '$baseUrl/auth/me',
        description: 'Confirms your bearer token is still valid',
      ),
      _ProbeSpec(
        label: 'Apps · /api/apps',
        endpoint: '$baseUrl/api/apps',
        description: 'Lists every deployed app',
      ),
      _ProbeSpec(
        label: 'Credentials store',
        endpoint: '$baseUrl/api/users/me/credentials',
        description: 'Every credential stored for the current user',
      ),
    ];

    final results = await Future.wait(
      probes.map((p) => _probe(p)),
      eagerError: false,
    );
    if (!mounted) return;
    setState(() {
      _probes = results;
      _lastRunAt = DateTime.now();
      _running = false;
    });
  }

  Future<_Probe> _probe(_ProbeSpec spec) async {
    final started = DateTime.now();
    try {
      final r = await _dio.get(spec.endpoint);
      final ms = DateTime.now().difference(started).inMilliseconds;
      final ok = r.statusCode != null && r.statusCode! < 500;
      return _Probe(
        spec: spec,
        ok: ok,
        statusCode: r.statusCode,
        latencyMs: ms,
        detail: _summariseBody(r.data),
      );
    } on DioException catch (e) {
      return _Probe(
        spec: spec,
        ok: false,
        statusCode: e.response?.statusCode,
        latencyMs: DateTime.now().difference(started).inMilliseconds,
        error: e.message ?? e.type.name,
      );
    } catch (e) {
      return _Probe(
        spec: spec,
        ok: false,
        latencyMs: DateTime.now().difference(started).inMilliseconds,
        error: e.toString(),
      );
    }
  }

  String? _summariseBody(dynamic body) {
    if (body == null) return null;
    if (body is Map && body['success'] == true) {
      final data = body['data'];
      if (data is List) return '${data.length} entries';
      if (data is Map) return '${data.keys.length} keys';
      return 'OK';
    }
    if (body is Map && body['error'] != null) {
      return body['error'].toString();
    }
    return null;
  }

  Future<void> _copyReport() async {
    final auth = AuthService();
    final lines = <String>[
      '## Digitorn client diagnostics',
      'Generated: ${DateTime.now().toIso8601String()}',
      'Daemon URL: ${auth.baseUrl}',
      'User: ${auth.currentUser?.userId ?? "(none)"}',
      'Authenticated: ${auth.isAuthenticated}',
      '',
    ];
    for (final p in _probes) {
      lines.add('- ${p.spec.label}');
      lines.add('  endpoint: ${p.spec.endpoint}');
      lines.add('  status : ${p.statusCode ?? "(n/a)"}');
      lines.add('  latency: ${p.latencyMs}ms');
      if (p.detail != null) lines.add('  detail : ${p.detail}');
      if (p.error != null) lines.add('  error  : ${p.error}');
      lines.add('');
    }
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Report copied to clipboard'),
      backgroundColor: context.colors.green.withValues(alpha: 0.9),
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.surface,
        elevation: 0,
        foregroundColor: c.text,
        title: Text('Diagnostics',
            style: GoogleFonts.inter(
                fontSize: 14,
                color: c.textBright,
                fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            tooltip: 'Copy report',
            icon: Icon(Icons.copy_all_rounded, size: 18, color: c.textMuted),
            onPressed: _copyReport,
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: Icon(Icons.refresh_rounded, size: 18, color: c.textMuted),
            onPressed: _running ? null : _run,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(c),
                const SizedBox(height: 20),
                if (_running && _probes.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 1.5, color: c.textMuted),
                      ),
                    ),
                  )
                else
                  for (final p in _probes)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _ProbeCard(probe: p),
                    ),
                const SizedBox(height: 24),
                _buildEnvironmentBlock(c),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(AppColors c) {
    final okCount = _probes.where((p) => p.ok).length;
    final total = _probes.length;
    final allGreen = total > 0 && okCount == total;
    final tint = total == 0
        ? c.textMuted
        : allGreen
            ? c.green
            : c.red;
    final label = total == 0
        ? 'Running…'
        : allGreen
            ? 'All systems operational'
            : '$okCount / $total services OK';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: tint,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                    color: tint.withValues(alpha: 0.5), blurRadius: 8),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: tint)),
                const SizedBox(height: 3),
                Text(
                  _lastRunAt == null
                      ? 'Probing…'
                      : 'Last run ${_timeAgo(_lastRunAt!)}',
                  style: GoogleFonts.firaCode(
                      fontSize: 10.5, color: c.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEnvironmentBlock(AppColors c) {
    final auth = AuthService();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('ENVIRONMENT',
              style: GoogleFonts.firaCode(
                  fontSize: 10,
                  color: c.textMuted,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5)),
          const SizedBox(height: 10),
          _kv(c, 'daemon_url', auth.baseUrl),
          _kv(c, 'user', auth.currentUser?.userId ?? '(none)'),
          _kv(c, 'email', auth.currentUser?.email ?? '(none)'),
          _kv(c, 'roles',
              auth.currentUser?.roles.join(', ') ?? ''),
          _kv(
              c,
              'permissions',
              auth.currentUser?.permissions.isEmpty == true
                  ? '(none)'
                  : (auth.currentUser?.permissions.join(', ') ?? '')),
          _kv(c, 'is_admin (effective)',
              '${auth.currentUser?.isAdmin ?? false}'),
          _kv(
              c,
              'is_admin (from daemon)',
              auth.currentUser?.serverIsAdmin == null
                  ? '(not sent)'
                  : '${auth.currentUser!.serverIsAdmin}'),
          _kv(c, 'authenticated', '${auth.isAuthenticated}'),
        ],
      ),
    );
  }

  Widget _kv(AppColors c, String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(k,
                style: GoogleFonts.firaCode(
                    fontSize: 11, color: c.textMuted)),
          ),
          Expanded(
            child: SelectableText(v,
                style: GoogleFonts.firaCode(
                    fontSize: 11, color: c.textBright)),
          ),
        ],
      ),
    );
  }

  static String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 10) return 'just now';
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }
}

class _ProbeSpec {
  final String label;
  final String endpoint;
  final String description;
  const _ProbeSpec({
    required this.label,
    required this.endpoint,
    required this.description,
  });
}

class _Probe {
  final _ProbeSpec spec;
  final bool ok;
  final int? statusCode;
  final int latencyMs;
  final String? detail;
  final String? error;
  const _Probe({
    required this.spec,
    required this.ok,
    required this.latencyMs,
    this.statusCode,
    this.detail,
    this.error,
  });
}

class _ProbeCard extends StatelessWidget {
  final _Probe probe;
  const _ProbeCard({required this.probe});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tint = probe.ok ? c.green : c.red;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(7),
                  border:
                      Border.all(color: tint.withValues(alpha: 0.35)),
                ),
                child: Icon(
                  probe.ok
                      ? Icons.check_rounded
                      : Icons.close_rounded,
                  size: 14,
                  color: tint,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(probe.spec.label,
                        style: GoogleFonts.inter(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: c.textBright)),
                    const SizedBox(height: 2),
                    Text(probe.spec.description,
                        style: GoogleFonts.inter(
                            fontSize: 10.5, color: c.textMuted)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    probe.statusCode != null ? '${probe.statusCode}' : 'err',
                    style: GoogleFonts.firaCode(
                      fontSize: 12,
                      color: tint,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text('${probe.latencyMs}ms',
                      style: GoogleFonts.firaCode(
                          fontSize: 10, color: c.textMuted)),
                ],
              ),
            ],
          ),
          if (probe.detail != null) ...[
            const SizedBox(height: 8),
            Text(probe.detail!,
                style: GoogleFonts.firaCode(
                    fontSize: 10.5, color: c.text, height: 1.4)),
          ],
          if (probe.error != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: c.red.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: c.red.withValues(alpha: 0.25)),
              ),
              child: SelectableText(
                probe.error!,
                style: GoogleFonts.firaCode(
                    fontSize: 10, color: c.red, height: 1.5),
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(probe.spec.endpoint,
              style: GoogleFonts.firaCode(
                  fontSize: 9.5, color: c.textDim)),
        ],
      ),
    );
  }
}
