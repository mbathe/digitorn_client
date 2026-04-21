/// Admin → MCP pool. Lists every shared MCP instance the daemon
/// keeps warm across users. Admins can connect or disconnect a
/// pooled entry without uninstalling it. Read-only data tied to
/// `/api/mcp/pool` + the `/connect` / `/disconnect` actions.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/mcp_service.dart';
import '../../../services/misc_api_service.dart';
import '../../../theme/app_theme.dart';
import '_section_scaffold.dart';

class AdminMcpPoolSection extends StatefulWidget {
  const AdminMcpPoolSection({super.key});

  @override
  State<AdminMcpPoolSection> createState() => _AdminMcpPoolSectionState();
}

class _AdminMcpPoolSectionState extends State<AdminMcpPoolSection> {
  final _svc = McpService();
  List<Map<String, dynamic>> _pool = const [];
  Map<String, dynamic>? _health;
  bool _loading = true;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final results = await Future.wait([
      _svc.listPool(),
      MiscApiService().mcpPoolHealth(),
    ]);
    final list = results[0] as List<Map<String, dynamic>>;
    final health = results[1] as Map<String, dynamic>?;
    if (!mounted) return;
    setState(() {
      _pool = list;
      _health = health;
      _loading = false;
    });
  }

  Future<void> _connect(String id) async {
    setState(() => _busy.add(id));
    try {
      await _svc.connectPool(id);
      await _load();
    } on McpException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _disconnect(String id) async {
    setState(() => _busy.add(id));
    try {
      await _svc.disconnectPool(id);
      await _load();
    } on McpException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AdminSectionScaffold(
      title: 'admin.section_mcp_pool'.tr(),
      subtitle: 'admin.mcp_subtitle'.tr(),
      loading: _loading,
      onRefresh: _load,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_health != null) ...[
            _HealthBadge(health: _health!),
            const SizedBox(height: 12),
          ],
          _pool.isEmpty
              ? _buildEmpty(c)
              : Container(
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: c.border),
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < _pool.length; i++) ...[
                        _PoolRow(
                          entry: _pool[i],
                          busy: _busy
                              .contains(_pool[i]['id'] as String? ?? ''),
                          onConnect: () =>
                              _connect(_pool[i]['id'] as String? ?? ''),
                          onDisconnect: () =>
                              _disconnect(_pool[i]['id'] as String? ?? ''),
                        ),
                        if (i < _pool.length - 1)
                          Divider(height: 1, color: c.border),
                      ],
                    ],
                  ),
                ),
        ],
      ),
    );
  }

  Widget _buildEmpty(AppColors c) => Container(
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.border),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.electrical_services_rounded,
                  size: 36, color: c.textMuted),
              const SizedBox(height: 12),
              Text('admin.mcp_empty_title'.tr(),
                  style: GoogleFonts.inter(
                      fontSize: 13.5,
                      color: c.textBright,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(
                'admin.mcp_empty_body'.tr(),
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                    fontSize: 11.5, color: c.textMuted, height: 1.5),
              ),
            ],
          ),
        ),
      );
}

class _PoolRow extends StatelessWidget {
  final Map<String, dynamic> entry;
  final bool busy;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  const _PoolRow({
    required this.entry,
    required this.busy,
    required this.onConnect,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final name = entry['name'] as String? ??
        entry['server_id'] as String? ??
        entry['id'] as String? ??
        'unknown';
    final status = entry['status'] as String? ?? 'unknown';
    final isConnected = status == 'connected' || status == 'running';
    final tint = isConnected ? c.green : c.textMuted;
    final tools = entry['tools_count'] is num
        ? (entry['tools_count'] as num).toInt()
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: tint.withValues(alpha: 0.35)),
            ),
            child: Icon(Icons.electrical_services_rounded,
                size: 14, color: tint),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: c.textBright),
                ),
                if (tools != null)
                  Text(
                    'admin.mcp_tools_count'.tr(namedArgs: {'n': '$tools'}),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.firaCode(
                        fontSize: 10, color: c.textMuted),
                  ),
              ],
            ),
          ),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: tint.withValues(alpha: 0.35)),
            ),
            child: Text(status.toUpperCase(),
                style: GoogleFonts.firaCode(
                    fontSize: 8.5,
                    color: tint,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5)),
          ),
          const SizedBox(width: 14),
          if (busy)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: c.textMuted),
            )
          else if (isConnected)
            OutlinedButton.icon(
              onPressed: onDisconnect,
              icon: Icon(Icons.link_off_rounded, size: 13, color: c.red),
              label: Text('admin.mcp_disconnect'.tr(),
                  style: GoogleFonts.inter(
                      fontSize: 11, color: c.red,
                      fontWeight: FontWeight.w700)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: c.red.withValues(alpha: 0.5)),
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
              ),
            )
          else
            ElevatedButton.icon(
              onPressed: onConnect,
              icon: const Icon(Icons.link_rounded,
                  size: 13, color: Colors.white),
              label: Text('admin.mcp_connect'.tr(),
                  style: GoogleFonts.inter(
                      fontSize: 11,
                      color: Colors.white,
                      fontWeight: FontWeight.w700)),
              style: ElevatedButton.styleFrom(
                backgroundColor: c.green,
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 9),
              ),
            ),
        ],
      ),
    );
  }
}

/// Summary strip rendered above the pool list when
/// `MiscApiService.mcpPoolHealth()` returns a payload. Shows
/// status (green / red), the number of live connections reported
/// by the daemon, and a freshness timestamp.
class _HealthBadge extends StatelessWidget {
  final Map<String, dynamic> health;
  const _HealthBadge({required this.health});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final healthy = health['healthy'] == true || health['status'] == 'ok';
    final live = (health['connected'] ?? health['live_connections']
            ?? health['count']) as int?;
    final total = (health['servers'] ?? health['total']) as int?;
    final latency = (health['latency_ms'] ?? health['probe_ms']) as num?;
    final msg = health['message']?.toString() ?? '';
    final color = healthy ? c.green : c.red;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(
              healthy
                  ? Icons.check_circle_rounded
                  : Icons.error_rounded,
              size: 16, color: color),
          const SizedBox(width: 8),
          Text(
            healthy
                ? 'admin.mcp_pool_healthy'.tr()
                : 'admin.mcp_pool_degraded'.tr(),
            style: GoogleFonts.inter(
                fontSize: 12, fontWeight: FontWeight.w700, color: color),
          ),
          const SizedBox(width: 10),
          if (live != null || total != null)
            Text(
              '${live ?? 0}${total != null ? ' / $total' : ''} live',
              style: GoogleFonts.firaCode(
                  fontSize: 11, color: c.textMuted),
            ),
          if (latency != null) ...[
            const SizedBox(width: 10),
            Text('${latency.round()}ms',
                style: GoogleFonts.firaCode(
                    fontSize: 11, color: c.textDim)),
          ],
          const Spacer(),
          if (msg.isNotEmpty)
            Flexible(
              child: Text(msg,
                  style: GoogleFonts.inter(
                      fontSize: 11, color: c.textDim),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
        ],
      ),
    );
  }
}
