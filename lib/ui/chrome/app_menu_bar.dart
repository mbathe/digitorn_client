/// AppMenuBar — desktop menu bar (File / Window / Tools / Admin / Help).
///
/// Shown on Windows + Linux desktop only. macOS keeps its native top-of-
/// screen menu bar (we don't try to fight the OS on that). Web + mobile
/// get a `SizedBox.shrink()`.
///
/// Each entry is a real action wired to existing services / pages — no
/// decorative items. Entries are gated:
///   • Admin section visible only when `AuthService.currentUser.isAdmin`
///   • Recent Apps populated from `AppsService.apps` (max 5)
///   • Window controls hit `windowManager`
///
/// Mirror of the proposal in the convo: deliberately NOT redundant with
/// /settings (no theme / language / density / credentials shortcuts here)
/// and NOT app-scoped (no New Session / Clear Chat / Export Chat).
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../../main.dart' show AppState, rootNavigatorKey;
import '../../models/app_summary.dart';
import '../../services/apps_service.dart';
import '../../services/auth_service.dart';
import '../../services/onboarding_service.dart';
import '../../theme/app_theme.dart';
import '../admin/admin_console_page.dart';
import '../admin/quotas_admin_page.dart';
import '../approvals/approvals_page.dart';
import '../builder/builder_drafts_page.dart';
import '../command_palette.dart';
import '../global_search.dart';
import '../hub/hub_page.dart';
import '../keyboard_shortcuts_sheet.dart';

/// Convenience: which platforms get the in-window menu bar.
/// Windows + Linux only. macOS users expect the native OS menu bar
/// at the top of the screen (handled separately by PlatformMenuBar
/// when that's wired up — out of scope here).
bool _shouldShowMenuBar() {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;
}

class AppMenuBar extends StatefulWidget {
  const AppMenuBar({super.key});

  @override
  State<AppMenuBar> createState() => _AppMenuBarState();
}

class _AppMenuBarState extends State<AppMenuBar> {
  final MenuController _ctrl = MenuController();
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    if (!_shouldShowMenuBar()) return const SizedBox.shrink();

    final c = context.colors;
    // Watch the services so admin gating + recent-apps reflect live
    // changes without forcing the user to reopen the menu.
    final isAdmin = context.watch<AuthService>().currentUser?.isAdmin ?? false;
    final apps = context.watch<AppsService>().apps;
    final activeApp = context.watch<AppState>().activeApp;
    final recentApps = _orderedRecentApps(apps, activeApp?.appId);

    // Premium menu styling — matches the user-menu popup we use on the
    // sidebar avatar (12 px radius, hairline border, layered shadow).
    final premiumMenuStyle = MenuStyle(
      backgroundColor: WidgetStatePropertyAll(c.surface),
      surfaceTintColor: WidgetStatePropertyAll(c.surface),
      elevation: const WidgetStatePropertyAll(0),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(vertical: 6),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c.border, width: 1),
        ),
      ),
      shadowColor: WidgetStatePropertyAll(c.shadow.withValues(alpha: 0.45)),
    );
    final premiumButtonStyle = ButtonStyle(
      // Width auto-sizes to content (icon + label + shortcut hint).
      // Height 36 + horizontal pad 14 + vertical pad 8 leaves enough
      // air on both axes so neither the label nor a shortcut on the
      // right ever brushes the rounded corner / edge.
      minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      ),
      foregroundColor: WidgetStatePropertyAll(c.text),
      textStyle: WidgetStatePropertyAll(
        const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
      ),
      overlayColor: WidgetStatePropertyAll(c.surfaceAlt),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    );

    return MenuTheme(
      data: MenuThemeData(style: premiumMenuStyle),
      child: MenuButtonTheme(
        data: MenuButtonThemeData(style: premiumButtonStyle),
        child: MenuAnchor(
          controller: _ctrl,
          alignmentOffset: const Offset(0, 4),
          style: premiumMenuStyle,
          builder: (context, controller, _) {
            // Single hamburger trigger — matches the Claude / VSCode
            // pattern of a compact menu icon at the leading edge of
            // the title bar.
            return MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _hover = true),
              onExit: (_) => setState(() => _hover = false),
              child: GestureDetector(
                onTap: () => controller.isOpen
                    ? controller.close()
                    : controller.open(),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  width: 36,
                  height: 28,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: controller.isOpen
                        ? c.surfaceAlt
                        : (_hover ? c.surfaceAlt.withValues(alpha: 0.6) : Colors.transparent),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.menu_rounded,
                    size: 16,
                    color: (_hover || controller.isOpen) ? c.textBright : c.textMuted,
                  ),
                ),
              ),
            );
          },
          menuChildren: [
            _fileMenu(context, recentApps),
            _windowMenu(context),
            _toolsMenu(context),
            if (isAdmin) _adminMenu(context),
            _helpMenu(context),
          ],
        ),
      ),
    );
  }

  // ─── File ──────────────────────────────────────────────────────────

  Widget _fileMenu(BuildContext context, List<AppSummary> recentApps) {
    return SubmenuButton(
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.add_rounded, size: 16),
          onPressed: () => _pushPage(const BuilderDraftsPage()),
          child: Text('menubar.new_app'.tr()),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.extension_rounded, size: 16),
          onPressed: () => _pushPage(const HubPage()),
          child: Text('menubar.browse_hub'.tr()),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.architecture_outlined, size: 16),
          onPressed: () => _pushPage(const BuilderDraftsPage()),
          child: Text('menubar.builder_drafts'.tr()),
        ),
        SubmenuButton(
          leadingIcon: const Icon(Icons.history_rounded, size: 16),
          menuChildren: recentApps.isEmpty
              ? [
                  MenuItemButton(
                    onPressed: null,
                    child: Text('menubar.no_recent_apps'.tr()),
                  ),
                ]
              : [
                  for (final app in recentApps)
                    MenuItemButton(
                      onPressed: () => _activateApp(app),
                      child: Text(app.name),
                    ),
                ],
          child: Text('menubar.recent_apps'.tr()),
        ),
        const Divider(height: 8),
        MenuItemButton(
          leadingIcon: const Icon(Icons.exit_to_app_rounded, size: 16),
          onPressed: _quit,
          child: Text('menubar.quit'.tr()),
        ),
      ],
      child: Text('menubar.file'.tr()),
    );
  }

  // ─── Window ────────────────────────────────────────────────────────

  Widget _windowMenu(BuildContext context) {
    return SubmenuButton(
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.minimize_rounded, size: 16),
          onPressed: () async {
            try {
              await windowManager.minimize();
            } catch (_) {}
          },
          child: Text('menubar.minimize'.tr()),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.crop_square_rounded, size: 16),
          onPressed: () async {
            try {
              final maximised = await windowManager.isMaximized();
              if (maximised) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            } catch (_) {}
          },
          child: Text('menubar.maximize'.tr()),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.fullscreen_rounded, size: 16),
          shortcut: const SingleActivator(LogicalKeyboardKey.f11),
          onPressed: () async {
            try {
              final fs = await windowManager.isFullScreen();
              await windowManager.setFullScreen(!fs);
            } catch (_) {}
          },
          child: Text('menubar.fullscreen'.tr()),
        ),
      ],
      child: Text('menubar.window'.tr()),
    );
  }

  // ─── Tools ─────────────────────────────────────────────────────────

  Widget _toolsMenu(BuildContext context) {
    return SubmenuButton(
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.terminal_rounded, size: 16),
          shortcut: const SingleActivator(LogicalKeyboardKey.keyK, control: true),
          onPressed: _openCommandPalette,
          child: Text('menubar.command_palette'.tr()),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.swap_horiz_rounded, size: 16),
          shortcut: const SingleActivator(LogicalKeyboardKey.keyT, control: true),
          onPressed: _openQuickSwitcher,
          child: Text('menubar.quick_switcher'.tr()),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.search_rounded, size: 16),
          shortcut: const SingleActivator(LogicalKeyboardKey.keyP, control: true),
          onPressed: _openGlobalSearch,
          child: Text('menubar.global_search'.tr()),
        ),
      ],
      child: Text('menubar.tools'.tr()),
    );
  }

  // ─── Admin ─────────────────────────────────────────────────────────

  Widget _adminMenu(BuildContext context) {
    return SubmenuButton(
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.shield_rounded, size: 16),
          onPressed: () => _pushPage(const AdminConsolePage()),
          child: Text('menubar.admin_console'.tr()),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.front_hand_outlined, size: 16),
          onPressed: () => _pushPage(const ApprovalsPage()),
          child: Text('menubar.pending_approvals'.tr()),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.speed_rounded, size: 16),
          onPressed: () => _pushPage(const QuotasAdminPage()),
          child: Text('menubar.manage_quotas'.tr()),
        ),
      ],
      child: Text('menubar.admin'.tr()),
    );
  }

  // ─── Help ──────────────────────────────────────────────────────────

  Widget _helpMenu(BuildContext context) {
    return SubmenuButton(
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.book_outlined, size: 16),
          onPressed: () => _openUrl('https://docs.digitorn.ai'),
          child: Text('menubar.documentation'.tr()),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.keyboard_alt_outlined, size: 16),
          shortcut: const SingleActivator(LogicalKeyboardKey.slash, control: true),
          onPressed: _openShortcuts,
          child: Text('menubar.keyboard_shortcuts'.tr()),
        ),
        SubmenuButton(
          leadingIcon: const Icon(Icons.refresh_rounded, size: 16),
          menuChildren: [
            MenuItemButton(
              onPressed: () => OnboardingService().resetAccount(),
              child: Text('menubar.replay_account'.tr()),
            ),
            MenuItemButton(
              onPressed: () => OnboardingService().reset(),
              child: Text('menubar.replay_full'.tr()),
            ),
          ],
          child: Text('menubar.replay_onboarding'.tr()),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.bug_report_outlined, size: 16),
          onPressed: () =>
              _openUrl('https://github.com/digitorn/client/issues'),
          child: Text('menubar.report_bug'.tr()),
        ),
        const Divider(height: 8),
        MenuItemButton(
          leadingIcon: const Icon(Icons.info_outline_rounded, size: 16),
          onPressed: _showAbout,
          child: Text('menubar.about'.tr()),
        ),
      ],
      child: Text('menubar.help'.tr()),
    );
  }

  // ─── Action helpers ───────────────────────────────────────────────
  // These all route through `rootNavigatorKey` because the menu bar
  // lives in the title bar — ABOVE MaterialApp's Navigator. Using the
  // local BuildContext for `Navigator.of(...)` / `showDialog(...)` /
  // `CommandPalette.show(...)` would target an empty subtree that has
  // no Navigator ancestor, so the actions would fail silently. The
  // global key gets us a context INSIDE the Navigator.

  /// Push a page on the root navigator. Silent no-op if the navigator
  /// is not yet mounted (very early in app lifecycle).
  void _pushPage(Widget page) {
    rootNavigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => page),
    );
  }

  /// Activate an app via `AppState`, then make sure the chat panel is
  /// the visible surface. Same flow as clicking an app card from the
  /// dashboard.
  void _activateApp(AppSummary app) {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) return;
    ctx.read<AppState>().setApp(app);
  }

  void _openCommandPalette() {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) return;
    CommandPalette.show(ctx);
  }

  void _openQuickSwitcher() {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) return;
    GlobalSearch.show(ctx, mode: SearchMode.quickSwitcher);
  }

  void _openGlobalSearch() {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) return;
    GlobalSearch.show(ctx);
  }

  void _openShortcuts() {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) return;
    KeyboardShortcutsSheet.show(ctx);
  }

  /// Native About dialog backed by Flutter's `showAboutDialog`. Routed
  /// through the root navigator's context so the dialog renders on top
  /// of the main Navigator stack rather than over an empty title-bar
  /// subtree.
  void _showAbout() {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) return;
    showAboutDialog(
      context: ctx,
      applicationName: 'Digitorn',
      applicationVersion: '1.0.0',
      applicationIcon: const Icon(Icons.bolt_rounded, size: 28),
      applicationLegalese: '© 2026 Digitorn',
    );
  }

  /// Open an external URL with `url_launcher`. Failures swallowed
  /// silently — there's nothing useful we can show in a menu callback.
  Future<void> _openUrl(String url) async {
    try {
      await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
  }

  /// Best-effort window close. Same shape as `_WindowButtons` close.
  Future<void> _quit() async {
    try {
      await windowManager.close();
    } catch (_) {}
  }

  /// Active app first (if any), then the rest, capped at 5 entries.
  /// Mirrors what most desktop apps show in a Recent menu — the one
  /// you have open + a handful of recent siblings.
  List<AppSummary> _orderedRecentApps(
    List<AppSummary> apps,
    String? activeAppId,
  ) {
    if (apps.isEmpty) return const [];
    final ordered = <AppSummary>[];
    if (activeAppId != null) {
      final active = apps.where((a) => a.appId == activeAppId).firstOrNull;
      if (active != null) ordered.add(active);
    }
    for (final a in apps) {
      if (a.appId == activeAppId) continue;
      ordered.add(a);
      if (ordered.length >= 5) break;
    }
    return ordered;
  }
}
