/// Cross-app approvals queue — one place to approve / deny every
/// pending tool call the daemon is waiting on, across every session
/// of every app. Backed by `GET /api/users/me/approvals`.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/approvals_service.dart';
import '../../theme/app_theme.dart';
import '../common/remote_icon.dart';
import '../common/themed_dialogs.dart';

class ApprovalsPage extends StatefulWidget {
  const ApprovalsPage({super.key});

  @override
  State<ApprovalsPage> createState() => _ApprovalsPageState();
}

class _ApprovalsPageState extends State<ApprovalsPage> {
  final _svc = ApprovalsService();

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChange);
    _svc.refresh();
  }

  @override
  void dispose() {
    _svc.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
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
        title: Text('Pending approvals',
            style: GoogleFonts.inter(
                fontSize: 14,
                color: c.textBright,
                fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh_rounded, size: 18, color: c.textMuted),
            onPressed: _svc.loading ? null : () => _svc.refresh(),
          ),
        ],
      ),
      body: _svc.loading && _svc.pending.isEmpty
          ? Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: c.textMuted),
              ),
            )
          : _svc.pending.isEmpty
              ? _buildEmpty(c)
              : _buildList(c),
    );
  }

  Widget _buildEmpty(AppColors c) => Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.verified_outlined, size: 48, color: c.green),
              const SizedBox(height: 14),
              Text('Nothing awaiting your approval',
                  style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: c.textBright)),
              const SizedBox(height: 6),
              Text(
                'Every agent is cleared to run — this page fills up the moment one asks for permission.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                    fontSize: 12, color: c.textMuted, height: 1.5),
              ),
            ],
          ),
        ),
      );

  Widget _buildList(AppColors c) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(40, 28, 40, 60),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Pending approvals',
                  style: GoogleFonts.inter(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: c.textBright,
                  )),
              const SizedBox(height: 5),
              Text(
                '${_svc.count} request${_svc.count == 1 ? '' : 's'} awaiting your decision across every app.',
                style: GoogleFonts.inter(
                    fontSize: 13.5, color: c.textMuted, height: 1.5),
              ),
              const SizedBox(height: 22),
              for (final req in _svc.pending) ...[
                _ApprovalCard(
                  request: req,
                  onApprove: () => _respond(req, true),
                  onDeny: () => _respond(req, false),
                ),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _respond(PendingApproval req, bool approved) async {
    final msg = await _askMessage(context, approved: approved);
    if (msg == null) return;
    final ok = await _svc.respond(req, approved: approved, message: msg);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? (approved ? 'Approved' : 'Denied')
              : 'Failed to send response',
          style: GoogleFonts.inter(fontSize: 12),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<String?> _askMessage(BuildContext context,
      {required bool approved}) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = ctx.colors;
        return themedAlertDialog(
          ctx,
          title: approved ? 'Approve' : 'Deny',
          content: SizedBox(
            width: 360,
            child: TextField(
              controller: ctrl,
              autofocus: true,
              maxLines: 3,
              style: GoogleFonts.inter(fontSize: 13, color: c.textBright),
              decoration: themedInputDecoration(
                ctx,
                labelText: 'Message (optional)',
                hintText: approved
                    ? 'Go ahead, but only on the staging branch…'
                    : 'Not now — let me review the params first.',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel',
                  style: GoogleFonts.inter(
                      fontSize: 12, color: c.textMuted)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              style: ElevatedButton.styleFrom(
                backgroundColor: approved ? c.green : c.red,
                foregroundColor: Colors.white,
                elevation: 0,
              ),
              child: Text(approved ? 'Approve' : 'Deny',
                  style: GoogleFonts.inter(
                      fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          ],
        );
      },
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  final PendingApproval request;
  final VoidCallback onApprove;
  final VoidCallback onDeny;
  const _ApprovalCard({
    required this.request,
    required this.onApprove,
    required this.onDeny,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final riskTint = switch (request.riskLevel) {
      'high' || 'critical' => c.red,
      'medium' => c.orange,
      'low' => c.green,
      _ => c.textMuted,
    };
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RemoteIcon(
                id: request.appId,
                kind: RemoteIconKind.app,
                size: 38,
                transparent: true,
                emojiFallback: request.appIcon,
                nameFallback: request.appName ?? request.appId,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          request.toolName,
                          style: GoogleFonts.firaCode(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: c.textBright,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: riskTint.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(
                                color: riskTint.withValues(alpha: 0.35)),
                          ),
                          child: Text(
                            '${request.riskLevel.toUpperCase()} RISK',
                            style: GoogleFonts.firaCode(
                              fontSize: 8.5,
                              color: riskTint,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${request.appName ?? request.appId} · session ${_short(request.sessionId)} · ${_ago(request.createdAt)}',
                      style: GoogleFonts.firaCode(
                          fontSize: 10, color: c.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (request.summary != null && request.summary!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(request.summary!,
                style: GoogleFonts.inter(
                    fontSize: 12.5, color: c.text, height: 1.5)),
          ],
          if (request.params.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: c.border),
              ),
              child: Text(
                _prettyParams(request.params),
                style: GoogleFonts.firaCode(
                    fontSize: 10.5, color: c.text, height: 1.5),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              const Spacer(),
              OutlinedButton.icon(
                onPressed: onDeny,
                icon: Icon(Icons.close_rounded, size: 14, color: c.red),
                label: Text('Deny',
                    style: GoogleFonts.inter(
                        fontSize: 12,
                        color: c.red,
                        fontWeight: FontWeight.w600)),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: c.red.withValues(alpha: 0.5)),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton.icon(
                onPressed: onApprove,
                icon: const Icon(Icons.check_rounded,
                    size: 14, color: Colors.white),
                label: Text('Approve',
                    style: GoogleFonts.inter(
                        fontSize: 12,
                        color: Colors.white,
                        fontWeight: FontWeight.w700)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.green,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 10),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _short(String id) =>
      id.length > 10 ? id.substring(0, 10) : id;

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 30) return 'just now';
    if (d.inMinutes < 1) return '${d.inSeconds}s ago';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  static String _prettyParams(Map<String, dynamic> params) {
    final sb = StringBuffer();
    params.forEach((k, v) {
      final s = v is String
          ? (v.length > 140 ? '${v.substring(0, 140)}…' : v)
          : v.toString();
      sb.writeln('$k: $s');
    });
    return sb.toString().trimRight();
  }
}
