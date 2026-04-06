import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../services/auth_service.dart';
import '../../services/theme_service.dart';
import '../../theme/app_theme.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeService>();
    final auth = AuthService();
    final c = context.colors;

    return Container(
      color: c.bg,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(32),
            children: [
              Text('Settings',
                style: GoogleFonts.inter(
                  fontSize: 24, fontWeight: FontWeight.w700, color: c.text)),
              const SizedBox(height: 32),

              // ── Appearance ──────────────────────────────────────────────
              _Section(title: 'Appearance', children: [
                _SettingRow(
                  icon: Icons.palette_outlined,
                  label: 'Theme',
                  trailing: SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                      ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                    ],
                    selected: {theme.mode},
                    onSelectionChanged: (_) => theme.toggle(),
                    style: ButtonStyle(
                      textStyle: WidgetStatePropertyAll(
                          GoogleFonts.inter(fontSize: 12)),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 16),

              // ── Connection ──────────────────────────────────────────────
              _Section(title: 'Connection', children: [
                _SettingRow(
                  icon: Icons.dns_outlined,
                  label: 'Daemon URL',
                  subtitle: auth.baseUrl,
                ),
                _SettingRow(
                  icon: Icons.person_outline,
                  label: 'User',
                  subtitle: auth.currentUser?.displayName ?? auth.currentUser?.userId ?? 'Unknown',
                ),
              ]),
              const SizedBox(height: 16),

              // ── Keyboard shortcuts ──────────────────────────────────────
              _Section(title: 'Keyboard Shortcuts', children: [
                _ShortcutRow(keys: 'Enter', action: 'Send message'),
                _ShortcutRow(keys: 'Shift + Enter', action: 'New line'),
                _ShortcutRow(keys: 'Escape', action: 'Stop agent'),
                _ShortcutRow(keys: 'Ctrl + N', action: 'New session'),
                _ShortcutRow(keys: 'Ctrl + L', action: 'Clear chat'),
              ]),
              const SizedBox(height: 32),

              // ── Logout ──────────────────────────────────────────────────
              Center(
                child: OutlinedButton.icon(
                  onPressed: () => auth.logout(),
                  icon: Icon(Icons.logout, size: 16, color: c.textMuted),
                  label: Text('Logout', style: GoogleFonts.inter(color: c.textMuted)),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: c.border),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
          style: GoogleFonts.inter(
            fontSize: 13, fontWeight: FontWeight.w600,
            color: c.textMuted, letterSpacing: 0.3)),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.border),
          ),
          child: Column(children: [
            for (int i = 0; i < children.length; i++) ...[
              children[i],
              if (i < children.length - 1)
                Divider(height: 1, color: c.border),
            ],
          ]),
        ),
      ],
    );
  }
}

class _SettingRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final Widget? trailing;
  const _SettingRow({
    required this.icon, required this.label,
    this.subtitle, this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 16, color: c.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: GoogleFonts.inter(fontSize: 13, color: c.text)),
                if (subtitle != null)
                  Text(subtitle!,
                    style: GoogleFonts.firaCode(fontSize: 11, color: c.textMuted)),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  final String keys;
  final String action;
  const _ShortcutRow({
    required this.keys, required this.action,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: c.surfaceAlt,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(keys,
              style: GoogleFonts.firaCode(fontSize: 11, color: c.text)),
          ),
          const SizedBox(width: 12),
          Text(action, style: GoogleFonts.inter(fontSize: 13, color: c.textMuted)),
        ],
      ),
    );
  }
}
