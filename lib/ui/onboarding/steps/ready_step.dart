import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../design/ds.dart';
import '../../../services/onboarding_service.dart';
import '../../../theme/app_theme.dart';
import '../../ds/ds.dart';
import '../../ds/ds_avatar.dart';
import '../wizard_nav.dart';
import '../wizard_step_scaffold.dart';

class ReadyStep extends StatefulWidget {
  const ReadyStep({super.key});

  @override
  State<ReadyStep> createState() => _ReadyStepState();
}

class _ReadyStepState extends State<ReadyStep> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      WizardNav.of(context).setCanAdvance(true);
    });
  }

  void _launch(String target) {
    OnboardingService().preferredInitialTarget = target;
    WizardNav.of(context).onNext();
  }

  @override
  Widget build(BuildContext context) {
    final ob = OnboardingService();
    final displayName = ob.displayName ?? 'Digitorn';
    final compact = DsBreakpoint.isCompact(context);
    return WizardStepScaffold(
      eyebrow: 'onboarding.ready_eyebrow'.tr(),
      title: 'onboarding.ready_welcome'.tr(namedArgs: {'name': displayName}),
      subtitle: 'onboarding.ready_subtitle_long'.tr(),
      nextLabel: 'onboarding.ready_cta'.tr(),
      nextIcon: Icons.arrow_forward,
      maxWidth: 820,
      illustration: _Celebration(seed: displayName),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Summary(service: ob),
          SizedBox(height: DsSpacing.x8),
          _SectionLabel(label: 'onboarding.ready_or_jump'.tr()),
          SizedBox(height: DsSpacing.x4),
          if (compact)
            Column(
              children: [
                _LaunchCard(
                  accent: true,
                  title: 'onboarding.ready_builder_title'.tr(),
                  subtitle: 'onboarding.ready_builder_subtitle'.tr(),
                  icon: Icons.auto_fix_high,
                  badge: 'onboarding.ready_recommended'.tr(),
                  onTap: () => _launch('builder'),
                ),
                SizedBox(height: DsSpacing.x3),
                _LaunchCard(
                  title: 'onboarding.ready_hub_title'.tr(),
                  subtitle: 'onboarding.ready_hub_subtitle'.tr(),
                  icon: Icons.storefront_outlined,
                  onTap: () => _launch('hub'),
                ),
              ],
            )
          else
            IntrinsicHeight(
              child: Row(
                children: [
                  Expanded(
                    flex: 6,
                    child: _LaunchCard(
                      accent: true,
                      title: 'onboarding.ready_builder_title'.tr(),
                      subtitle: 'onboarding.ready_builder_subtitle'.tr(),
                      icon: Icons.auto_fix_high,
                      badge: 'onboarding.ready_recommended'.tr(),
                      onTap: () => _launch('builder'),
                    ),
                  ),
                  SizedBox(width: DsSpacing.x3),
                  Expanded(
                    flex: 5,
                    child: _LaunchCard(
                      title: 'onboarding.ready_hub_title'.tr(),
                      subtitle: 'onboarding.ready_hub_subtitle'.tr(),
                      icon: Icons.storefront_outlined,
                      onTap: () => _launch('hub'),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        Text(label, style: DsType.eyebrow(color: c.accentPrimary)),
        Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: DsSpacing.x4),
            child: Container(height: 1, color: c.border),
          ),
        ),
      ],
    );
  }
}

class _LaunchCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool accent;
  final String? badge;
  final VoidCallback onTap;

  const _LaunchCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    this.accent = false,
    this.badge,
    required this.onTap,
  });

  @override
  State<_LaunchCard> createState() => _LaunchCardState();
}

class _LaunchCardState extends State<_LaunchCard> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final borderColor = widget.accent
        ? c.accentPrimary
        : (_hover ? c.borderHover : c.border);
    final bg = widget.accent
        ? Color.lerp(c.surface, c.accentPrimary, _hover ? 0.10 : 0.06)
        : (_hover ? c.surfaceAlt : c.surface);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          duration: DsDuration.fast,
          curve: DsCurve.decelSnap,
          scale: _pressed ? 0.985 : 1.0,
          child: AnimatedContainer(
            duration: DsDuration.base,
            curve: DsCurve.decelSnap,
            padding: EdgeInsets.all(DsSpacing.x5),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(DsRadius.card),
              border: Border.all(
                color: borderColor,
                width: widget.accent || _hover
                    ? DsStroke.normal
                    : DsStroke.hairline,
              ),
              boxShadow: widget.accent
                  ? DsElevation.accentGlow(c.accentPrimary,
                      strength: _hover ? 0.6 : 0.35)
                  : (_hover
                      ? DsElevation.float(c.shadow)
                      : DsElevation.raise(c.shadow)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        gradient: widget.accent
                            ? LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [c.accentPrimary, c.accentSecondary],
                              )
                            : null,
                        color: widget.accent ? null : c.surfaceAlt,
                        borderRadius: BorderRadius.circular(DsRadius.xs),
                        boxShadow: widget.accent
                            ? DsElevation.accentGlow(c.accentPrimary,
                                strength: 0.6)
                            : null,
                      ),
                      child: Icon(
                        widget.icon,
                        size: 18,
                        color: widget.accent ? c.onAccent : c.textBright,
                      ),
                    ),
                    const Spacer(),
                    if (widget.badge != null)
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: DsSpacing.x3,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: c.accentPrimary.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(DsRadius.pill),
                          border: Border.all(
                            color: c.accentPrimary.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Text(
                          widget.badge!,
                          style: DsType.micro(color: c.accentPrimary)
                              .copyWith(
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w700,
                            fontSize: 10,
                          ),
                        ),
                      ),
                  ],
                ),
                SizedBox(height: DsSpacing.x5),
                Text(widget.title, style: DsType.h2(color: c.textBright)),
                SizedBox(height: DsSpacing.x2),
                Text(
                  widget.subtitle,
                  style: DsType.caption(color: c.textMuted)
                      .copyWith(height: 1.45),
                ),
                SizedBox(height: DsSpacing.x5),
                Row(
                  children: [
                    Text(
                      'onboarding.ready_launch'.tr(),
                      style: DsType.caption(
                        color: widget.accent ? c.accentPrimary : c.text,
                      ).copyWith(fontWeight: FontWeight.w600),
                    ),
                    SizedBox(width: DsSpacing.x2),
                    Icon(
                      Icons.arrow_forward,
                      size: 14,
                      color: widget.accent ? c.accentPrimary : c.text,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Celebration extends StatefulWidget {
  final String seed;
  const _Celebration({required this.seed});

  @override
  State<_Celebration> createState() => _CelebrationState();
}

class _CelebrationState extends State<_Celebration>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  String get _initials {
    final parts = widget.seed
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'D';
    if (parts.length == 1) {
      return parts.first.substring(0, parts.first.length.clamp(0, 2));
    }
    return '${parts.first[0]}${parts.last[0]}';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: 140,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _c,
            builder: (_, _) {
              return CustomPaint(
                painter: _SparklesPainter(
                  t: _c.value,
                  tint: c.accentPrimary,
                ),
                size: const Size(320, 140),
              );
            },
          ),
          DsAvatar(
            seed: widget.seed,
            initials: _initials,
            size: 88,
          ),
        ],
      ),
    );
  }
}

class _SparklesPainter extends CustomPainter {
  final double t;
  final Color tint;
  _SparklesPainter({required this.t, required this.tint});

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(7);
    for (int i = 0; i < 22; i++) {
      final baseX = rnd.nextDouble();
      final baseY = rnd.nextDouble();
      final phase = (t + rnd.nextDouble()) % 1.0;
      final alpha = (math.sin(phase * math.pi)).clamp(0.0, 1.0);
      final x = size.width * baseX;
      final y = size.height *
          (baseY + 0.05 * math.sin((t + rnd.nextDouble()) * 2 * math.pi));
      final r = 1.0 + rnd.nextDouble() * 1.5;
      final paint = Paint()
        ..color = tint.withValues(alpha: alpha * 0.6)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1);
      canvas.drawCircle(Offset(x, y), r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SparklesPainter old) => old.t != t;
}

class _Summary extends StatelessWidget {
  final OnboardingService service;
  const _Summary({required this.service});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final items = <_SummaryItem>[
      _SummaryItem(
        icon: Icons.badge_outlined,
        label: 'onboarding.ready_role'.tr(),
        value: _roleLabel(service.role),
      ),
      _SummaryItem(
        icon: Icons.auto_awesome_outlined,
        label: 'onboarding.ready_providers'.tr(),
        value: service.connectedProviders.isEmpty
            ? 'onboarding.ready_none_yet'.tr()
            : 'onboarding.ready_providers_connected'.tr(
                namedArgs: {'n': '${service.connectedProviders.length}'}),
      ),
      _SummaryItem(
        icon: Icons.apps,
        label: 'onboarding.ready_apps_queued'.tr(),
        value: service.installedApps.isEmpty
            ? 'onboarding.ready_builder_only'.tr()
            : 'onboarding.ready_apps_incl_builder'.tr(
                namedArgs: {'n': '${service.installedApps.length}'}),
      ),
    ];
    return DsSurface(
      padding: EdgeInsets.symmetric(
        horizontal: DsSpacing.x5,
        vertical: DsSpacing.x4,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (int i = 0; i < items.length; i++) ...[
            if (i > 0)
              Container(
                width: 1,
                height: 24,
                color: c.border,
              ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: DsSpacing.x3),
                child: _SummaryCell(item: items[i]),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _roleLabel(String id) => switch (id) {
      'developer' => 'onboarding.role_developer'.tr(),
      'analyst' => 'onboarding.role_analyst'.tr(),
      'operator' => 'onboarding.role_operator'.tr(),
      'researcher' => 'onboarding.role_researcher'.tr(),
      _ => 'onboarding.role_other'.tr(),
    };

class _SummaryItem {
  final IconData icon;
  final String label;
  final String value;
  const _SummaryItem({
    required this.icon,
    required this.label,
    required this.value,
  });
}

class _SummaryCell extends StatelessWidget {
  final _SummaryItem item;
  const _SummaryCell({required this.item});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(item.icon, size: 12, color: c.textMuted),
            SizedBox(width: DsSpacing.x2),
            Text(item.label,
                style: DsType.eyebrow(color: c.textMuted)
                    .copyWith(letterSpacing: 1.2)),
          ],
        ),
        SizedBox(height: 4),
        Text(
          item.value,
          style: DsType.label(color: c.textBright),
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
