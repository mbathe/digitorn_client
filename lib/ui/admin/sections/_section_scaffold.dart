/// Shared scaffold for every section inside the admin console.
/// Provides:
///   * Standard header (title, subtitle, refresh button, optional
///     trailing actions)
///   * Scrollable body with sensible padding
///   * Loading + empty + error sub-states for the consumers
///   * The shared [AdminAuditRow] widget reused by overview + audit
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/admin_service.dart';
import '../../../theme/app_theme.dart';

class AdminSectionScaffold extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;
  final bool loading;
  final VoidCallback? onRefresh;
  final List<Widget> headerActions;

  const AdminSectionScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.loading = false,
    this.onRefresh,
    this.headerActions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header
        Container(
          padding: const EdgeInsets.fromLTRB(36, 28, 36, 22),
          decoration: BoxDecoration(
            color: c.surface,
            border: Border(bottom: BorderSide(color: c.border)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: GoogleFonts.inter(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: c.textBright,
                          letterSpacing: -0.4,
                        )),
                    const SizedBox(height: 5),
                    Text(subtitle,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          color: c.textMuted,
                          height: 1.5,
                        )),
                  ],
                ),
              ),
              const SizedBox(width: 18),
              ...headerActions,
              if (onRefresh != null) ...[
                const SizedBox(width: 6),
                IconButton(
                  tooltip: 'admin.refresh'.tr(),
                  iconSize: 16,
                  icon: Icon(
                    loading
                        ? Icons.hourglass_empty_rounded
                        : Icons.refresh_rounded,
                    color: c.textMuted,
                  ),
                  onPressed: loading ? null : onRefresh,
                ),
              ],
            ],
          ),
        ),
        // Body
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(36, 24, 36, 60),
            child: child,
          ),
        ),
      ],
    );
  }
}

/// Audit row used by both the overview preview and the dedicated
/// activity log section. Shared widget — single source of truth.
class AdminAuditRow extends StatelessWidget {
  final AdminAuditEntry entry;
  final bool dense;
  const AdminAuditRow({super.key, required this.entry, this.dense = false});

  Color _actionTint(AppColors c) {
    if (entry.action.contains('delete') ||
        entry.action.contains('revoke')) {
      return c.red;
    }
    if (entry.action.contains('create') ||
        entry.action.contains('grant')) {
      return c.green;
    }
    if (entry.action.contains('update')) return c.blue;
    return c.textMuted;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tint = _actionTint(c);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 6 : 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: tint.withValues(alpha: 0.35)),
            ),
            child: Text(
              entry.action.toUpperCase(),
              style: GoogleFonts.firaCode(
                fontSize: 8.5,
                color: tint,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: entry.actorLabel ?? entry.actorId,
                    style: GoogleFonts.inter(
                        fontSize: 12,
                        color: c.textBright,
                        fontWeight: FontWeight.w600),
                  ),
                  if (entry.targetType != null) ...[
                    TextSpan(
                      text: '  →  ',
                      style: GoogleFonts.firaCode(
                          fontSize: 11, color: c.textDim),
                    ),
                    TextSpan(
                      text:
                          '${entry.targetType}/${entry.targetId ?? "?"}',
                      style: GoogleFonts.firaCode(
                          fontSize: 11, color: c.textMuted),
                    ),
                  ],
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            _ago(entry.when),
            style:
                GoogleFonts.firaCode(fontSize: 9.5, color: c.textDim),
          ),
        ],
      ),
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'admin.just_now'.tr();
    if (d.inHours < 1) {
      return 'admin.ago_m'.tr(namedArgs: {'n': '${d.inMinutes}'});
    }
    if (d.inDays < 1) {
      return 'admin.ago_h'.tr(namedArgs: {'n': '${d.inHours}'});
    }
    return 'admin.ago_d'.tr(namedArgs: {'n': '${d.inDays}'});
  }
}
