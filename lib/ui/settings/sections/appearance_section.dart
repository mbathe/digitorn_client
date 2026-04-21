/// "Appearance" section — theme, accent colour, density.
///
/// Theme writes into [ThemeService]; accent and density write into
/// [PreferencesService] (the accent is currently a passive setting
/// the rest of the app can read at any time).
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../../services/preferences_service.dart';
import '../../../services/theme_service.dart';
import '../../../theme/app_theme.dart';
import '_shared.dart';

class AppearanceSection extends StatelessWidget {
  const AppearanceSection({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeService>();
    final prefs = context.watch<PreferencesService>();
    return SectionScaffold(
      title: 'settings.section_appearance'.tr(),
      subtitle: 'settings.section_appearance_subtitle'.tr(),
      icon: Icons.palette_outlined,
      children: [
        // ── Theme ───────────────────────────────────────────────
        SettingsCard(
          label: 'settings.theme_dark_mode'.tr().toUpperCase(),
          children: [
            SettingsRow(
              icon: theme.mode == ThemeMode.system
                  ? Icons.brightness_auto_outlined
                  : theme.isDark
                      ? Icons.dark_mode_outlined
                      : Icons.light_mode_outlined,
              label: switch (theme.mode) {
                ThemeMode.dark => 'settings.theme_dark_mode'.tr(),
                ThemeMode.light => 'settings.theme_light_mode'.tr(),
                ThemeMode.system => 'settings.theme_follow_system'.tr(),
              },
              subtitle: theme.mode == ThemeMode.system
                  ? 'settings.theme_follow_os'.tr()
                  : 'settings.theme_switch_instant'.tr(),
              trailing: SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: ThemeMode.dark,
                    icon: const Icon(Icons.dark_mode_outlined, size: 14),
                    label: Text('settings.theme_dark'.tr(),
                        style: GoogleFonts.inter(fontSize: 11)),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    icon: const Icon(Icons.light_mode_outlined, size: 14),
                    label: Text('settings.theme_light'.tr(),
                        style: GoogleFonts.inter(fontSize: 11)),
                  ),
                  ButtonSegment(
                    value: ThemeMode.system,
                    icon:
                        const Icon(Icons.brightness_auto_outlined, size: 14),
                    label: Text('settings.theme_system'.tr(),
                        style: GoogleFonts.inter(fontSize: 11)),
                  ),
                ],
                selected: {theme.mode},
                onSelectionChanged: (s) => theme.setMode(s.first),
              ),
            ),
          ],
        ),

        // ── Palette ─────────────────────────────────────────────
        SettingsCard(
          label: 'settings.palette'.tr(),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'settings.palette_subtitle'.tr(),
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: context.colors.textBright,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'settings.palette_description'.tr(),
                    style: GoogleFonts.inter(
                      fontSize: 11.5,
                      color: context.colors.textMuted,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final p in AppPalette.values)
                        _PaletteCard(
                          palette: p,
                          selected: theme.palette == p,
                          isDark: theme.isDark,
                          onTap: () => theme.setPalette(p),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),

        // NOTE: the "Accent" swatch picker used to live here but
        // the palette selector at the top of the page already
        // drives every accent colour. Kept commented out so the
        // i18n keys (settings.accent / settings.accent_title /
        // settings.accent_description) remain traceable — delete
        // from the locales in a follow-up pass.

        // ── Density ─────────────────────────────────────────────
        SettingsCard(
          label: 'settings.density'.tr(),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'settings.density_title'.tr(),
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: context.colors.textBright,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'settings.density_description'.tr(),
                    style: GoogleFonts.inter(
                      fontSize: 11.5,
                      color: context.colors.textMuted,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 14),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [
                      for (final d in PreferencesService.densities)
                        ButtonSegment(
                          value: d.$1,
                          label: Text(
                            d.$2,
                            style: GoogleFonts.inter(fontSize: 11),
                          ),
                        ),
                    ],
                    selected: {prefs.density},
                    onSelectionChanged: (s) => prefs.setDensity(s.first),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _PaletteCard extends StatefulWidget {
  final AppPalette palette;
  final bool selected;
  final bool isDark;
  final VoidCallback onTap;
  const _PaletteCard({
    required this.palette,
    required this.selected,
    required this.isDark,
    required this.onTap,
  });

  @override
  State<_PaletteCard> createState() => _PaletteCardState();
}

class _PaletteCardState extends State<_PaletteCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Each card previews the palette in its own colours — so the user
    // sees a literal swatch, not the current theme.
    final brightness = widget.isDark &&
            widget.palette != AppPalette.solarized
        ? Brightness.dark
        : (widget.palette.hasLight ? Brightness.light : Brightness.dark);
    final preview = AppPalettes.resolve(widget.palette, brightness);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 148,
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.selected
                  ? c.accentPrimary
                  : (_hover ? c.borderHover : c.border),
              width: widget.selected ? 1.5 : 1,
            ),
            boxShadow: widget.selected
                ? [
                    BoxShadow(
                      color: c.glow.withValues(alpha: 0.28),
                      blurRadius: 16,
                      spreadRadius: -4,
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Swatch strip showing the palette's key colors.
              Container(
                height: 52,
                decoration: BoxDecoration(
                  color: preview.bg,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(9),
                    topRight: Radius.circular(9),
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              preview.bg,
                              Color.lerp(preview.bg,
                                      preview.accentPrimary, 0.18) ??
                                  preview.bg,
                              Color.lerp(preview.bg,
                                      preview.accentSecondary, 0.22) ??
                                  preview.bg,
                            ],
                          ),
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(9),
                            topRight: Radius.circular(9),
                          ),
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Row(
                          children: [
                            _Dot(color: preview.accentPrimary),
                            const SizedBox(width: 6),
                            _Dot(color: preview.accentSecondary),
                            const SizedBox(width: 6),
                            _Dot(color: preview.green),
                            const SizedBox(width: 6),
                            _Dot(color: preview.red),
                          ],
                        ),
                      ),
                    ),
                    if (widget.selected)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            color: preview.accentPrimary,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.check_rounded,
                              size: 12, color: preview.onAccent),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'palettes.${widget.palette.id}'.tr(),
                      style: GoogleFonts.inter(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: c.textBright,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'palettes.${widget.palette.id}_desc'.tr(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 10.5,
                        color: c.textMuted,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  const _Dot({required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: color.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}
