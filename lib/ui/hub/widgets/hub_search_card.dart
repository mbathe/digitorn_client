/// Card optimised for `/api/hub/search` results — shows verified
/// publisher badge, risk pill, ★ rating and download count, plus an
/// Install action.
///
/// Mirror of web `HubSearchCard`
/// (`digitorn_web/src/components/hub/hub-search-card.tsx`).
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../models/hub/hub_models.dart';
import '../../../theme/app_theme.dart';
import 'risk_pill.dart';
import 'star_rating.dart';
import 'verified_badge.dart';

class HubSearchCard extends StatefulWidget {
  final HubSearchHit hit;
  final bool installed;
  final VoidCallback? onCardTap;
  final Future<void> Function()? onInstall;

  const HubSearchCard({
    super.key,
    required this.hit,
    required this.installed,
    this.onCardTap,
    this.onInstall,
  });

  @override
  State<HubSearchCard> createState() => _HubSearchCardState();
}

class _HubSearchCardState extends State<HubSearchCard> {
  bool _hover = false;
  bool _busy = false;

  Future<void> _run() async {
    if (widget.onInstall == null || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.onInstall!();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hit = widget.hit;
    final seed = _seedColor(hit.name);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onCardTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: c.surface,
            border: Border.all(
              color: _hover ? c.borderHover : c.border,
              width: _hover ? 1.3 : 1,
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: _hover
                ? [
                    BoxShadow(
                      color: seed.withValues(alpha: 0.22),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _IconTile(hit: hit, seed: seed),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          hit.name,
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2,
                            color: c.textBright,
                            height: 1.15,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                hit.publisherSlug.isEmpty
                                    ? 'anonymous'
                                    : hit.publisherSlug,
                                style: GoogleFonts.jetBrainsMono(
                                  fontSize: 10,
                                  color: c.textMuted,
                                  height: 1.2,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (hit.publisherVerified) ...[
                              const SizedBox(width: 4),
                              Icon(
                                Icons.verified_rounded,
                                size: 10,
                                color: c.blue,
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Text(
                  hit.description.isEmpty ? hit.packageId : hit.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    color: c.text,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 7),
              Wrap(
                spacing: 3,
                runSpacing: 3,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  VerifiedBadge(verified: hit.publisherVerified, compact: true),
                  RiskPill(level: hit.riskLevel, compact: true),
                  if (hit.avgRating != null)
                    StarRating(
                      value: hit.avgRating!,
                      size: 11,
                      count: hit.reviewCount,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (hit.totalDownloads > 0) ...[
                    Icon(
                      Icons.cloud_download_outlined,
                      size: 11,
                      color: c.textMuted,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _formatDownloads(hit.totalDownloads),
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w600,
                        color: c.textMuted,
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (widget.installed)
                    _InstalledChip(c: c)
                  else
                    _InstallButton(
                      busy: _busy,
                      enabled: widget.onInstall != null,
                      onTap: _run,
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

class _IconTile extends StatelessWidget {
  final HubSearchHit hit;
  final Color seed;
  const _IconTile({required this.hit, required this.seed});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (hit.iconUrl != null && hit.iconUrl!.isNotEmpty) {
      return Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: c.surfaceAlt,
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.network(
          hit.iconUrl!,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _initialFallback(),
        ),
      );
    }
    return _initialFallback();
  }

  Widget _initialFallback() {
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: seed,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        (hit.name.isEmpty ? '?' : hit.name[0]).toUpperCase(),
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _InstallButton extends StatelessWidget {
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;
  const _InstallButton({
    required this.busy,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: 30,
      child: ElevatedButton.icon(
        onPressed: !enabled || busy ? null : onTap,
        icon: busy
            ? const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.download_rounded, size: 13),
        label: const Text('Install'),
        style: ElevatedButton.styleFrom(
          backgroundColor: c.blue,
          foregroundColor: Colors.white,
          disabledBackgroundColor: c.blue.withValues(alpha: 0.4),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          minimumSize: const Size(0, 30),
          textStyle: GoogleFonts.inter(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
    );
  }
}

class _InstalledChip extends StatelessWidget {
  final AppColors c;
  const _InstalledChip({required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_rounded, size: 11, color: c.textMuted),
          const SizedBox(width: 4),
          Text(
            'Installed',
            style: GoogleFonts.inter(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: c.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDownloads(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}

Color _seedColor(String name) {
  var h = 0;
  for (var i = 0; i < name.length; i++) {
    h = (h * 31 + name.codeUnitAt(i)) & 0x7fffffff;
  }
  return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.55, 0.45).toColor();
}
