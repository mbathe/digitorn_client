import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../design/ds.dart';
import '../../../services/preferences_service.dart';
import '../../../services/theme_service.dart';
import '../../../theme/app_theme.dart';
import '../../ds/ds.dart';
import '../wizard_nav.dart';
import '../wizard_step_scaffold.dart';

class ThemeStep extends StatefulWidget {
  const ThemeStep({super.key});

  @override
  State<ThemeStep> createState() => _ThemeStepState();
}

class _ThemeStepState extends State<ThemeStep> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      WizardNav.of(context).setCanAdvance(true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final theme = ThemeService();
    final prefs = PreferencesService();
    final compact = DsBreakpoint.isCompact(context);

    return ListenableBuilder(
      listenable: Listenable.merge([theme, prefs]),
      builder: (_, _) {
        return WizardStepScaffold(
          eyebrow: 'onboarding.step_02'.tr(),
          title: 'onboarding.theme_title_long'.tr(),
          subtitle: 'onboarding.theme_subtitle_long'.tr(),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SectionLabel(label: 'onboarding.language'.tr(), c: c),
              SizedBox(height: DsSpacing.x4),
              _Segmented<String>(
                value: prefs.language,
                options: const [
                  _Opt('en', 'English', Icons.language),
                  _Opt('fr', 'Français', Icons.translate),
                ],
                onChanged: (v) => prefs.setLanguage(v),
              ),
              SizedBox(height: DsSpacing.x7),
              _SectionLabel(label: 'onboarding.mode'.tr(), c: c),
              SizedBox(height: DsSpacing.x4),
              _Segmented<ThemeMode>(
                value: theme.mode,
                options: [
                  _Opt(ThemeMode.system, 'onboarding.mode_system'.tr(),
                      Icons.auto_mode),
                  _Opt(ThemeMode.light, 'onboarding.mode_light'.tr(),
                      Icons.light_mode_outlined),
                  _Opt(ThemeMode.dark, 'onboarding.mode_dark'.tr(),
                      Icons.dark_mode_outlined),
                ],
                onChanged: (v) => theme.setMode(v),
              ),
              SizedBox(height: DsSpacing.x7),
              _SectionLabel(label: 'onboarding.palette'.tr(), c: c),
              SizedBox(height: DsSpacing.x4),
              _PaletteGrid(
                selected: theme.palette,
                onChanged: (p) => theme.setPalette(p),
                compact: compact,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  final AppColors c;
  const _SectionLabel({required this.label, required this.c});

  @override
  Widget build(BuildContext context) {
    return Text(label, style: DsType.eyebrow(color: c.textMuted));
  }
}

class _Opt<T> {
  final T value;
  final String label;
  final IconData icon;
  const _Opt(this.value, this.label, this.icon);
}

class _Segmented<T> extends StatelessWidget {
  final T value;
  final List<_Opt<T>> options;
  final ValueChanged<T> onChanged;
  const _Segmented({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(DsRadius.input),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          for (final opt in options)
            Expanded(
              child: _SegItem(
                selected: value == opt.value,
                label: opt.label,
                icon: opt.icon,
                onTap: () => onChanged(opt.value),
              ),
            ),
        ],
      ),
    );
  }
}

class _SegItem extends StatelessWidget {
  final bool selected;
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _SegItem({
    required this.selected,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: DsDuration.fast,
          curve: DsCurve.decelSnap,
          height: 36,
          decoration: BoxDecoration(
            color: selected ? c.surfaceAlt : Colors.transparent,
            borderRadius: BorderRadius.circular(DsRadius.xs),
            border: Border.all(
              color: selected ? c.borderHover : Colors.transparent,
            ),
            boxShadow: selected ? DsElevation.raise(c.shadow) : null,
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: selected ? c.textBright : c.textMuted,
              ),
              SizedBox(width: DsSpacing.x3),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: DsType.caption(
                    color: selected ? c.textBright : c.textMuted,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PaletteGrid extends StatelessWidget {
  final AppPalette selected;
  final ValueChanged<AppPalette> onChanged;
  final bool compact;
  const _PaletteGrid({
    required this.selected,
    required this.onChanged,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final ordered = [
      AppPalette.obsidian,
      AppPalette.defaultTheme,
      AppPalette.midnight,
      AppPalette.oled,
      AppPalette.nord,
      AppPalette.solarized,
    ];
    // Wrap children must have a BOUNDED width — ``double.infinity``
    // inside a Wrap becomes "give me all the space", which at best
    // forces one-card-per-row and at worst RenderFlex-overflows when
    // the parent's own width hasn't been settled yet. On compact
    // viewports we switch to a Column so each card stretches to the
    // full (bounded) column width cleanly.
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final p in ordered) ...[
            _PaletteCard(
              palette: p,
              selected: selected == p,
              onTap: () => onChanged(p),
            ),
            SizedBox(height: DsSpacing.x3),
          ],
        ],
      );
    }
    return Wrap(
      spacing: DsSpacing.x3,
      runSpacing: DsSpacing.x3,
      children: [
        for (final p in ordered)
          SizedBox(
            width: 168,
            child: _PaletteCard(
              palette: p,
              selected: selected == p,
              onTap: () => onChanged(p),
            ),
          ),
      ],
    );
  }
}

class _PaletteCard extends StatelessWidget {
  final AppPalette palette;
  final bool selected;
  final VoidCallback onTap;
  const _PaletteCard({
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final preview = AppPalettes.resolve(palette, Brightness.dark);
    final recommended = palette == AppPalette.obsidian;
    return DsCard(
      selected: selected,
      onTap: onTap,
      padding: EdgeInsets.all(DsSpacing.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Swatches(preview: preview),
              const Spacer(),
              if (recommended)
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
                    'onboarding.pick_badge'.tr(),
                    style: DsType.micro(color: c.accentPrimary)
                        .copyWith(letterSpacing: 1.4, fontWeight: FontWeight.w700),
                  ),
                ),
            ],
          ),
          SizedBox(height: DsSpacing.x4),
          Text(palette.label, style: DsType.h3(color: c.textBright)),
          SizedBox(height: DsSpacing.x1),
          Text(
            palette.description,
            style: DsType.micro(color: c.textMuted)
                .copyWith(height: 1.4, fontSize: 11.5),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _Swatches extends StatelessWidget {
  final AppColors preview;
  const _Swatches({required this.preview});

  @override
  Widget build(BuildContext context) {
    final colors = [
      preview.bg,
      preview.surface,
      preview.accentPrimary,
      preview.accentSecondary,
    ];
    // Negative margin on Container is a Flutter assertion violation
    // (``container.dart:271`` — margin.isNonNegative). The swatches
    // need a -4 px overlap to look like a chip stack, so we express
    // the overlap through ``Transform.translate`` instead: same
    // visual effect, no Container constraint check triggered.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < colors.length; i++)
          Transform.translate(
            offset: Offset(i == 0 ? 0 : -4.0 * i, 0),
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: colors[i],
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.black.withValues(alpha: 0.15),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
