import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:split_view/split_view.dart';
import 'package:provider/provider.dart';
import 'ui/chat/chat_panel.dart';
import 'ui/workspace/workspace_panel.dart';
import 'ui/dashboard/app_selector.dart';
import 'ui/auth/login_page.dart';
import 'ui/sessions/session_drawer.dart';
import 'models/app_summary.dart';
import 'services/api_client.dart';
import 'services/socket_service.dart';
import 'services/auth_service.dart';
import 'services/session_service.dart';
import 'services/workspace_service.dart';
import 'services/tool_service.dart';
import 'services/background_service.dart';
import 'services/theme_service.dart';
import 'services/notification_service.dart';
import 'models/workspace_state.dart';
import 'models/session_metrics.dart';
import 'ui/sidebar/workspace_sidebar.dart';
import 'ui/settings/settings_page.dart';
import 'theme/app_theme.dart';

// ─── Color tokens ─────────────────────────────────────────────────────────────
const _kBg     = Color(0xFF0D0D0D);
const _kSurf   = Color(0xFF111111);
const _kBorder = Color(0xFF1E1E1E);
const _kMuted  = Color(0xFF555555);
const _kText   = Color(0xFFD4D4D4);
const _kGreen  = Color(0xFF3FB950);
const _kRed    = Color(0xFFF85149);
const _kBlue   = Color(0xFF388BFD);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AuthService().loadFromStorage();
  await ThemeService().load();
  NotificationService().init();

  runApp(const DigitornClientApp());
}

// ─── App State ────────────────────────────────────────────────────────────────

enum ActivePanel { dashboard, chat, sessions, workspace, tools, tasks, settings }

class AppState extends ChangeNotifier {
  AppSummary? activeApp;
  String activeMode = 'empty';
  bool isWorkspaceVisible = false;
  String workspace = '';

  // Which side panel is active
  ActivePanel panel = ActivePanel.dashboard;

  StreamSubscription? _workbenchSub;

  AppState() {
    _workbenchSub = DigitornSocketService().workbenchEvents.listen((event) {
      if (!isWorkspaceVisible) showWorkspace();
      final payload = event['payload'];
      if (payload != null) {
        if (payload['type'] == 'code') setMode('editor');
        if (payload['type'] == 'excel') setMode('excel');
      }
    });
  }

  @override
  void dispose() {
    _workbenchSub?.cancel();
    super.dispose();
  }

  void setMode(String mode) {
    activeMode = mode;
    notifyListeners();
  }

  void setApp(AppSummary app) {
    activeApp = app;
    panel = ActivePanel.chat;
    DigitornApiClient()
      ..updateBaseUrl(AuthService().baseUrl, token: AuthService().accessToken)
      ..appId = app.appId;
    DigitornSocketService().joinApp(app.appId);
    isWorkspaceVisible = app.workspaceMode == 'visible';
    SessionService().createAndSetSession(app.appId);
    WorkspaceService().clearAll();
    ToolService().clearCache();
    notifyListeners();
  }

  void clearApp() {
    activeApp = null;
    panel = ActivePanel.dashboard;
    isWorkspaceVisible = false;
    WorkspaceService().clearAll();
    WorkspaceState().clear();
    ToolService().clearCache();
    BackgroundService().stopPolling();
    notifyListeners();
  }

  void showWorkspace() {
    isWorkspaceVisible = true;
    notifyListeners();
  }

  void closeWorkspace() {
    isWorkspaceVisible = false;
    notifyListeners();
  }

  void setWorkspace(String path) {
    workspace = path;
    notifyListeners();
  }

  void setPanel(ActivePanel p) {
    panel = p;
    notifyListeners();
  }
}

// ─── Root App ─────────────────────────────────────────────────────────────────

class DigitornClientApp extends StatelessWidget {
  const DigitornClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()),
        ChangeNotifierProvider(create: (_) => DigitornSocketService()),
        ChangeNotifierProvider(create: (_) => AuthService()),
        ChangeNotifierProvider(create: (_) => SessionService()),
        ChangeNotifierProvider(create: (_) => WorkspaceService()),
        ChangeNotifierProvider(create: (_) => ToolService()),
        ChangeNotifierProvider(create: (_) => BackgroundService()),
        ChangeNotifierProvider(create: (_) => WorkspaceState()),
        ChangeNotifierProvider(create: (_) => SessionMetrics()),
        ChangeNotifierProvider(create: (_) => ThemeService()),
      ],
      child: Builder(
        builder: (ctx) {
        final themeMode = ctx.watch<ThemeService>().mode;
        return MaterialApp(
        title: 'Digitorn Client',
        debugShowCheckedModeBanner: false,
        locale: const Locale('en'),
        themeMode: themeMode,
        theme: ThemeService.lightTheme.copyWith(
          textTheme: GoogleFonts.interTextTheme(ThemeData.light().textTheme),
        ),
        darkTheme: ThemeService.darkTheme.copyWith(
          textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
        ),
        home: const MainWindow(),
      );
        },
      ),
    );
  }
}

// ─── Main Shell ───────────────────────────────────────────────────────────────

class MainWindow extends StatefulWidget {
  const MainWindow({super.key});
  @override
  State<MainWindow> createState() => _MainWindowState();
}

class _MainWindowState extends State<MainWindow> {
  @override
  void initState() {
    super.initState();
    DigitornSocketService().connect(AuthService().baseUrl);
    AuthService().addListener(_onAuthChange);
  }

  void _onAuthChange() => setState(() {});

  @override
  void dispose() {
    AuthService().removeListener(_onAuthChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    if (!auth.isAuthenticated) {
      return LoginPage(onAuthenticated: () {
        DigitornSocketService().connect(AuthService().baseUrl);
        DigitornApiClient().updateBaseUrl(AuthService().baseUrl,
            token: AuthService().accessToken);
        setState(() {});
      });
    }

    final state = context.watch<AppState>();
    final bg = context.watch<BackgroundService>();

    final isMobile = MediaQuery.of(context).size.width < 600;

    if (isMobile) {
      return Scaffold(
        backgroundColor: _kBg,
        body: _ContentArea(state: state),
        bottomNavigationBar: state.activeApp != null
            ? _MobileBottomBar(state: state, bg: bg)
            : null,
      );
    }

    return Scaffold(
      backgroundColor: context.colors.bg,
      body: Row(
        children: [
          // ── Activity Bar (desktop only) ────────────────────────────────────
          _ActivityBar(state: state, bg: bg),
          Container(width: 1, color: context.colors.border),
          // ── Content area ──────────────────────────────────────────────────
          Expanded(child: _ContentArea(state: state)),
        ],
      ),
    );
  }
}

// ─── Activity Bar ─────────────────────────────────────────────────────────────

// ─── Mobile Bottom Navigation ────────────────────────────────────────────────

class _MobileBottomBar extends StatelessWidget {
  final AppState state;
  final BackgroundService bg;
  const _MobileBottomBar({required this.state, required this.bg});

  @override
  Widget build(BuildContext context) {
    final currentIndex = switch (state.panel) {
      ActivePanel.chat     => 0,
      ActivePanel.sessions => 1,
      ActivePanel.workspace => 2,
      ActivePanel.tools    => 3,
      _                    => 0,
    };

    return Container(
      decoration: BoxDecoration(
        color: context.colors.surface,
        border: Border(top: BorderSide(color: context.colors.border)),
      ),
      child: SafeArea(
        child: SizedBox(
          height: 56,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MobileTab(
                icon: Icons.chat_bubble_outline_rounded,
                label: 'Chat',
                isActive: currentIndex == 0,
                onTap: () => state.setPanel(ActivePanel.chat),
              ),
              _MobileTab(
                icon: Icons.history_rounded,
                label: 'Sessions',
                isActive: currentIndex == 1,
                onTap: () => state.setPanel(
                  state.panel == ActivePanel.sessions
                      ? ActivePanel.chat
                      : ActivePanel.sessions,
                ),
              ),
              _MobileTab(
                icon: Icons.code_rounded,
                label: 'Workspace',
                isActive: currentIndex == 2,
                onTap: () {
                  if (state.isWorkspaceVisible) {
                    state.closeWorkspace();
                    state.setPanel(ActivePanel.chat);
                  } else {
                    state.showWorkspace();
                  }
                },
              ),
              _MobileTab(
                icon: Icons.build_outlined,
                label: 'Tools',
                isActive: currentIndex == 3,
                onTap: () => state.setPanel(
                  state.panel == ActivePanel.tools
                      ? ActivePanel.chat
                      : ActivePanel.tools,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileTab extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  const _MobileTab({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isActive ? context.colors.textBright : context.colors.textMuted;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 64,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 4),
            Text(label,
              style: GoogleFonts.inter(fontSize: 10, color: color, fontWeight: isActive ? FontWeight.w600 : FontWeight.w400),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Activity Bar (Desktop) ──────────────────────────────────────────────────

class _ActivityBar extends StatelessWidget {
  final AppState state;
  final BackgroundService bg;
  const _ActivityBar({required this.state, required this.bg});

  @override
  Widget build(BuildContext context) {
    final hasApp = state.activeApp != null;
    final socket = context.watch<DigitornSocketService>();

    final c = context.colors;
    return Container(
      width: 56,
      color: c.surface,
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          // ── Logo ────────────────────────────────────────────────────────
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: c.surfaceAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.border),
            ),
            child: Icon(Icons.hub_outlined,
                color: c.textMuted, size: 17),
          ),
          const SizedBox(height: 20),

          // ── Dashboard ────────────────────────────────────────────────────
          _BarItem(
            icon: Icons.dashboard_outlined,
            tooltip: 'Apps',
            isActive: state.panel == ActivePanel.dashboard,
            onTap: () => state.clearApp(),
          ),

          if (hasApp) ...[
            const SizedBox(height: 4),
            // ── Chat ───────────────────────────────────────────────────────
            _BarItem(
              icon: Icons.chat_bubble_outline_rounded,
              tooltip: 'Chat',
              isActive: state.panel == ActivePanel.chat,
              onTap: () {
                state.setPanel(ActivePanel.chat);
                state.closeWorkspace();
              },
            ),
            const SizedBox(height: 4),
            // ── Sessions ───────────────────────────────────────────────────
            _BarItem(
              icon: Icons.history_rounded,
              tooltip: 'Sessions',
              isActive: state.panel == ActivePanel.sessions,
              onTap: () => state.setPanel(
                state.panel == ActivePanel.sessions
                    ? ActivePanel.chat
                    : ActivePanel.sessions,
              ),
            ),
            const SizedBox(height: 4),
            // ── Workspace ──────────────────────────────────────────────────
            _BarItem(
              icon: Icons.code_rounded,
              tooltip: 'Workspace',
              isActive: state.isWorkspaceVisible,
              onTap: () {
                if (state.isWorkspaceVisible) {
                  state.closeWorkspace();
                } else {
                  state.showWorkspace();
                }
              },
              badge: context.watch<WorkspaceService>().buffers.length > 0
                  ? '${context.watch<WorkspaceService>().buffers.length}'
                  : null,
            ),
          ],

          const Spacer(),

          // ── Theme toggle ───────────────────────────────────────────────
          Consumer<ThemeService>(
            builder: (_, theme, __) => _BarItem(
              icon: theme.isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              tooltip: theme.isDark ? 'Light mode' : 'Dark mode',
              isActive: false,
              onTap: () => theme.toggle(),
            ),
          ),
          const SizedBox(height: 8),

          // ── Diagnostics badge ────────────────────────────────────────────
          if (hasApp)
            Consumer<WorkspaceService>(
              builder: (_, ws, __) => ws.errorCount > 0
                  ? Tooltip(
                      message: '${ws.errorCount} errors',
                      child: Container(
                        width: 20,
                        height: 20,
                        margin: const EdgeInsets.only(bottom: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF3A1010),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Center(
                          child: Text('${ws.errorCount}',
                              style: const TextStyle(
                                  fontSize: 10, color: _kRed)),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),

          // ── Settings ─────────────────────────────────────────────────────
          _BarItem(
            icon: Icons.settings_outlined,
            tooltip: 'Settings',
            isActive: state.panel == ActivePanel.settings,
            onTap: () => state.setPanel(
              state.panel == ActivePanel.settings
                  ? ActivePanel.chat
                  : ActivePanel.settings,
            ),
          ),
          const SizedBox(height: 10),

          // ── Connection dot ────────────────────────────────────────────────
          Tooltip(
            message: socket.isConnected ? 'Connected' : 'Disconnected',
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: socket.isConnected ? _kGreen : _kRed,
                boxShadow: [
                  BoxShadow(
                    color: (socket.isConnected ? _kGreen : _kRed)
                        .withValues(alpha: 0.45),
                    blurRadius: 6,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Content Area ─────────────────────────────────────────────────────────────

class _ContentArea extends StatefulWidget {
  final AppState state;
  const _ContentArea({required this.state});

  @override
  State<_ContentArea> createState() => _ContentAreaState();
}

class _ContentAreaState extends State<_ContentArea> {
  final GlobalKey _chatKey = GlobalKey();
  final SplitViewController _splitCtrl = SplitViewController(
    weights: [0.5, 0.5],
    limits: [
      WeightLimit(min: 0.2, max: 0.8),
      WeightLimit(min: 0.2, max: 0.8),
    ],
  );

  AppState get state => widget.state;

  @override
  Widget build(BuildContext context) {
    // ── Dashboard (no app selected) ─────────────────────────────────────
    if (state.activeApp == null) {
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: AppSelector(
          key: const ValueKey('dashboard'),
          onAppSelected: (app) {
            state.setApp(app);
            SessionService().loadSessions(app.appId);
            BackgroundService().startPolling(
              app.appId,
              SessionService().activeSession?.sessionId ?? 'default',
            );
          },
        ),
      );
    }

    // ── App view: chat + optional panels ─────────────────────────────────
    final showSessions = state.panel == ActivePanel.sessions;
    final showSettings = state.panel == ActivePanel.settings;

    final screenWidth = MediaQuery.of(context).size.width;
    // Auto-hide sessions on narrow screens
    final effectiveShowSessions = showSessions && screenWidth > 700;
    final sessionWidth = screenWidth < 900 ? 240.0 : 300.0;

    return Row(
      children: [
        // Session drawer (animated slide-in)
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          width: effectiveShowSessions ? sessionWidth : 0,
          clipBehavior: Clip.hardEdge,
          decoration: const BoxDecoration(),
          child: effectiveShowSessions
              ? SessionDrawer(
                  appId: state.activeApp!.appId,
                  onClose: () => state.setPanel(ActivePanel.chat),
                )
              : const SizedBox.shrink(),
        ),
        if (effectiveShowSessions) Container(width: 1, color: context.colors.border),

        // Main content area
        Expanded(
          child: showSettings
              ? const SettingsPage()
              : _chatOrSplit(context, state),
        ),
      ],
    );
  }

  Widget _chatOrSplit(BuildContext context, AppState state) {
    final chat = ChatPanel(key: _chatKey);
    final screenWidth = MediaQuery.of(context).size.width;

    // Auto-hide workspace and sessions on narrow screens
    if (screenWidth < 600) {
      // Mobile: no split, only chat or workspace (toggle via bottom bar)
      if (state.isWorkspaceVisible && state.panel == ActivePanel.workspace) {
        return const WorkspacePanel();
      }
      return chat;
    }

    if (state.isWorkspaceVisible) {
      return SplitView(
        key: const ValueKey('split'),
        viewMode: SplitViewMode.Horizontal,
        indicator: const SplitIndicator(
          viewMode: SplitViewMode.Horizontal,
          color: Colors.transparent,
        ),
        gripSize: 1,
        gripColor: context.colors.border,
        controller: _splitCtrl,
        children: [
          chat,
          const WorkspacePanel(),
        ],
      );
    }

    return chat;
  }
}


class _TaskTile extends StatelessWidget {
  final BackgroundTask task;
  const _TaskTile({required this.task});

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (task.status) {
      'running' => _kBlue,
      'completed' => _kGreen,
      'failed' => _kRed,
      _ => _kMuted,
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _kSurf,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _kBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status indicator
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: statusColor,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(task.description,
                    style: GoogleFonts.inter(
                        fontSize: 12, color: _kText)),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Text(task.status,
                        style: GoogleFonts.inter(
                            fontSize: 10.5, color: statusColor)),
                    if (task.progress != null) ...[
                      const SizedBox(width: 8),
                      Text('${(task.progress! * 100).toStringAsFixed(0)}%',
                          style: GoogleFonts.firaCode(
                              fontSize: 10, color: _kMuted)),
                    ],
                  ],
                ),
              ],
            ),
          ),
          // Cancel button if running
          if (task.isRunning)
            _CancelBtn(task: task),
        ],
      ),
    );
  }
}

class _CancelBtn extends StatefulWidget {
  final BackgroundTask task;
  const _CancelBtn({required this.task});
  @override
  State<_CancelBtn> createState() => _CancelBtnState();
}

class _CancelBtnState extends State<_CancelBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: () async {
            final appId = context.read<AppState>().activeApp?.appId ?? '';
            await BackgroundService().cancelTask(appId, widget.task.id);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: _h ? const Color(0xFF3A1010) : const Color(0xFF1A0A0A),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: const Color(0xFF2A1515)),
            ),
            child: Text('Cancel',
                style: GoogleFonts.inter(
                    fontSize: 10, color: _kRed)),
          ),
        ),
      );
}

// ─── Activity Bar Item ────────────────────────────────────────────────────────

class _BarItem extends StatefulWidget {
  final IconData icon;
  final String? tooltip;
  final bool isActive;
  final VoidCallback? onTap;
  final String? badge;
  final Color? badgeColor;

  const _BarItem({
    required this.icon,
    required this.isActive,
    this.tooltip,
    this.onTap,
    this.badge,
    this.badgeColor,
  });

  @override
  State<_BarItem> createState() => _BarItemState();
}

class _BarItemState extends State<_BarItem> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget item = MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: widget.isActive
                    ? c.borderHover
                    : _h
                        ? c.surfaceAlt
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
                border: widget.isActive
                    ? Border.all(color: c.borderHover)
                    : null,
              ),
              child: Stack(
                children: [
                  // Active indicator — left bar
                  if (widget.isActive)
                    Positioned(
                      left: 0,
                      top: 8,
                      bottom: 8,
                      child: Container(
                        width: 2,
                        decoration: BoxDecoration(
                          color: _kText,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  Center(
                    child: Icon(
                      widget.icon,
                      color: widget.isActive
                          ? c.textBright
                          : _h
                              ? c.text
                              : c.textMuted,
                      size: 17,
                    ),
                  ),
                ],
              ),
            ),

            // Badge (top-right)
            if (widget.badge != null)
              Positioned(
                right: -3,
                top: -3,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: widget.badgeColor ?? const Color(0xFF333333),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: _kSurf, width: 1.5),
                  ),
                  child: Text(
                    widget.badge!,
                    style: const TextStyle(fontSize: 8.5, color: Colors.white),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    if (widget.tooltip != null) {
      return Tooltip(message: widget.tooltip!, child: item);
    }
    return item;
  }
}
