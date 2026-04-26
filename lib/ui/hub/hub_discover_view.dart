/// Discover view backed by the daemon's `/api/hub/search` proxy.
///
/// Block order:
///   - Hub account panel (sign-in inline if not connected)
///   - Search bar
///   - Category chips
///   - Grid of HubSearchCards (or empty / error / loading state)
///   - Pager when total > pageSize
///
/// Mirror of web `DiscoverView`
/// (`digitorn_web/src/components/hub/discover-view.tsx`).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/app_package.dart';
import '../../models/hub/hub_models.dart';
import '../../services/hub_service.dart';
import '../../theme/app_theme.dart';
import 'hub_account_panel.dart';
import 'widgets/hub_search_card.dart';

const _kCategories = [
  ['all', 'All'],
  ['productivity', 'Productivity'],
  ['developer-tools', 'Developer Tools'],
  ['research', 'Research'],
  ['creative', 'Creative'],
  ['data', 'Data'],
  ['communication', 'Communication'],
];

class HubDiscoverView extends StatefulWidget {
  /// Packages already installed locally — used to flag matching cards
  /// as "Installed" by package id.
  final List<AppPackage> installed;

  /// Async install callback — returns true on success so the grid
  /// can mark the card as installed without a refetch round-trip.
  /// The hub install dialog (consent dance) is owned by the parent.
  final Future<bool> Function(HubSearchHit hit)? onInstallHit;

  final ValueChanged<HubSearchHit>? onCardTap;

  const HubDiscoverView({
    super.key,
    required this.installed,
    this.onInstallHit,
    this.onCardTap,
  });

  @override
  State<HubDiscoverView> createState() => _HubDiscoverViewState();
}

class _HubDiscoverViewState extends State<HubDiscoverView> {
  final _searchCtl = TextEditingController();
  String _category = 'all';
  String _debounced = '';
  int _page = 1;
  HubSearchResponse? _data;
  bool _loading = false;
  String? _error;
  Timer? _debounce;
  int _reqId = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      final q = value.trim();
      if (q == _debounced) return;
      setState(() {
        _debounced = q;
        _page = 1;
      });
      _load();
    });
  }

  Future<void> _load() async {
    final myId = ++_reqId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await HubService().search(
        q: _debounced.isEmpty ? null : _debounced,
        category: _category == 'all' ? null : _category,
        page: _page,
        pageSize: 24,
      );
      if (!mounted || myId != _reqId) return;
      setState(() {
        _data = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || myId != _reqId) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _selectCategory(String id) {
    if (_category == id) return;
    setState(() {
      _category = id;
      _page = 1;
    });
    _load();
  }

  void _setPage(int p) {
    if (p == _page) return;
    setState(() => _page = p);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final installedKeys =
        widget.installed.map((p) => p.packageId).toSet();
    final data = _data;
    final totalPages = data == null
        ? 1
        : ((data.total / data.pageSize).ceil()).clamp(1, 9999);

    return Container(
      color: c.bg,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(40, 28, 40, 60),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const HubAccountPanel(),
            const SizedBox(height: 18),
            _SearchBar(controller: _searchCtl, onChanged: _onQueryChanged),
            const SizedBox(height: 14),
            _CategoryChips(active: _category, onSelect: _selectCategory),
            const SizedBox(height: 22),
            if (_loading && data == null)
              const _LoadingState()
            else if (_error != null)
              _ErrorState(message: _error!)
            else if (data == null || data.hits.isEmpty)
              _EmptyState(query: _debounced)
            else
              _Grid(
                hits: data.hits,
                installedKeys: installedKeys,
                onCardTap: widget.onCardTap,
                onInstallHit: widget.onInstallHit,
              ),
            if (totalPages > 1) ...[
              const SizedBox(height: 18),
              _Pager(
                page: _page,
                total: totalPages,
                loading: _loading,
                onChange: _setPage,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  final List<HubSearchHit> hits;
  final Set<String> installedKeys;
  final ValueChanged<HubSearchHit>? onCardTap;
  final Future<bool> Function(HubSearchHit)? onInstallHit;

  const _Grid({
    required this.hits,
    required this.installedKeys,
    required this.onCardTap,
    required this.onInstallHit,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final cols = (width / 280).floor().clamp(1, 4);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 1.65,
      ),
      itemCount: hits.length,
      itemBuilder: (_, i) {
        final hit = hits[i];
        return HubSearchCard(
          hit: hit,
          installed: installedKeys.contains(hit.packageId),
          onCardTap:
              onCardTap == null ? null : () => onCardTap!(hit),
          onInstall: onInstallHit == null
              ? null
              : () async {
                  await onInstallHit!(hit);
                },
        );
      },
    );
  }
}

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  const _SearchBar({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 16, color: c.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: GoogleFonts.inter(fontSize: 13, color: c.textBright),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: 'Filter packages…',
                hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
              ),
            ),
          ),
          if (controller.text.isNotEmpty)
            IconButton(
              padding: EdgeInsets.zero,
              constraints:
                  const BoxConstraints(minWidth: 24, minHeight: 24),
              splashRadius: 14,
              icon: Icon(Icons.close_rounded, size: 14, color: c.textMuted),
              onPressed: () {
                controller.clear();
                onChanged('');
              },
            ),
        ],
      ),
    );
  }
}

class _CategoryChips extends StatelessWidget {
  final String active;
  final ValueChanged<String> onSelect;
  const _CategoryChips({required this.active, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _kCategories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final id = _kCategories[i][0];
          final label = _kCategories[i][1];
          final selected = id == active;
          final accent = c.accentPrimary;
          return InkWell(
            onTap: () => onSelect(id),
            borderRadius: BorderRadius.circular(20),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: selected
                    ? accent.withValues(alpha: 0.12)
                    : c.surface,
                border: Border.all(
                  color: selected
                      ? accent.withValues(alpha: 0.5)
                      : c.border,
                  width: selected ? 1.4 : 1,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? accent : c.text,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60),
      child: Column(
        children: [
          const SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: 10),
          Text(
            'Searching the Hub…',
            style: TextStyle(fontSize: 13, color: c.textMuted),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String query;
  const _EmptyState({required this.query});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60),
      child: Column(
        children: [
          Icon(Icons.search_off_rounded, size: 36, color: c.textDim),
          const SizedBox(height: 10),
          Text(
            query.isNotEmpty
                ? 'No package matches "$query"'
                : 'No package in this category yet',
            style: TextStyle(fontSize: 13, color: c.textMuted),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  const _ErrorState({required this.message});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.red.withValues(alpha: 0.06),
        border: Border.all(color: c.red.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        message,
        style: TextStyle(fontSize: 13, color: c.red),
        textAlign: TextAlign.center,
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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            minimumSize: const Size(0, 32),
            side: BorderSide(color: c.border),
          ),
          child: const Text('Prev', style: TextStyle(fontSize: 12)),
        ),
        const SizedBox(width: 12),
        Text(
          '$page / $total',
          style: GoogleFonts.jetBrainsMono(fontSize: 12, color: c.textMuted),
        ),
        const SizedBox(width: 12),
        OutlinedButton(
          onPressed:
              page >= total || loading ? null : () => onChange(page + 1),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            minimumSize: const Size(0, 32),
            side: BorderSide(color: c.border),
          ),
          child: const Text('Next', style: TextStyle(fontSize: 12)),
        ),
      ],
    );
  }
}
