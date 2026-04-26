/// UserMenuButton — circular avatar at the bottom of the activity bar.
/// Tap → floating menu opening upward to the right with quick actions:
///   • Header   — avatar + display name + email
///   • Settings — opens the Settings panel (ActivePanel.settings)
///   • Language — expand-in-place sub-list of 11 locales
///   • Theme    — expand-in-place sub-list (System / Light / Dark)
///   • Help     — opens Settings → About
///   • Log out  — calls AuthService.logout()
///
/// Mirror of web `UserMenuButton` in
/// digitorn_web/src/components/shell/user-menu.tsx. Closes on outside
/// click, Escape key, or item selection.
library;

import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, KeyDownEvent;
import 'package:provider/provider.dart';

import '../../main.dart' show AppState, ActivePanel;
import '../../services/auth_service.dart';
import '../../services/preferences_service.dart';
import '../../services/theme_service.dart';
import '../../theme/app_theme.dart';
import '../ds/ds_avatar.dart';

class UserMenuButton extends StatefulWidget {
  const UserMenuButton({super.key});

  @override
  State<UserMenuButton> createState() => _UserMenuButtonState();
}

class _UserMenuButtonState extends State<UserMenuButton> {
  bool _hover = false;
  bool _open = false;
  OverlayEntry? _overlay;
  final LayerLink _link = LayerLink();

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  String _seed() {
    final u = AuthService().currentUser;
    return u?.displayName ?? u?.email ?? u?.userId ?? 'Digitorn';
  }

  String _initials(String seed) {
    final parts = seed.trim()
        .split(RegExp(r'[\s@._-]+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'D';
    if (parts.length == 1) {
      final s = parts[0];
      return s.substring(0, s.length < 2 ? s.length : 2).toUpperCase();
    }
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  void _toggle() {
    if (_open) {
      _close();
    } else {
      _show();
    }
  }

  void _close() {
    _overlay?.remove();
    _overlay = null;
    // Also clear `_hover` — while the menu is open the backdrop
    // OverlayEntry sits over the button and swallows pointer events,
    // so the MouseRegion never receives its `onExit`. Without this
    // reset, the focus ring lingers after the menu closes even though
    // the cursor is no longer over the avatar.
    if (_open || _hover) {
      setState(() {
        _open = false;
        _hover = false;
      });
    }
  }

  void _show() {
    _overlay = OverlayEntry(
      builder: (ctx) => _UserMenuOverlay(
        link: _link,
        onDismiss: _close,
      ),
    );
    Overlay.of(context).insert(_overlay!);
    setState(() => _open = true);
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthService().currentUser;
    final seed = _seed();
    final initials = _initials(seed);
    final c = context.colors;
    final tooltip = user?.displayName ?? user?.userId ?? 'Account';

    return CompositedTransformTarget(
      link: _link,
      child: Tooltip(
        message: _open ? '' : tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: _toggle,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: (_hover || _open)
                      ? c.accentPrimary
                      : Colors.transparent,
                  width: 1,
                ),
                boxShadow: _open
                    ? [
                        BoxShadow(
                          color: c.accentPrimary.withValues(alpha: 0.20),
                          blurRadius: 0,
                          spreadRadius: 3,
                        ),
                      ]
                    : null,
              ),
              alignment: Alignment.center,
              child: DsAvatar(
                seed: seed,
                initials: initials,
                size: 24,
                showBorder: false,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Overlay ───────────────────────────────────────────────────────────────

class _UserMenuOverlay extends StatefulWidget {
  final LayerLink link;
  final VoidCallback onDismiss;
  const _UserMenuOverlay({required this.link, required this.onDismiss});

  @override
  State<_UserMenuOverlay> createState() => _UserMenuOverlayState();
}

enum _Submenu { none, language, theme }

class _UserMenuOverlayState extends State<_UserMenuOverlay> {
  _Submenu _submenu = _Submenu.none;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _onSelect(VoidCallback action) {
    action();
    widget.onDismiss();
  }

  Future<void> _logout() async {
    widget.onDismiss();
    final ctx = context;
    await AuthService().logout();
    // Navigation — pop everything, the AuthGate at the root will
    // route to login automatically when currentUser becomes null.
    if (ctx.mounted) {
      Navigator.of(ctx, rootNavigator: true)
          .popUntil((r) => r.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Direction-aware anchoring. In LTR the activity bar sits on the
    // LEFT edge → menu blooms upward-and-right of the avatar (target's
    // top-right ↔ follower's bottom-left, +8 px x). In RTL the bar
    // flips to the RIGHT edge → menu must bloom upward-and-left
    // (target's top-left ↔ follower's bottom-right, -8 px x) otherwise
    // it spawns off-screen past the right viewport edge.
    final isRtl = Directionality.of(context) == ui.TextDirection.rtl;
    final targetAnchor = isRtl ? Alignment.topLeft : Alignment.topRight;
    final followerAnchor = isRtl ? Alignment.bottomRight : Alignment.bottomLeft;
    final anchorOffset = Offset(isRtl ? -8 : 8, 0);
    return Stack(
      children: [
        // Backdrop — tap anywhere outside to close.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onDismiss,
            child: const SizedBox.expand(),
          ),
        ),
        // Anchored panel
        CompositedTransformFollower(
          link: widget.link,
          targetAnchor: targetAnchor,
          followerAnchor: followerAnchor,
          offset: anchorOffset,
          showWhenUnlinked: false,
          child: Material(
            color: Colors.transparent,
            child: Focus(
              focusNode: _focus,
              autofocus: true,
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.escape) {
                  widget.onDismiss();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: Container(
                width: 280,
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height - 24,
                ),
                decoration: BoxDecoration(
                  color: c.surface,
                  border: Border.all(color: c.border, width: 1),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: c.shadow.withValues(alpha: 0.45),
                      blurRadius: 38,
                      offset: const Offset(0, 18),
                    ),
                    BoxShadow(
                      color: c.shadow.withValues(alpha: 0.30),
                      blurRadius: 14,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Header(),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _MenuRow(
                              icon: Icons.settings_outlined,
                              label: 'sidebar.settings'.tr(),
                              shortcut: 'Ctrl+,',
                              onTap: () => _onSelect(() {
                                final state = context.read<AppState>();
                                state.setPanel(ActivePanel.settings);
                              }),
                            ),
                            _MenuRow(
                              icon: Icons.language_rounded,
                              label: 'sidebar.menu_language'.tr(),
                              trailing: _LanguageTrailing(
                                expanded: _submenu == _Submenu.language,
                              ),
                              onTap: () => setState(() {
                                _submenu = _submenu == _Submenu.language
                                    ? _Submenu.none
                                    : _Submenu.language;
                              }),
                            ),
                            if (_submenu == _Submenu.language)
                              _LanguageList(onAfterPick: widget.onDismiss),
                            _MenuRow(
                              icon: Icons.palette_outlined,
                              label: 'sidebar.menu_theme'.tr(),
                              trailing: _ThemeTrailing(
                                expanded: _submenu == _Submenu.theme,
                              ),
                              onTap: () => setState(() {
                                _submenu = _submenu == _Submenu.theme
                                    ? _Submenu.none
                                    : _Submenu.theme;
                              }),
                            ),
                            if (_submenu == _Submenu.theme) const _ThemeList(),
                            _MenuRow(
                              icon: Icons.help_outline_rounded,
                              label: 'sidebar.menu_help'.tr(),
                              onTap: () => _onSelect(() {
                                final state = context.read<AppState>();
                                state.setPanel(ActivePanel.settings);
                              }),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Container(
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(color: c.border, width: 1),
                        ),
                      ),
                      child: _MenuRow(
                        icon: Icons.logout_rounded,
                        label: 'auth.sign_out'.tr(),
                        danger: true,
                        onTap: _logout,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Header ────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final user = AuthService().currentUser;
    final seed = user?.displayName ?? user?.email ?? user?.userId ?? 'Digitorn';
    final parts = seed.trim()
        .split(RegExp(r'[\s@._-]+'))
        .where((p) => p.isNotEmpty)
        .toList();
    final initials = parts.isEmpty
        ? 'D'
        : parts.length == 1
            ? parts[0]
                .substring(0, parts[0].length < 2 ? parts[0].length : 2)
                .toUpperCase()
            : (parts.first[0] + parts.last[0]).toUpperCase();
    final displayName = user?.displayName ?? user?.userId ?? '—';
    final email = user?.email;
    final showEmail = email != null && email.isNotEmpty && email != displayName;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: c.border, width: 1),
        ),
      ),
      child: Row(
        children: [
          DsAvatar(seed: seed, initials: initials, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.textBright,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.1,
                  ),
                ),
                if (showEmail)
                  Text(
                    email,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: c.textMuted,
                      fontSize: 11.5,
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

// ─── Menu row (generic) ────────────────────────────────────────────────────

class _MenuRow extends StatefulWidget {
  final IconData icon;
  final String label;
  final String? shortcut;
  final Widget? trailing;
  final VoidCallback onTap;
  final bool danger;
  const _MenuRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.shortcut,
    this.trailing,
    this.danger = false,
  });

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = widget.danger
        ? c.red
        : (_h ? c.textBright : c.text);
    final iconFg = widget.danger
        ? c.red
        : (_h ? c.textBright : c.textMuted);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          color: _h ? c.surfaceAlt : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: [
              Icon(widget.icon, size: 14, color: iconFg),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (widget.shortcut != null)
                Text(
                  widget.shortcut!,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10.5,
                    color: c.textDim,
                  ),
                ),
              if (widget.trailing != null) widget.trailing!,
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Language sub-list ────────────────────────────────────────────────────

class _LanguageTrailing extends StatelessWidget {
  final bool expanded;
  const _LanguageTrailing({required this.expanded});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final prefs = context.watch<PreferencesService>();
    final current = PreferencesService.languages
        .firstWhere((l) => l.$1 == prefs.language,
            orElse: () => PreferencesService.languages.first);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(current.$3, style: const TextStyle(fontSize: 13)),
        const SizedBox(width: 4),
        AnimatedRotation(
          turns: expanded ? 0.25 : 0,
          duration: const Duration(milliseconds: 140),
          child: Icon(Icons.chevron_right_rounded,
              size: 14, color: c.textMuted),
        ),
      ],
    );
  }
}

class _LanguageList extends StatelessWidget {
  final VoidCallback onAfterPick;
  const _LanguageList({required this.onAfterPick});

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<PreferencesService>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
                final parts = l.$1.split('-');
                await context.setLocale(
                  parts.length == 2
                      ? Locale(parts[0], parts[1])
                      : Locale(l.$1),
                );
                if (!context.mounted) return;
                onAfterPick();
              },
            ),
        ],
      ),
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
    final accent = c.accentPrimary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: widget.selected
                ? Color.lerp(c.surface, accent, 0.10)
                : (_h ? c.surfaceAlt : Colors.transparent),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Text(widget.flag, style: const TextStyle(fontSize: 14)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: widget.selected
                        ? FontWeight.w600
                        : FontWeight.w500,
                    color: widget.selected ? accent : c.text,
                  ),
                ),
              ),
              if (widget.selected)
                Icon(Icons.check_rounded, size: 13, color: accent),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Theme sub-list ───────────────────────────────────────────────────────

class _ThemeTrailing extends StatelessWidget {
  final bool expanded;
  const _ThemeTrailing({required this.expanded});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final theme = context.watch<ThemeService>();
    final (icon, label) = switch (theme.mode) {
      ThemeMode.system =>
        (Icons.brightness_auto_outlined, 'sidebar.menu_system_theme'.tr()),
      ThemeMode.light =>
        (Icons.light_mode_outlined, 'sidebar.light_mode'.tr()),
      ThemeMode.dark =>
        (Icons.dark_mode_outlined, 'sidebar.dark_mode'.tr()),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: c.textMuted),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            color: c.textMuted,
          ),
        ),
        const SizedBox(width: 4),
        AnimatedRotation(
          turns: expanded ? 0.25 : 0,
          duration: const Duration(milliseconds: 140),
          child: Icon(Icons.chevron_right_rounded,
              size: 14, color: c.textMuted),
        ),
      ],
    );
  }
}

class _ThemeList extends StatelessWidget {
  const _ThemeList();

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeService>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ThemeRow(
            icon: Icons.brightness_auto_outlined,
            label: 'sidebar.menu_system_theme'.tr(),
            selected: theme.mode == ThemeMode.system,
            onTap: () => theme.setMode(ThemeMode.system),
          ),
          _ThemeRow(
            icon: Icons.light_mode_outlined,
            label: 'sidebar.light_mode'.tr(),
            selected: theme.mode == ThemeMode.light,
            onTap: () => theme.setMode(ThemeMode.light),
          ),
          _ThemeRow(
            icon: Icons.dark_mode_outlined,
            label: 'sidebar.dark_mode'.tr(),
            selected: theme.mode == ThemeMode.dark,
            onTap: () => theme.setMode(ThemeMode.dark),
          ),
        ],
      ),
    );
  }
}

class _ThemeRow extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ThemeRow({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_ThemeRow> createState() => _ThemeRowState();
}

class _ThemeRowState extends State<_ThemeRow> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final accent = c.accentPrimary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: widget.selected
                ? Color.lerp(c.surface, accent, 0.10)
                : (_h ? c.surfaceAlt : Colors.transparent),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 13,
                  color: widget.selected ? accent : c.textMuted),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: widget.selected
                        ? FontWeight.w600
                        : FontWeight.w500,
                    color: widget.selected ? accent : c.text,
                  ),
                ),
              ),
              if (widget.selected)
                Icon(Icons.check_rounded, size: 13, color: accent),
            ],
          ),
        ),
      ),
    );
  }
}
