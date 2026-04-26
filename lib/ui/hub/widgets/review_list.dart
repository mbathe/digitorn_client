/// Reviews tab on the Package detail page. Three blocks stacked:
///   1. Distribution summary (avg + 5 bars)
///   2. Inline review form (only when signed in to Hub)
///   3. Paginated review list with sort selector
///
/// Mirror of web `ReviewList`
/// (`digitorn_web/src/components/hub/review-list.tsx`).
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../models/hub/hub_models.dart';
import '../../../services/hub_service.dart';
import '../../../services/hub_session_service.dart';
import '../../../theme/app_theme.dart';
import 'rating_distribution.dart';
import 'review_form.dart';
import 'star_rating.dart';

class ReviewList extends StatefulWidget {
  final String publisher;
  final String packageId;

  const ReviewList({
    super.key,
    required this.publisher,
    required this.packageId,
  });

  @override
  State<ReviewList> createState() => _ReviewListState();
}

class _ReviewListState extends State<ReviewList> {
  final _session = HubSessionService();
  HubReviewListResponse? _data;
  HubReviewSort _sort = HubReviewSort.recent;
  int _page = 1;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSession);
    _load();
  }

  @override
  void dispose() {
    _session.removeListener(_onSession);
    super.dispose();
  }

  void _onSession() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await HubService().reviews(
        widget.publisher,
        widget.packageId,
        sort: _sort,
        page: _page,
      );
      if (!mounted) return;
      setState(() {
        _data = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final data = _data;
    final totalPages = data == null
        ? 1
        : ((data.total / data.pageSize).ceil()).clamp(1, 9999);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (data != null) ...[
          RatingDistribution(
            avg: data.avgRating,
            total: data.reviewCount,
            distribution: data.distribution,
          ),
          const SizedBox(height: 16),
        ],
        if (_session.isLoggedIn)
          ReviewForm(
            publisher: widget.publisher,
            packageId: widget.packageId,
            onSubmitted: () {
              setState(() => _page = 1);
              _load();
            },
          )
        else
          _SignInCallout(),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              data == null
                  ? 'Reviews'
                  : '${data.total} ${data.total == 1 ? "review" : "reviews"}',
              style: GoogleFonts.inter(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: c.textBright,
              ),
            ),
            _SortPicker(
              value: _sort,
              onChanged: (v) {
                setState(() {
                  _page = 1;
                  _sort = v;
                });
                _load();
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_loading && data == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          _ErrorRow(message: _error!, onRetry: _load)
        else if (data != null && data.items.isEmpty)
          _EmptyState()
        else
          ...?_data?.items.map((r) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ReviewRow(item: r),
              )),
        if (totalPages > 1) ...[
          const SizedBox(height: 8),
          _Pager(
            page: _page,
            total: totalPages,
            loading: _loading,
            onChange: (p) {
              setState(() => _page = p);
              _load();
            },
          ),
        ],
      ],
    );
  }
}

class _ReviewRow extends StatelessWidget {
  final HubReviewItem item;
  const _ReviewRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(12),
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
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  _initials(item.userDisplayName),
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: c.textMuted,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.userDisplayName.isEmpty
                          ? 'Anonymous'
                          : item.userDisplayName,
                      style: GoogleFonts.inter(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: c.textBright,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      _formatDate(item.createdAt),
                      style: TextStyle(fontSize: 10.5, color: c.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              StarRating(value: item.rating.toDouble(), size: 12),
            ],
          ),
          if (item.body != null && item.body!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              item.body!,
              style: GoogleFonts.inter(
                fontSize: 12.5,
                color: c.text,
                height: 1.5,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SortPicker extends StatelessWidget {
  final HubReviewSort value;
  final ValueChanged<HubReviewSort> onChanged;
  const _SortPicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<HubReviewSort>(
          value: value,
          isDense: true,
          icon: Icon(Icons.expand_more, size: 14, color: c.textMuted),
          style: GoogleFonts.inter(fontSize: 11.5, color: c.text),
          dropdownColor: c.surface,
          items: const [
            DropdownMenuItem(
              value: HubReviewSort.recent,
              child: Text('Most recent'),
            ),
            DropdownMenuItem(
              value: HubReviewSort.ratingDesc,
              child: Text('Highest rated'),
            ),
            DropdownMenuItem(
              value: HubReviewSort.ratingAsc,
              child: Text('Lowest rated'),
            ),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}

class _Pager extends StatelessWidget {
  final int page;
  final int total;
  final bool loading;
  final ValueChanged<int> onChange;
  const _Pager({
    required this.page,
    required this.total,
    required this.loading,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        OutlinedButton(
          onPressed: page <= 1 || loading ? null : () => onChange(page - 1),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            minimumSize: const Size(0, 28),
            side: BorderSide(color: c.border),
          ),
          child: const Text('Prev', style: TextStyle(fontSize: 11.5)),
        ),
        const SizedBox(width: 12),
        Text(
          '$page / $total',
          style: GoogleFonts.jetBrainsMono(
            fontSize: 11.5,
            color: c.textMuted,
          ),
        ),
        const SizedBox(width: 12),
        OutlinedButton(
          onPressed: page >= total || loading ? null : () => onChange(page + 1),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            minimumSize: const Size(0, 28),
            side: BorderSide(color: c.border),
          ),
          child: const Text('Next', style: TextStyle(fontSize: 11.5)),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 40),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border, style: BorderStyle.solid),
      ),
      child: Column(
        children: [
          Icon(Icons.chat_bubble_outline_rounded, size: 20, color: c.textMuted),
          const SizedBox(height: 6),
          Text(
            'No reviews yet — be the first.',
            style: TextStyle(fontSize: 12.5, color: c.textMuted),
          ),
        ],
      ),
    );
  }
}

class _SignInCallout extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        'Sign in to the Hub above to leave a review.',
        style: TextStyle(fontSize: 12, color: c.textMuted),
      ),
    );
  }
}

class _ErrorRow extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorRow({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.red.withValues(alpha: 0.06),
        border: Border.all(color: c.red.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 12, color: c.red),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 24),
            ),
            child: Text(
              'Retry',
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: c.red,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _initials(String name) {
  if (name.trim().isEmpty) return '?';
  final parts = name.trim().split(RegExp(r'\s+')).take(2);
  final s = parts
      .map((p) => p.isNotEmpty ? p[0].toUpperCase() : '')
      .join();
  return s.isEmpty ? '?' : s;
}

String _formatDate(String iso) {
  if (iso.isEmpty) return '';
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[d.month - 1]} ${d.day}, ${d.year}';
}
