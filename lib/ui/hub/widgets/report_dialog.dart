/// Modal dialog launched from the package detail header.
///
/// Mirror of web `ReportDialog`
/// (`digitorn_web/src/components/hub/report-dialog.tsx`).
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../models/hub/hub_models.dart';
import '../../../services/hub_service.dart';
import '../../../theme/app_theme.dart';

const int _kMaxDetails = 4000;

class _ReasonMeta {
  final HubReportReason value;
  final String label;
  final String hint;
  const _ReasonMeta(this.value, this.label, this.hint);
}

const _reasons = [
  _ReasonMeta(
    HubReportReason.malware,
    'Malware',
    'Suspicious code, phishing, supply-chain attack',
  ),
  _ReasonMeta(
    HubReportReason.spam,
    'Spam',
    'Low-effort, duplicated, or promotional content',
  ),
  _ReasonMeta(
    HubReportReason.abuse,
    'Abuse',
    'Harassment, hate speech, illegal content',
  ),
  _ReasonMeta(
    HubReportReason.copyright,
    'Copyright',
    'Unauthorised use of a third-party work',
  ),
  _ReasonMeta(
    HubReportReason.broken,
    "Broken / doesn't work",
    'Crashes on install, missing files',
  ),
  _ReasonMeta(
    HubReportReason.other,
    'Other',
    'Something else worth flagging',
  ),
];

/// Convenience launcher — returns true when the report was submitted.
Future<bool> showReportDialog({
  required BuildContext context,
  required String publisher,
  required String packageId,
  required String packageName,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (_) => ReportDialog(
      publisher: publisher,
      packageId: packageId,
      packageName: packageName,
    ),
  );
  return ok == true;
}

class ReportDialog extends StatefulWidget {
  final String publisher;
  final String packageId;
  final String packageName;

  const ReportDialog({
    super.key,
    required this.publisher,
    required this.packageId,
    required this.packageName,
  });

  @override
  State<ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<ReportDialog> {
  final _details = TextEditingController();
  HubReportReason _reason = HubReportReason.malware;
  bool _busy = false;
  String? _error;
  bool _done = false;

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await HubService().submitReport(
        widget.publisher,
        widget.packageId,
        reason: _reason,
        details:
            _details.text.trim().isEmpty ? null : _details.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _done = true;
        _busy = false;
      });
    } on HubServiceError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _formatError(e);
        _busy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not submit report.';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.flag_outlined, size: 16, color: c.orange),
                  const SizedBox(width: 8),
                  Text(
                    'Report package',
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: c.textBright,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (_done)
                _SuccessBanner(c: c)
              else ...[
                RichText(
                  text: TextSpan(
                    style: GoogleFonts.inter(
                      fontSize: 12.5,
                      color: c.textMuted,
                    ),
                    children: [
                      const TextSpan(text: 'Reporting '),
                      TextSpan(
                        text: widget.packageName,
                        style: GoogleFonts.inter(
                          fontWeight: FontWeight.w700,
                          color: c.text,
                        ),
                      ),
                      const TextSpan(
                        text:
                            '. Pick the closest reason; add details if it helps the moderators.',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                ..._reasons.map(
                  (r) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _ReasonRow(
                      meta: r,
                      selected: _reason == r.value,
                      onTap: () => setState(() => _reason = r.value),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _details,
                  minLines: 3,
                  maxLines: 6,
                  onChanged: (_) => setState(() {}),
                  style: GoogleFonts.inter(fontSize: 13, color: c.text),
                  decoration: InputDecoration(
                    hintText: 'Optional context (links, repro steps…)',
                    hintStyle:
                        TextStyle(color: c.textMuted, fontSize: 12.5),
                    filled: true,
                    fillColor: c.surfaceAlt,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: c.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: c.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: c.blue),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${_details.text.length} / $_kMaxDetails',
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 11,
                        color: _details.text.length > _kMaxDetails
                            ? c.red
                            : c.textMuted,
                      ),
                    ),
                    if (_error != null)
                      Flexible(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.error_outline,
                                size: 11, color: c.red),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Text(
                                _error!,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: c.red,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(_done),
                    child: Text(_done ? 'Close' : 'Cancel'),
                  ),
                  const SizedBox(width: 8),
                  if (!_done)
                    ElevatedButton(
                      onPressed: (_busy ||
                              _details.text.length > _kMaxDetails)
                          ? null
                          : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: c.orange,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor:
                            c.orange.withValues(alpha: 0.4),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        minimumSize: const Size(0, 32),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Submit report'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReasonRow extends StatelessWidget {
  final _ReasonMeta meta;
  final bool selected;
  final VoidCallback onTap;
  const _ReasonRow({
    required this.meta,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? c.blue.withValues(alpha: 0.08)
              : c.surface,
          border: Border.all(color: selected ? c.blue : c.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 12,
              height: 12,
              margin: const EdgeInsets.only(top: 3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? c.blue : Colors.transparent,
                border: Border.all(
                  width: 2,
                  color: selected ? c.blue : c.textDim,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    meta.label,
                    style: GoogleFonts.inter(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: c.textBright,
                    ),
                  ),
                  Text(
                    meta.hint,
                    style: TextStyle(fontSize: 11, color: c.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuccessBanner extends StatelessWidget {
  final AppColors c;
  const _SuccessBanner({required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.green.withValues(alpha: 0.08),
        border: Border.all(color: c.green.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_circle_outline_rounded, size: 14, color: c.green),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Thanks — moderators will review this report. Repeat reports on '
              'the same package within 24h are throttled.',
              style: TextStyle(fontSize: 12.5, color: c.green, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatError(HubServiceError e) {
  switch (e.status) {
    case 401:
      return 'Sign in to the Hub first.';
    case 429:
      return 'You already reported this package recently.';
    default:
      return e.message;
  }
}
