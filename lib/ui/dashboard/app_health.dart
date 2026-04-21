import 'package:digitorn_client/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:dio/dio.dart';
import '../../services/app_lifecycle_service.dart';
import '../../services/auth_service.dart';
import '../chat/chat_bubbles.dart' show showToast;

/// App health dialog — shows diagnostics + metrics from daemon
class AppHealthDialog extends StatefulWidget {
  final String appId;
  final String appName;
  const AppHealthDialog({super.key, required this.appId, required this.appName});

  static void show(BuildContext context, String appId, String appName) {
    showDialog(
      context: context,
      builder: (_) => AppHealthDialog(appId: appId, appName: appName),
    );
  }

  @override
  State<AppHealthDialog> createState() => _AppHealthDialogState();
}

class _AppHealthDialogState extends State<AppHealthDialog> {
  Map<String, dynamic>? _diagnostics;
  Map<String, dynamic>? _metrics;
  Map<String, dynamic>? _status;
  List<Map<String, dynamic>> _errors = const [];
  bool _loading = true;
  bool _busy = false;

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 10),
    validateStatus: (s) => s != null && s < 500,
  ))..interceptors.add(AuthService().authInterceptor);

  String get _base => AuthService().baseUrl;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      // Parallelise every endpoint the dialog needs. AppLifecycleService
      // wraps the four lifecycle introspection routes (status +
      // errors) so we don't have to duplicate the Dio setup here.
      final svc = AppLifecycleService();
      final results = await Future.wait([
        _dio.get('$_base/api/apps/${widget.appId}/diagnostics'),
        _dio.get('$_base/api/metrics/apps/${widget.appId}'),
        svc.status(widget.appId),
        svc.fetchErrors(widget.appId, limit: 10),
      ]);
      final diagResp = results[0] as Response;
      final metResp = results[1] as Response;
      final statusMap = results[2] as Map<String, dynamic>?;
      final errorsList = results[3] as List<Map<String, dynamic>>?;

      if (mounted) {
        setState(() {
          _diagnostics = diagResp.statusCode == 200
              ? (diagResp.data['data'] ?? diagResp.data) as Map<String, dynamic>?
              : null;
          _metrics = metResp.statusCode == 200
              ? (metResp.data['data'] ?? metResp.data) as Map<String, dynamic>?
              : null;
          _status = statusMap;
          _errors = errorsList ?? const [];
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Lifecycle actions ────────────────────────────────────────

  Future<void> _runLifecycle({
    required String label,
    required Future<bool> Function() action,
    String? confirmMessage,
  }) async {
    if (confirmMessage != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dCtx) => AlertDialog(
          backgroundColor: context.colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: context.colors.border),
          ),
          title: Text('$label?',
              style: GoogleFonts.inter(
                  fontSize: 15, fontWeight: FontWeight.w600)),
          content: Text(confirmMessage,
              style: GoogleFonts.inter(fontSize: 13)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dCtx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dCtx).pop(true),
              child: Text(label),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy = true);
    final ok = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    showToast(context, ok ? '$label: OK' : '$label failed — check logs.');
    if (ok) _fetch(); // refresh status / diagnostics / errors
  }

  bool get _isDisabled {
    final s = _status;
    if (s == null) return false;
    final raw = s['status'] ?? s['state'] ?? s['enabled'];
    if (raw is bool) return !raw;
    if (raw is String) {
      return raw == 'disabled' || raw == 'paused';
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 500),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Text(widget.appName,
                    style: GoogleFonts.inter(
                      fontSize: 16, fontWeight: FontWeight.w600, color: c.text)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Icon(Icons.close_rounded, size: 18, color: c.textMuted),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: c.border),

            if (_loading)
              const Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(strokeWidth: 1.5),
              )
            else
              Flexible(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // Diagnostics
                    if (_diagnostics != null) ...[
                      Text('DIAGNOSTICS',
                        style: GoogleFonts.inter(
                          fontSize: 10, fontWeight: FontWeight.w600,
                          color: c.textMuted, letterSpacing: 0.5)),
                      const SizedBox(height: 8),
                      _buildDiagnostics(),
                      const SizedBox(height: 16),
                    ],

                    // Metrics
                    if (_metrics != null) ...[
                      Text('METRICS',
                        style: GoogleFonts.inter(
                          fontSize: 10, fontWeight: FontWeight.w600,
                          color: c.textMuted, letterSpacing: 0.5)),
                      const SizedBox(height: 8),
                      _buildMetrics(),
                      const SizedBox(height: 16),
                    ],

                    // Recent errors (AppLifecycleService.fetchErrors)
                    if (_errors.isNotEmpty) ...[
                      Text('RECENT ERRORS',
                          style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: c.textMuted,
                              letterSpacing: 0.5)),
                      const SizedBox(height: 8),
                      _buildErrors(),
                    ],

                    if (_diagnostics == null && _metrics == null &&
                        _errors.isEmpty)
                      Center(
                        child: Text('No data available',
                          style: GoogleFonts.inter(color: c.textMuted, fontSize: 13)),
                      ),
                  ],
                ),
              ),

            // ── Lifecycle action bar ─────────────────────────────
            if (!_loading) ...[
              Divider(height: 1, color: c.border),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _runLifecycle(
                              label: 'Reload',
                              action: () => AppLifecycleService()
                                  .reload(widget.appId)),
                      icon: const Icon(Icons.refresh_rounded, size: 14),
                      label: const Text('Reload'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: c.text,
                        side: BorderSide(color: c.border),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _runLifecycle(
                              label: _isDisabled ? 'Enable' : 'Disable',
                              action: _isDisabled
                                  ? () => AppLifecycleService()
                                      .enable(widget.appId)
                                  : () => AppLifecycleService()
                                      .disable(widget.appId)),
                      icon: Icon(
                        _isDisabled
                            ? Icons.power_rounded
                            : Icons.pause_rounded,
                        size: 14,
                      ),
                      label: Text(_isDisabled ? 'Enable' : 'Disable'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _isDisabled ? c.green : c.orange,
                        side: BorderSide(
                            color: (_isDisabled ? c.green : c.orange)
                                .withValues(alpha: 0.4)),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                      ),
                    ),
                    const Spacer(),
                    if (_busy)
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 1.5, color: c.textMuted),
                      ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _runLifecycle(
                              label: 'Delete',
                              confirmMessage:
                                  'Permanently undeploy this app and wipe '
                                  'every session. This cannot be undone.',
                              action: () => AppLifecycleService()
                                  .deleteApp(widget.appId)),
                      icon: const Icon(Icons.delete_outline_rounded,
                          size: 14),
                      label: const Text('Delete'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: c.red,
                        side: BorderSide(
                            color: c.red.withValues(alpha: 0.4)),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDiagnostics() {
    final c = context.colors;
    final checks = _diagnostics!['checks'] as List<dynamic>? ?? [];
    if (checks.isEmpty) {
      return _buildFlatDiag();
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          for (int i = 0; i < checks.length; i++) ...[
            _diagRow(checks[i] as Map<String, dynamic>),
            if (i < checks.length - 1) Divider(height: 1, color: c.border),
          ],
        ],
      ),
    );
  }

  Widget _buildFlatDiag() {
    final c = context.colors;
    final model = _diagnostics!['model'] as String? ?? '';
    final modules = _diagnostics!['modules'] as List<dynamic>? ?? [];
    final toolCount = _diagnostics!['tool_count'] as int? ?? _diagnostics!['tools'] ?? 0;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          _simpleRow('Model', model.isEmpty ? 'unknown' : model),
          Divider(height: 1, color: c.border),
          _simpleRow('Modules', '${modules.length} loaded'),
          Divider(height: 1, color: c.border),
          _simpleRow('Tools', '$toolCount available'),
        ],
      ),
    );
  }

  Widget _diagRow(Map<String, dynamic> check) {
    final c = context.colors;
    final name = check['name'] as String? ?? check['check'] as String? ?? '';
    final ok = (check['ok'] as bool?) ?? (check['status'] == 'ok');
    final detail = check['detail'] as String? ?? check['message'] as String? ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle_rounded : Icons.error_rounded,
              size: 14, color: ok ? c.green : c.red),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: GoogleFonts.inter(fontSize: 12, color: c.text)),
                if (detail.isNotEmpty)
                  Text(detail, style: GoogleFonts.inter(fontSize: 11, color: c.textMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _simpleRow(String label, String value) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Text(label, style: GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
          const Spacer(),
          Text(value, style: GoogleFonts.firaCode(fontSize: 12, color: c.text)),
        ],
      ),
    );
  }

  Widget _buildErrors() {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.red.withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          for (int i = 0; i < _errors.length; i++) ...[
            _errorRow(_errors[i]),
            if (i < _errors.length - 1)
              Divider(height: 1, color: c.border),
          ],
        ],
      ),
    );
  }

  Widget _errorRow(Map<String, dynamic> err) {
    final c = context.colors;
    final msg = (err['message'] ?? err['error'] ?? '').toString();
    final ts = (err['ts'] ?? err['timestamp'] ?? '').toString();
    final source = (err['source'] ?? err['kind'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline_rounded, size: 13, color: c.red),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  msg.isEmpty ? '(no message)' : msg,
                  style: GoogleFonts.firaCode(
                      fontSize: 11, color: c.text),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (source.isNotEmpty || ts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 19, top: 2),
              child: Text(
                [if (source.isNotEmpty) source, if (ts.isNotEmpty) ts]
                    .join(' · '),
                style:
                    GoogleFonts.inter(fontSize: 10, color: c.textDim),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMetrics() {
    final c = context.colors;
    final sessions = _metrics!['active_sessions'] as int? ?? _metrics!['sessions'] ?? 0;
    final totalCost = _metrics!['total_cost_usd'] as num? ?? _metrics!['cost_usd'] ?? 0;
    final totalTokens = _metrics!['total_tokens'] as int? ?? 0;
    final totalCalls = _metrics!['total_tool_calls'] as int? ?? 0;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          _simpleRow('Active sessions', '$sessions'),
          Divider(height: 1, color: c.border),
          _simpleRow('Total tokens', _fmt(totalTokens)),
          Divider(height: 1, color: c.border),
          _simpleRow('Tool calls', '$totalCalls'),
          Divider(height: 1, color: c.border),
          _simpleRow('Cost', '\$${totalCost.toStringAsFixed(4)}'),
        ],
      ),
    );
  }

  String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return n.toString();
  }
}
