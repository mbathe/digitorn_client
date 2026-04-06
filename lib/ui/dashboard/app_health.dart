import 'package:digitorn_client/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:dio/dio.dart';
import '../../services/auth_service.dart';

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
  bool _loading = true;

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
      final [diagResp, metResp] = await Future.wait([
        _dio.get('$_base/api/apps/${widget.appId}/diagnostics'),
        _dio.get('$_base/api/metrics/apps/${widget.appId}'),
      ]);

      if (mounted) {
        setState(() {
          _diagnostics = diagResp.statusCode == 200
              ? (diagResp.data['data'] ?? diagResp.data) as Map<String, dynamic>?
              : null;
          _metrics = metResp.statusCode == 200
              ? (metResp.data['data'] ?? metResp.data) as Map<String, dynamic>?
              : null;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
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
                    ],

                    if (_diagnostics == null && _metrics == null)
                      Center(
                        child: Text('No data available',
                          style: GoogleFonts.inter(color: c.textMuted, fontSize: 13)),
                      ),
                  ],
                ),
              ),
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
    final ok = check['ok'] as bool? ?? check['status'] == 'ok' ?? true;
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
