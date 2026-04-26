/// "About" section — version, build info, links, keyboard shortcuts
/// shortcut, diagnostics shortcut. The plumbing equivalent of a
/// well-organised "About this app" pane.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../theme/app_theme.dart';
import '../../keyboard_shortcuts_sheet.dart';
import '../diagnostics_page.dart';
import '_shared.dart';

class AboutSection extends StatefulWidget {
  const AboutSection({super.key});

  @override
  State<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<AboutSection> {
  String _versionLine = 'Loading…';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      final platform = _platformLabel();
      setState(() {
        _versionLine = 'v${info.version}+${info.buildNumber} · $platform';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _versionLine = 'Unknown build · Flutter');
    }
  }

  String _platformLabel() {
    final t = Theme.of(context).platform;
    switch (t) {
      case TargetPlatform.windows:
        return 'Flutter Windows desktop';
      case TargetPlatform.macOS:
        return 'Flutter macOS desktop';
      case TargetPlatform.linux:
        return 'Flutter Linux desktop';
      case TargetPlatform.android:
        return 'Flutter Android';
      case TargetPlatform.iOS:
        return 'Flutter iOS';
      default:
        return 'Flutter';
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SectionScaffold(
      title: 'settings.section_about'.tr(),
      subtitle: 'settings.section_about_subtitle'.tr(),
      icon: Icons.info_outline_rounded,
      children: [
        // Hero
        Container(
          padding: const EdgeInsets.all(24),
          margin: const EdgeInsets.only(bottom: 24),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.border),
          ),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                      colors: [c.accentPrimary, c.accentSecondary]),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: c.glow.withValues(alpha: 0.35),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Icon(Icons.bolt_rounded,
                    size: 28, color: c.onAccent),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Digitorn Client',
                      style: GoogleFonts.inter(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: c.textBright,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _versionLine,
                      style: GoogleFonts.firaCode(
                        fontSize: 11,
                        color: c.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        SettingsCard(
          label: 'settings.about_tools'.tr(),
          children: [
            SettingsRow(
              icon: Icons.network_check_rounded,
              label: 'settings.about_diagnostics'.tr(),
              subtitle: 'settings.about_diagnostics_hint'.tr(),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const DiagnosticsPage(),
                ),
              ),
              trailing:
                  Icon(Icons.chevron_right_rounded, size: 16, color: c.textDim),
            ),
            SettingsRow(
              icon: Icons.keyboard_alt_outlined,
              label: 'settings.about_keyboard_shortcuts'.tr(),
              subtitle: 'settings.about_keyboard_shortcuts_hint'.tr(),
              onTap: () => KeyboardShortcutsSheet.show(context),
              trailing:
                  Icon(Icons.chevron_right_rounded, size: 16, color: c.textDim),
            ),
          ],
        ),

        SettingsCard(
          label: 'settings.about_links'.tr(),
          children: [
            _LinkRow(
              icon: Icons.book_outlined,
              label: 'settings.about_documentation'.tr(),
              url: 'https://docs.digitorn.ai',
            ),
            _LinkRow(
              icon: Icons.bug_report_outlined,
              label: 'settings.about_report_bug'.tr(),
              url: 'https://github.com/digitorn/client/issues',
            ),
            _LinkRow(
              icon: Icons.code_rounded,
              label: 'settings.about_github'.tr(),
              url: 'https://github.com/digitorn/client',
            ),
          ],
        ),
      ],
    );
  }
}

class _LinkRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String url;
  const _LinkRow({
    required this.icon,
    required this.label,
    required this.url,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SettingsRow(
      icon: icon,
      label: label,
      subtitle: url,
      onTap: () => launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication),
      trailing:
          Icon(Icons.open_in_new_rounded, size: 14, color: c.textDim),
    );
  }
}
