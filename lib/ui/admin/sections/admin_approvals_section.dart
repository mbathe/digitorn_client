/// Admin → Approvals. Pending approval requests across every app
/// the admin oversees. Each row carries:
///
///   * The app + session context, tool name + a short preview of
///     the proposed action
///   * Accept / Reject buttons that call
///     [AppAdminService.resolveApproval] (admin-scope)
///
/// The list is refreshed via `AppsService` (to enumerate apps) +
/// `AppAdminService.listApprovals` per app. A single admin can
/// thus triage pending approvals globally in one pane instead of
/// hopping session to session.
library;

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/app_admin_service.dart';
import '../../../services/apps_service.dart';
import '../../../theme/app_theme.dart';
import '../../chat/chat_bubbles.dart' show showToast;
import '_section_scaffold.dart';

class AdminApprovalsSection extends StatefulWidget {
  const AdminApprovalsSection({super.key});

  @override
  State<AdminApprovalsSection> createState() =>
      _AdminApprovalsSectionState();
}

class _PendingApproval {
  final String appId;
  final String appName;
  final Map<String, dynamic> raw;

  const _PendingApproval({
    required this.appId,
    required this.appName,
    required this.raw,
  });

  String get requestId => (raw['request_id'] ?? raw['id'] ?? '') as String;
  String get sessionId =>
      (raw['session_id'] ?? raw['sid'] ?? '') as String;
  String get toolName =>
      (raw['tool'] ?? raw['tool_name'] ?? raw['action'] ?? '?') as String;
  String get summary =>
      (raw['summary'] ?? raw['preview'] ?? raw['description'] ?? '')
          as String;
  String? get actor => raw['actor'] as String? ?? raw['user_id'] as String?;
}

class _AdminApprovalsSectionState extends State<AdminApprovalsSection> {
  bool _loading = true;
  List<_PendingApproval> _rows = const [];
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    // Ensure the app catalogue is fresh so we label apps correctly.
    await AppsService().refresh();
    final apps = AppsService().apps;
    final admin = AppAdminService();
    final futures = apps.map((a) async {
      final res = await admin.listApprovals(a.appId, scope: AdminScope.admin);
      if (res == null) return const <_PendingApproval>[];
      return res.map((m) => _PendingApproval(
          appId: a.appId, appName: a.name, raw: m));
    });
    final results = await Future.wait(futures);
    if (!mounted) return;
    setState(() {
      _rows = results
          .expand<_PendingApproval>((iter) => iter)
          .toList(growable: false);
      _loading = false;
    });
  }

  Future<void> _resolve(_PendingApproval row, bool approved) async {
    if (row.requestId.isEmpty) return;
    setState(() => _busy.add(row.requestId));
    final ok = await AppAdminService().resolveApproval(
      row.appId,
      requestId: row.requestId,
      approved: approved,
      scope: AdminScope.admin,
    );
    if (!mounted) return;
    setState(() => _busy.remove(row.requestId));
    showToast(
      context,
      ok
          ? (approved
              ? 'admin.approvals_approved'.tr()
              : 'admin.approvals_rejected'.tr())
          : 'admin.approvals_resolve_failed'.tr(),
    );
    if (ok) _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AdminSectionScaffold(
      title: 'admin.approvals'.tr(),
      subtitle: _loading
          ? 'admin.approvals_scanning'.tr()
          : 'admin.approvals_pending_count'.tr(namedArgs: {
              'n': '${_rows.length}',
              'apps': '${AppsService().apps.length}',
            }),
      loading: _loading,
      onRefresh: _load,
      child: _rows.isEmpty
          ? _buildEmpty(c)
          : Container(
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.border),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < _rows.length; i++) ...[
                    _ApprovalRow(
                      row: _rows[i],
                      busy: _busy.contains(_rows[i].requestId),
                      onApprove: () => _resolve(_rows[i], true),
                      onReject: () => _resolve(_rows[i], false),
                    ),
                    if (i < _rows.length - 1)
                      Divider(height: 1, color: c.border),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildEmpty(AppColors c) {
    return Container(
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
            Icon(Icons.verified_user_rounded, size: 36, color: c.green),
            const SizedBox(height: 12),
            Text(
              'admin.approvals_all_clear'.tr(),
              style: GoogleFonts.inter(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: c.textBright,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'admin.approvals_no_pending'.tr(),
              style: GoogleFonts.inter(fontSize: 12, color: c.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _ApprovalRow extends StatelessWidget {
  final _PendingApproval row;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _ApprovalRow({
    required this.row,
    required this.busy,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: c.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: c.orange.withValues(alpha: 0.3)),
            ),
            child: Text(
              row.toolName.toUpperCase(),
              style: GoogleFonts.firaCode(
                fontSize: 9,
                color: c.orange,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.appName.isNotEmpty ? row.appName : row.appId,
                  style: GoogleFonts.inter(
                    fontSize: 12.5,
                    color: c.textBright,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  row.summary.isEmpty
                      ? 'admin.approvals_no_preview'.tr()
                      : row.summary,
                  style: GoogleFonts.firaCode(
                      fontSize: 11, color: c.textMuted),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    if (row.actor != null)
                      'admin.approvals_by'
                          .tr(namedArgs: {'actor': row.actor!}),
                    if (row.sessionId.isNotEmpty)
                      'admin.approvals_session'.tr(namedArgs: {
                        'id': row.sessionId.substring(
                            0, row.sessionId.length.clamp(0, 10))
                      }),
                    'admin.approvals_id'
                        .tr(namedArgs: {'id': row.requestId}),
                  ].join(' · '),
                  style: GoogleFonts.firaCode(
                      fontSize: 9.5, color: c.textDim),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (busy)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            )
          else ...[
            OutlinedButton.icon(
              onPressed: onReject,
              icon: const Icon(Icons.close_rounded, size: 14),
              label: Text('admin.approvals_reject'.tr()),
              style: OutlinedButton.styleFrom(
                foregroundColor: c.red,
                side: BorderSide(color: c.red.withValues(alpha: 0.35)),
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 6),
              ),
            ),
            const SizedBox(width: 6),
            ElevatedButton.icon(
              onPressed: onApprove,
              icon: const Icon(Icons.check_rounded,
                  size: 14, color: Colors.white),
              label: Text(
                'admin.approvals_approve'.tr(),
                style: GoogleFonts.inter(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 11.5),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: c.green,
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
