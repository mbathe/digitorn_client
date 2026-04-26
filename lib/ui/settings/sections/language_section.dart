/// "Language & region" section. Live-wired to easy_localization:
/// picking a language rebuilds the app tree in the new locale
/// immediately. The choice is also persisted via PreferencesService
/// so it sticks across restarts.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../../services/preferences_service.dart';
import '../../../theme/app_theme.dart';
import '_shared.dart';

class LanguageSection extends StatelessWidget {
  const LanguageSection({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<PreferencesService>();
    return SectionScaffold(
      title: 'settings.section_language'.tr(),
      subtitle: 'settings.section_language_subtitle'.tr(),
      icon: Icons.language_rounded,
      children: [
        SettingsCard(
          label: 'settings.language_interface'.tr(),
          children: [
            for (final l in PreferencesService.languages)
              _LanguageRow(
                code: l.$1,
                label: l.$2,
                flag: l.$3,
                selected: prefs.language == l.$1,
                onTap: () async {
                  await prefs.setLanguage(l.$1);
                  if (!context.mounted) return;
                  // zh-CN ships with a country code; the bare codes ship
                  // language-only. Split before constructing the Locale
                  // so easy_localization picks the right ARB.
                  final parts = l.$1.split('-');
                  await context.setLocale(
                    parts.length == 2
                        ? Locale(parts[0], parts[1])
                        : Locale(l.$1),
                  );
                },
              ),
          ],
        ),
      ],
    );
  }
}

class _LanguageRow extends StatefulWidget {
  final String code;
  final String label;
  final String flag;
  final bool selected;
  final VoidCallback onTap;
  const _LanguageRow({
    required this.code,
    required this.label,
    required this.flag,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_LanguageRow> createState() => _LanguageRowState();
}

class _LanguageRowState extends State<_LanguageRow> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          color: widget.selected
              ? c.accentPrimary.withValues(alpha: 0.06)
              : _h
                  ? c.surfaceAlt
                  : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Text(widget.flag, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.label,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: c.textBright,
                        fontWeight: widget.selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                    Text(
                      widget.code,
                      style: GoogleFonts.firaCode(
                        fontSize: 10,
                        color: c.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.selected)
                Icon(Icons.check_circle_rounded,
                    size: 17, color: c.accentPrimary),
            ],
          ),
        ),
      ),
    );
  }
}
