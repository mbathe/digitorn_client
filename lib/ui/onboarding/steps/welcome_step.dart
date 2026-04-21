import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../design/ds.dart';
import '../../../theme/app_theme.dart';
import '../../ds/ds.dart';
import '../wizard_step_scaffold.dart';

/// Opening step — brand mark + platform positioning. Features an
/// animated count that lands on "200+ apps" to set scale
/// expectations on the very first screen.
class WelcomeStep extends StatelessWidget {
  const WelcomeStep({super.key});

  @override
  Widget build(BuildContext context) {
    return WizardStepScaffold(
      eyebrow: 'onboarding.welcome_eyebrow'.tr(),
      title: 'onboarding.welcome_title_long'.tr(),
      subtitle: 'onboarding.welcome_subtitle_long'.tr(),
      nextLabel: 'onboarding.welcome_cta'.tr(),
      illustration: const _WelcomeIllustration(),
      content: const _ScaleRow(),
    );
  }
}

class _WelcomeIllustration extends StatefulWidget {
  const _WelcomeIllustration();

  @override
  State<_WelcomeIllustration> createState() => _WelcomeIllustrationState();
}

class _WelcomeIllustrationState extends State<_WelcomeIllustration>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final scale = 1.0 + 0.015 * (_c.value - 0.5);
        return Transform.scale(
          scale: scale,
          child: const Center(child: DsBrandMark(size: 96)),
        );
      },
    );
  }
}

class _ScaleRow extends StatelessWidget {
  const _ScaleRow();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        Wrap(
          spacing: DsSpacing.x8,
          runSpacing: DsSpacing.x5,
          alignment: WrapAlignment.center,
          children: [
            _StatBlock(
              count: 200,
              suffix: '+',
              label: 'onboarding.stat_hub_label'.tr(),
              delayMs: 0,
            ),
            _StatBlock(
              count: 5,
              suffix: ' min',
              label: 'onboarding.stat_builder_label'.tr(),
              delayMs: 300,
            ),
            _StatBlock(
              count: 1,
              suffix: ' runtime',
              label: 'onboarding.stat_runtime_label'.tr(),
              delayMs: 600,
            ),
          ],
        ),
        SizedBox(height: DsSpacing.x7),
        Container(
          width: 48,
          height: 1,
          color: c.border,
        ),
      ],
    );
  }
}

class _StatBlock extends StatefulWidget {
  final int count;
  final String suffix;
  final String label;
  final int delayMs;

  const _StatBlock({
    required this.count,
    required this.suffix,
    required this.label,
    required this.delayMs,
  });

  @override
  State<_StatBlock> createState() => _StatBlockState();
}

class _StatBlockState extends State<_StatBlock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    Future.delayed(Duration(milliseconds: widget.delayMs), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final t = DsCurve.decelSoft.transform(_c.value);
        final value = (widget.count * t).round();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '$value',
                  style: DsType.display(
                    size: 40,
                    color: c.textBright,
                    weight: FontWeight.w600,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    widget.suffix,
                    style: DsType.h2(color: c.accentPrimary)
                        .copyWith(fontSize: 18),
                  ),
                ),
              ],
            ),
            SizedBox(height: DsSpacing.x1),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(
                widget.label,
                textAlign: TextAlign.center,
                style: DsType.caption(color: c.textMuted),
              ),
            ),
          ],
        );
      },
    );
  }
}
