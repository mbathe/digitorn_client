/// Inline form embedded above the review list. Posting the same
/// package a second time updates the existing review (daemon upsert),
/// so we don't need an explicit "edit" mode.
///
/// Mirror of web `ReviewForm`
/// (`digitorn_web/src/components/hub/review-form.tsx`).
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/hub_service.dart';
import '../../../theme/app_theme.dart';
import 'star_rating.dart';

const int _kMaxBody = 4000;

class ReviewForm extends StatefulWidget {
  final String publisher;
  final String packageId;
  final VoidCallback onSubmitted;

  const ReviewForm({
    super.key,
    required this.publisher,
    required this.packageId,
    required this.onSubmitted,
  });

  @override
  State<ReviewForm> createState() => _ReviewFormState();
}

class _ReviewFormState extends State<ReviewForm> {
  final _body = TextEditingController();
  int _rating = 0;
  bool _busy = false;
  String? _error;
  bool _success = false;

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_rating < 1 || _rating > 5 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await HubService().submitReview(
        widget.publisher,
        widget.packageId,
        rating: _rating,
        body: _body.text.trim().isEmpty ? null : _body.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _success = true;
        _busy = false;
        _body.clear();
        _rating = 0;
      });
      widget.onSubmitted();
      Future.delayed(const Duration(milliseconds: 2500), () {
        if (mounted) setState(() => _success = false);
      });
    } on HubServiceError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _formatError(e);
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not post review.';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final remaining = _kMaxBody - _body.text.length;
    final tooLong = remaining < 0;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Your review',
                style: GoogleFonts.inter(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: c.textBright,
                ),
              ),
              StarRating(
                value: _rating.toDouble(),
                size: 20,
                onChange: (v) => setState(() => _rating = v),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _body,
            minLines: 3,
            maxLines: 6,
            onChanged: (_) => setState(() {}),
            style: GoogleFonts.inter(fontSize: 13, color: c.text),
            decoration: InputDecoration(
              hintText: "Share what worked, what didn't, who'd love this…",
              hintStyle: TextStyle(color: c.textMuted, fontSize: 12.5),
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
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${_body.text.length} / $_kMaxBody',
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 11,
                  color: tooLong ? c.red : c.textMuted,
                ),
              ),
              ElevatedButton(
                onPressed:
                    (_busy || _rating < 1 || tooLong) ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.blue,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: c.blue.withValues(alpha: 0.4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  minimumSize: const Size(0, 30),
                  textStyle: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Post review'),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            _Banner(message: _error!, color: c.red, icon: Icons.error_outline),
          ],
          if (_success) ...[
            const SizedBox(height: 8),
            _Banner(
              message: 'Thanks — your review is published.',
              color: c.green,
              icon: Icons.check_circle_outline,
            ),
          ],
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final String message;
  final Color color;
  final IconData icon;
  const _Banner({
    required this.message,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 11, color: color),
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
      return 'Please sign in to the Hub first.';
    case 403:
      return "You can't review your own package.";
    case 429:
      return 'Too many reviews — try again later.';
    default:
      return e.message;
  }
}
