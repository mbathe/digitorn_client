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
import 'ui/workspace/canvas/canvas_registry.dart';
import 'ui/workspace/canvas/builder_canvas.dart';
import 'ui/workspace/viewers/viewer_registry.dart';
import 'ui/workspace/viewers/code_file_viewer.dart';
import 'ui/workspace/viewers/markdown_file_viewer.dart';
import 'ui/workspace/viewers/image_file_viewer.dart';
import 'ui/workspace/viewers/pdf_file_viewer.dart';
import 'ui/workspace/viewers/csv_file_viewer.dart';
import 'ui/workspace/viewers/notebook_file_viewer.dart';
import 'ui/workspace/viewers/json_file_viewer.dart';
import 'ui/workspace/viewers/yaml_file_viewer.dart';
import 'ui/workspace/viewers/toml_file_viewer.dart';
import 'ui/workspace/viewers/xml_file_viewer.dart';
import 'ui/workspace/viewers/log_file_viewer.dart';
import 'models/app_summary.dart';
import 'models/app_manifest.dart';
import 'services/api_client.dart';
import 'services/socket_service.dart';
import 'services/activity_inbox_service.dart';
import 'services/auth_service.dart';
import 'services/devices_service.dart';
import 'services/user_events_service.dart';
import 'services/preferences_service.dart';
import 'services/preview_store.dart';
import 'services/preview_availability_service.dart';
import 'services/app_ui_config_service.dart';
import 'services/workspace_module.dart';
import 'services/session_service.dart';
import 'services/snippets_service.dart';
import 'services/workspace_service.dart';
import 'services/database_service.dart';
import 'services/apps_service.dart';
import 'services/tool_service.dart';
import 'services/background_service.dart';
import 'package:flutter/services.dart';

import 'ui/admin/admin_console_page.dart';
import 'ui/credentials_v2/credentials_gate_v2.dart';
import 'widgets_v1/dispatcher.dart' as widgets_disp;
import 'widgets_v1/models.dart' as widgets_models;
import 'widgets_v1/service.dart' as widgets_service;
import 'widgets_v1/zones.dart' as widgets_zones;
import 'ui/background/background_dashboard.dart';
import 'ui/oneshot/oneshot_panel.dart';
import 'ui/command_palette.dart';
import 'ui/common/remote_icon.dart';
import 'ui/dashboard/deploy_flow.dart';
import 'ui/global_search.dart';
import 'ui/hub/hub_page.dart';
import 'ui/keyboard_shortcuts_sheet.dart';
import 'services/theme_service.dart';
import 'services/onboarding_service.dart';
import 'services/notification_service.dart';
import 'services/tool_display_defaults_service.dart';
import 'services/session_prefs_service.dart';
import 'services/user_prefs_sync.dart';
import 'services/recent_attachments_service.dart';
import 'ui/onboarding/account_wizard_page.dart';
import 'ui/builder/builder_drafts_page.dart';
import 'models/workspace_state.dart';
import 'models/session_metrics.dart';
import 'ui/inbox/inbox_bell.dart';
import 'ui/settings/settings_page.dart';
import 'ui/shell/user_menu_button.dart';
import 'theme/app_theme.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:window_manager/window_manager.dart';
import 'ui/chrome/title_bar.dart';


/// True when we run as a desktop Flutter app with a proper window
/// (Windows / Linux / macOS) — only case where a custom title bar
/// makes sense. Mobile and web never have window chrome to override.
bool get _isDesktop {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS;
}

/// Initialise window_manager and hide the platform title bar so our
/// custom [DigitornTitleBar] can render on top. On macOS we keep the
/// native traffic-light buttons (best-in-class affordance) by using
/// `TitleBarStyle.hidden` which drops only the title text — Windows
/// + Linux get a fully frameless window we control end-to-end.
Future<void> _initWindowChrome() async {
  if (!_isDesktop) return;
  try {
    await windowManager.ensureInitialized();
    final options = WindowOptions(
      size: const Size(1280, 820),
      minimumSize: const Size(720, 520),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: defaultTargetPlatform == TargetPlatform.macOS
          ? TitleBarStyle.hidden
          : TitleBarStyle.hidden,
      title: 'Digitorn',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  } catch (e) {
    // Fallback to native chrome — don't block app boot on a
    // window-manager hiccup (sandboxed envs, linux+wayland quirks).
    debugPrint('windowManager init failed, falling back to native: $e');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initWindowChrome();
  await EasyLocalization.ensureInitialized();
  await AuthService().loadFromStorage();
  await ThemeService().load();
  await PreferencesService().load();
  await OnboardingService().load();
  await SnippetsService().load();
  await SessionPrefsService().load();
  await RecentAttachmentsService().load();
  // Touch singletons so they subscribe to the global event stream
  // before any provider tries to listen.
  ActivityInboxService();
  PreviewStore();
  WorkspaceModule();

  // Open the single Socket.IO connection — this is the only transport
  // for every server → client event. DigitornSocketService routes
  // incoming events to UserEventsService / SessionService which the
  // rest of the app subscribes to.
  if (AuthService().accessToken != null) {
    unawaited(DigitornSocketService().connect(AuthService().baseUrl));
    unawaited(DevicesService().registerCurrentDevice());
    unawaited(ActivityInboxService().fetchUnreadCountFromServer());
    // Fire-and-forget discovery of the daemon's tool display
    // catalog — falls back to built-in defaults if unavailable.
    unawaited(ToolDisplayDefaultsService().load());
    // Pull the user's server-persisted UI prefs (theme, palette,
    // language, density) and onboarding attributes (role, avatar,
    // preferred providers, starter apps) from the daemon and apply
    // them locally. First-run / fresh device ends up with the same
    // UI the user configured on another device.
    unawaited(hydrateUserPrefsFromDaemon());
  }
  AuthService().addListener(() {
    // Defer to next frame — AuthService.notifyListeners() may fire
    // during a widget build (e.g. after a 401 → logout cascade).
    // Touching other ChangeNotifiers synchronously here corrupts
    // the element tree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (AuthService().accessToken != null) {
        unawaited(DigitornSocketService().connect(AuthService().baseUrl));
        unawaited(DevicesService().registerCurrentDevice());
        unawaited(ActivityInboxService().fetchUnreadCountFromServer());
        unawaited(ToolDisplayDefaultsService().reload());
        // Re-hydrate on auth change too — covers the "user logs in
        // on a fresh install" path where the local SharedPreferences
        // are still at factory defaults.
        unawaited(hydrateUserPrefsFromDaemon());
      } else {
        DigitornSocketService().disconnect();
        NotificationService().disposeSub();
        unawaited(UserEventsService().reset());
      }
    });
  });
  NotificationService().init();
  _registerWorkspaceViewers();
  _registerWorkspaceCanvases();

  final prefs = PreferencesService();
  final startLocale = _localeFromLang(prefs.language);
  runApp(
    EasyLocalization(
      supportedLocales: const [
        Locale('en'),
        Locale('fr'),
        Locale('es'),
        Locale('de'),
        Locale('pt'),
        Locale('it'),
        Locale('zh', 'CN'),
        Locale('ja'),
        Locale('ko'),
        Locale('ru'),
        Locale('ar'),
      ],
      path: 'assets/translations',
      fallbackLocale: const Locale('en'),
      startLocale: startLocale,
      child: const DigitornClientApp(),
    ),
  );
}

Locale _localeFromLang(String? lang) {
  switch (lang) {
    case 'fr':
      return const Locale('fr');
    case 'es':
      return const Locale('es');
    case 'de':
      return const Locale('de');
    case 'pt':
      return const Locale('pt');
    case 'it':
      return const Locale('it');
    case 'zh':
    case 'zh-CN':
    case 'zh_CN':
      return const Locale('zh', 'CN');
    case 'ja':
      return const Locale('ja');
    case 'ko':
      return const Locale('ko');
    case 'ru':
      return const Locale('ru');
    case 'ar':
      return const Locale('ar');
    case 'en':
    default:
      return const Locale('en');
  }
}

/// Register every viewer the workspace knows about. This is the **only**
/// place new file formats need to be wired up — see
/// `lib/ui/workspace/viewers/` for the available viewers.
void _registerWorkspaceViewers() {
  // Specialised viewers (higher priority — claim their extensions first).
  ViewerRegistry.register(const PdfFileViewer());
  ViewerRegistry.register(const NotebookFileViewer());
  ViewerRegistry.register(const JsonFileViewer());
  ViewerRegistry.register(const YamlFileViewer());
  ViewerRegistry.register(const TomlFileViewer());
  ViewerRegistry.register(const XmlFileViewer());
  ViewerRegistry.register(const LogFileViewer());
  ViewerRegistry.register(const CsvFileViewer());
  ViewerRegistry.register(const MarkdownFileViewer());
  ViewerRegistry.register(const ImageFileViewer());

  // Generic code/text viewer also handles a long list of extensions
  // explicitly, AND serves as the registry's fallback for anything
  // unknown.
  const code = CodeFileViewer();
  ViewerRegistry.register(code);
  ViewerRegistry.setFallback(code);
}

/// Register canvas renderers — apps that declare `workspace.render_mode`
/// with a non-built-in value get dispatched here by `WsPreviewRouter`.
/// Built-in modes (react / html / markdown / slides / code) are handled
/// directly in the router; everything else lands in this registry.
void _registerWorkspaceCanvases() {
  // Derived-graph canvas for the digitorn-builder app — parses
  // `app.yaml` client-side into triggers / agents / modules columns
  // with phase / compile / deploy / tests overlays. Any app that sets
  // `render_mode: builder` in its workspace config lights this up.
  CanvasRegistry.register(
    'builder',
    (_) => const BuilderCanvas(),
  );
}

// ─── App State ────────────────────────────────────────────────────────────────

/// Root navigator key — exposed so services (e.g. the credentials
/// gate called from [AppState.setApp]) can push dialogs without a
/// BuildContext from the caller.
final GlobalKey<NavigatorState> rootNavigatorKey =
    GlobalKey<NavigatorState>();

enum ActivePanel { dashboard, chat, sessions, workspace, tools, tasks, settings, hub }

class AppState extends ChangeNotifier {
  AppSummary? activeApp;
  String activeMode = 'empty';
  bool isWorkspaceVisible = false;

  /// Widget spec (YAML compiled by the daemon) for the currently
  /// active app. Fetched in [setApp] and cleared on [clearApp].
  /// Used by the main layout to mount Z2 (chat_side) and by the
  /// workspace panel to mount Z3 (workspace tabs).
  widgets_models.WidgetsAppSpec activeAppWidgets =
      widgets_models.WidgetsAppSpec.empty;

  /// Parsed app manifest — drives every adaptive piece of the UI
  /// (workspace visibility, quick prompts, greeting, feature flags,
  /// accent colour, …). Replaced on every [setApp]; safe defaults
  /// means the UI still renders when the daemon hasn't shipped a
  /// manifest yet.
  AppManifest _manifest = AppManifest.defaults('');
  AppManifest get manifest => _manifest;

  String workspace = '';
  bool sidebarCollapsed = false;
  bool showAppsPanel = false;
  String? pendingMessage;

  /// Broadcast stream used by the widgets runtime to push a message
  /// into the currently-mounted chat (action: chat). ChatPanel
  /// subscribes in initState and injects + sends when an event
  /// arrives.
  final StreamController<String> _widgetChatController =
      StreamController<String>.broadcast();
  Stream<String> get widgetChatStream => _widgetChatController.stream;

  void injectChatMessage(String msg) {
    if (msg.trim().isEmpty) return;
    pendingMessage = msg;
    _widgetChatController.add(msg);
    notifyListeners();
  }

  /// Public wrapper around [notifyListeners] so code outside this
  /// class (e.g. the widgets_v1 action dispatcher) can trigger a
  /// rebuild after mutating public fields.
  void publicNotify() => notifyListeners();

  // ── Apps popover hover handling ───────────────────────────────────────
  //
  // The apps sidebar button opens the popover on hover, not only on
  // click. But hover UX is fragile: when the cursor moves from the
  // button to the popover, there's a brief instant where it's over
  // neither — without a grace period the popover would flash shut.
  //
  // Pattern: hover enter on either the button or the popover cancels
  // any pending close; hover exit starts a 220ms timer that closes the
  // popover unless a re-enter cancels it.
  Timer? _appsHoverCloseTimer;

  /// Sticky "do not close the popover" flag. Set to true while a long
  /// async operation (file picker → deploy) is in progress — otherwise
  /// the mouse leaving the popover to interact with the OS file dialog
  /// would trigger a hover close, unmount the widget mid-deploy and
  /// swallow every snackbar / refresh call that came after.
  bool _appsPanelBlockClose = false;

  // ── Apps list cache ───────────────────────────────────────────────────────
  // The apps popover is destroyed and recreated on every open (conditional
  // render). Without a cache, every open fires GET /api/apps. We keep the
  // last fetched list here with a 60-second TTL: the popover shows the
  // cached list instantly on open, then refreshes in background if stale.
  List<AppSummary> _appsListCache = [];
  DateTime? _appsListCachedAt;
  static const _appsListCacheTtl = Duration(seconds: 60);

  List<AppSummary> get appsListCache => _appsListCache;

  bool get appsListCacheValid =>
      _appsListCachedAt != null &&
      DateTime.now().difference(_appsListCachedAt!) < _appsListCacheTtl;

  void updateAppsCache(List<AppSummary> apps) {
    _appsListCache = apps;
    _appsListCachedAt = DateTime.now();
    // No notifyListeners() — the popover owns its own setState.
  }

  void toggleAppsPanel() {
    _appsHoverCloseTimer?.cancel();
    showAppsPanel = !showAppsPanel;
    notifyListeners();
  }

  void openAppsPanelHover() {
    _appsHoverCloseTimer?.cancel();
    if (!showAppsPanel) {
      showAppsPanel = true;
      notifyListeners();
    }
  }

  void scheduleAppsPanelClose() {
    if (_appsPanelBlockClose) return; // sticky — deploy in progress
    _appsHoverCloseTimer?.cancel();
    // Generous grace period — tooltip overlays and grid navigation can
    // produce brief hover exits we don't want to interpret as "close".
    _appsHoverCloseTimer = Timer(const Duration(milliseconds: 450), () {
      if (showAppsPanel) {
        showAppsPanel = false;
        notifyListeners();
      }
    });
  }

  void cancelAppsPanelClose() {
    _appsHoverCloseTimer?.cancel();
  }

  /// Prevent or allow the apps popover from auto-closing. Wrap any
  /// long-lived interaction (deploy, dialog) in `setAppsPanelBlockClose
  /// (true)` / `false` so mouse exits from the popover don't unmount
  /// the widget mid-operation.
  void setAppsPanelBlockClose(bool v) {
    _appsPanelBlockClose = v;
    if (v) _appsHoverCloseTimer?.cancel();
  }

  // Which side panel is active
  ActivePanel panel = ActivePanel.dashboard;

  AppState() {
    // Watch session switches so we can restore each session's own
    // workspace visibility (per-session preference map below).
    _sessionChangeSub =
        SessionService().onSessionChange.listen(_onSessionChange);
  }

  /// Per-session record of whether the user had the workspace open
  /// the last time they interacted with this session.
  ///   * null / missing → never explicitly shown → start HIDDEN
  ///   * true  → user had it open → start VISIBLE
  ///   * false → user had it closed → start HIDDEN
  ///
  /// Lives in-memory (not persisted) — sufficient for the current
  /// user ask: "if the user opened it earlier in THIS session, keep
  /// it open when they come back; otherwise hide". Survives session
  /// switches within the life of the app process.
  final Map<String, bool> _sessionWorkspaceShown = {};
  StreamSubscription<String?>? _sessionChangeSub;

  void _onSessionChange(String? sessionId) {
    if (sessionId == null || sessionId.isEmpty) return;
    // Workspace starts CLOSED on every session entry. We deliberately
    // do NOT restore the per-session "last shown" preference here —
    // product rule: "open a chat → workspace is closed by default".
    // If the user wants the workspace they click the rail/chip to
    // pop it open; that action calls ``showWorkspace()`` which still
    // writes to ``_sessionWorkspaceShown`` for within-session memory
    // (re-entering the same session later is a fresh "opening the
    // chat" → closed again).
    //
    // The one exception stays in ``_fetchManifest`` —
    // ``WorkspaceMode.required`` apps (digitorn-builder etc.) can't
    // function without the workspace, so they still force-open.
    if (isWorkspaceVisible) {
      isWorkspaceVisible = false;
      notifyListeners();
    }
    final appId = activeApp?.appId;
    if (appId != null && appId.isNotEmpty) {
      _primeWorkspaceMeta(appId, sessionId);
    }
  }

  /// Fetch `{render_mode, entry_file, title}` via
  /// `GET /sessions/{sid}/workspace` and inject it into
  /// `PreviewStore.state['workspace']` so `WorkspaceModule._rebuild()`
  /// picks up the canvas renderer to mount. Scout-confirmed: the
  /// daemon never emits this via `preview:state_changed`, so the
  /// client must pull it on every session activation.
  Future<void> _primeWorkspaceMeta(String appId, String sessionId) async {
    try {
      final meta = await DigitornApiClient()
          .fetchWorkspaceMeta(appId, sessionId);
      if (meta == null) return;
      final cur = SessionService().activeSession;
      if (cur == null ||
          cur.sessionId != sessionId ||
          cur.appId != appId) {
        return;
      }
      PreviewStore().primeWorkspaceMeta(meta);
    } catch (e, st) {
      debugPrint('_primeWorkspaceMeta failed for $appId/$sessionId: $e\n$st');
    }
  }

  @override
  void dispose() {
    _sessionChangeSub?.cancel();
    _appsHoverCloseTimer?.cancel();
    _widgetChatController.close();
    super.dispose();
  }

  void setMode(String mode) {
    activeMode = mode;
    notifyListeners();
  }

  Future<void> setApp(AppSummary app,
      {bool createNewSession = false, bool clearSession = true}) async {
    // Leave previous app room before joining the new one.
    final prevApp = activeApp;
    final appSwitched = prevApp != null && prevApp.appId != app.appId;
    if (appSwitched) {
      DigitornSocketService().leaveApp(prevApp.appId);
    }
    activeApp = app;
    panel = ActivePanel.chat;
    activeAppWidgets = widgets_models.WidgetsAppSpec.empty;
    // Seed with sensible defaults so the UI never flashes a broken
    // state while the richer manifest is being fetched.
    _manifest = AppManifest.defaults(app.appId);
    DigitornApiClient()
      ..updateBaseUrl(AuthService().baseUrl, token: AuthService().accessToken)
      ..appId = app.appId;
    DigitornSocketService().joinApp(app.appId);
    // Workspace starts HIDDEN on every app open. Per-session
    // preference kicks in once the new session is created and the
    // `_onSessionChange` listener restores the user's last choice
    // for that session (if they had opened it before).
    isWorkspaceVisible = false;
    // Synchronous store wipe so the workspace panel never renders
    // the previous app's files during the HTTP round-trip below.
    PreviewStore().reset();
    WorkspaceModule().reset();
    WorkspaceService().clearAll();
    // Clicking an app opens a fresh empty chat by default, even if
    // the user is clicking the same app twice — product intent is
    // "click on the app icon = new chat". Callers that immediately
    // want to open a SPECIFIC session (history drawer, inbox jump)
    // pass ``clearSession: false`` and call ``setActiveSession``
    // themselves right after. Cross-app jumps always clear — keeping
    // the previous app's session visible inside the new app for even
    // one frame mixes state between apps.
    if (clearSession || appSwitched) {
      SessionService().activeSession = null;
    }
    // Transition the UI immediately — the chat panel renders now so
    // the user gets instant feedback. The credentials gate (below)
    // runs as a dialog OVER the chat panel instead of blocking the
    // transition. This eliminates the "click → nothing happens for
    // N seconds" delay on first open.
    notifyListeners();

    // Fire all background fetches immediately — in parallel with the
    // credentials gate — so manifest/widgets/preview are loading while
    // the credentials HTTP call is in flight. Without this, a cold
    // credentials cache (first open) would block the manifest fetch
    // and leave the chat panel showing default values for 100–500ms.
    PreviewAvailabilityService().probe(app.appId);
    AppUiConfigService().ensure(app.appId);
    _primeCodeSnapshot(app.appId);
    _fetchWidgetsSpec(app.appId);
    _fetchManifest(app);

    // Pre-session credentials gate. Runs after the UI has transitioned
    // so the spinner and panel are already visible. If the user cancels
    // a missing-secret dialog, revert cleanly via goHome().
    final navCtx = rootNavigatorKey.currentContext;
    if (navCtx != null) {
      final ok = await CredentialsGateV2.ensureReady(
        navCtx,
        appId: app.appId,
      );
      if (!ok) {
        goHome();
        return;
      }
    }
    if (createNewSession) {
      // New atomic contract: a session can only be created together
      // with its first user message. ``createNewSession`` here is
      // really "show the empty welcome state" — the actual session
      // will be born when the user sends their first message via
      // ``_send`` in ``ChatPanel``.
      SessionService().clearActiveSession();
    }
    ToolService().clearCache();
    notifyListeners();
  }

  Future<void> _fetchManifest(AppSummary app) async {
    try {
      final fetched = await _loadManifest(app);
      if (activeApp?.appId != app.appId) return;
      _manifest = fetched;
      // Workspace visibility on app open: `none` forces hidden,
      // every other mode (`required`, `optional`, `auto`) leaves
      // whatever `setApp` already decided — which is `false` by
      // default. Even apps that REQUIRE a workspace should land
      // with the panel collapsed so the user enters the chat
      // first; they (or a tool result) open the workspace on
      // demand. Avoids the abrupt split-screen on every app open.
      if (_manifest.workspaceMode == WorkspaceMode.none) {
        isWorkspaceVisible = false;
      }
      notifyListeners();
    } catch (e, st) {
      debugPrint('fetchManifest failed: $e\n$st');
    }
  }

  /// Tries the daemon's manifest endpoint, falls back to synthesising
  /// one from the existing [AppSummary] so older daemons still work.
  Future<AppManifest> _loadManifest(AppSummary app) async {
    final api = DigitornApiClient();
    try {
      final res = await api.fetchAppManifest(app.appId);
      if (res != null) return res;
    } catch (e) {
      debugPrint('fetchAppManifest error: $e');
    }
    // Fallback — manifest synthesised from what we already have
    // (name, icon, color, workspace mode, greeting).
    return AppManifest(
      appId: app.appId,
      name: app.name,
      version: app.version,
      description: app.description,
      icon: app.icon,
      color: app.color,
      category: app.category,
      tags: app.tags,
      greeting: app.greeting,
      workspaceMode: _parseWsModeFromSummary(app.workspaceMode),
    );
  }

  WorkspaceMode _parseWsModeFromSummary(String raw) {
    switch (raw.toLowerCase()) {
      case 'none':
      case 'off':
        return WorkspaceMode.none;
      case 'required':
        return WorkspaceMode.required;
      case 'optional':
      case 'visible':
        return WorkspaceMode.optional;
      default:
        return WorkspaceMode.auto;
    }
  }

  Future<void> _fetchWidgetsSpec(String appId) async {
    try {
      final spec = await widgets_service.WidgetsService().fetchSpec(appId);
      if (activeApp?.appId != appId) return;
      activeAppWidgets = spec;
      // If the app declares a chat_side pane, auto-show the
      // workspace's Widgets tab is not needed here — Z2 lives next
      // to the chat, not in the workspace.
      notifyListeners();
    } catch (e, st) {
      debugPrint('_fetchWidgetsSpec failed for $appId: $e\n$st');
    }
  }

  /// Prime the workspace file tree with metadata from
  /// `GET /workspace/code-snapshot`. No content is fetched — just
  /// the per-file counters the explorer needs for badges. Best-
  /// effort: failures are silent (apps without the workspace module
  /// simply have nothing to prime, which is fine).
  Future<void> _primeCodeSnapshot(String appId) async {
    try {
      final session = SessionService().activeSession;
      if (session == null || session.appId != appId) return;
      final snap = await DigitornApiClient()
          .fetchCodeSnapshot(appId, session.sessionId);
      if (snap == null) return;
      // Session may have changed under us during the HTTP round-trip.
      final cur = SessionService().activeSession;
      if (cur == null ||
          cur.sessionId != session.sessionId ||
          cur.appId != appId) {
        return;
      }
      PreviewStore().primeFilesFromCodeSnapshot(snap);
    } catch (e, st) {
      debugPrint('_primeCodeSnapshot failed for $appId: $e\n$st');
    }
  }

  void clearApp() {
    activeApp = null;
    panel = ActivePanel.dashboard;
    isWorkspaceVisible = false;
    _sessionWorkspaceShown.clear();
    activeAppWidgets = widgets_models.WidgetsAppSpec.empty;
    _manifest = AppManifest.defaults('');
    WorkspaceService().clearAll();
    WorkspaceState().clear();
    ToolService().clearCache();
    BackgroundService().stopPolling();
    PreviewStore().reset();
    WorkspaceModule().reset();
    notifyListeners();
  }

  /// Convenience for the logo button: drop the current app AND close
  /// the apps panel, publishing a single notification instead of
  /// touching `notifyListeners` from outside the class.
  void goHome() {
    activeApp = null;
    panel = ActivePanel.dashboard;
    isWorkspaceVisible = false;
    showAppsPanel = false;
    activeAppWidgets = widgets_models.WidgetsAppSpec.empty;
    WorkspaceService().clearAll();
    WorkspaceState().clear();
    ToolService().clearCache();
    BackgroundService().stopPolling();
    PreviewStore().reset();
    WorkspaceModule().reset();
    notifyListeners();
  }

  void showWorkspace() {
    // Apps whose manifest declares `workspace_mode: none` should
    // never display the workspace, even if another widget tries to
    // pop it open. Honour that opt-out at the state layer so every
    // consumer is consistent.
    if (_manifest.workspaceMode == WorkspaceMode.none) return;
    isWorkspaceVisible = true;
    // Record the user's choice for the current session so the
    // workspace opens automatically the next time the user returns
    // to this session (per-session preference, not persisted).
    final sid = SessionService().activeSession?.sessionId;
    if (sid != null && sid.isNotEmpty) {
      _sessionWorkspaceShown[sid] = true;
    }
    notifyListeners();
  }

  void closeWorkspace() {
    isWorkspaceVisible = false;
    final sid = SessionService().activeSession?.sessionId;
    if (sid != null && sid.isNotEmpty) {
      _sessionWorkspaceShown[sid] = false;
    }
    notifyListeners();
  }

  /// Convenience for UI code that needs to know whether the
  /// workspace is reachable at all (shows/hides toggle buttons).
  bool get workspaceAvailable =>
      _manifest.workspaceMode != WorkspaceMode.none;

  void setWorkspace(String path) {
    workspace = path;
    notifyListeners();
  }

  void setPanel(ActivePanel p) {
    panel = p;
    notifyListeners();
  }

  void toggleSidebar() {
    sidebarCollapsed = !sidebarCollapsed;
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
        ChangeNotifierProvider(create: (_) => DatabaseService()),
        ChangeNotifierProvider(create: (_) => AppsService()),
        ChangeNotifierProvider(create: (_) => ToolService()),
        ChangeNotifierProvider(create: (_) => BackgroundService()),
        ChangeNotifierProvider(create: (_) => WorkspaceState()),
        ChangeNotifierProvider(create: (_) => SessionMetrics()),
        ChangeNotifierProvider(create: (_) => ContextState()),
        ChangeNotifierProvider(create: (_) => ThemeService()),
        ChangeNotifierProvider(create: (_) => OnboardingService()),
        ChangeNotifierProvider(create: (_) => UserEventsService()),
        ChangeNotifierProvider(create: (_) => PreviewStore()),
        ChangeNotifierProvider(create: (_) => PreviewAvailabilityService()),
        ChangeNotifierProvider(create: (_) => WorkspaceModule()),
        ChangeNotifierProvider(create: (_) => PreferencesService()),
        ChangeNotifierProvider(create: (_) => ActivityInboxService()),
        ChangeNotifierProvider(create: (_) => SessionPrefsService()),
      ],
      child: Builder(
        builder: (ctx) {
          // Watch the whole service so a palette change rebuilds the
          // MaterialApp and the new AppColors extension propagates.
          // Same goes for `PreferencesService` — flipping density
          // must rebuild the MaterialApp so `visualDensity` lands.
          final theme = ctx.watch<ThemeService>();
          final prefs = ctx.watch<PreferencesService>();
          final density = prefs.density;
          final textScale = ThemeService.textScaleFor(density);
          return MaterialApp(
            title: 'Digitorn Client',
            navigatorKey: rootNavigatorKey,
            debugShowCheckedModeBanner: false,
            localizationsDelegates: ctx.localizationDelegates,
            supportedLocales: ctx.supportedLocales,
            locale: ctx.locale,
            themeMode: theme.mode,
            theme: theme.buildTheme(Brightness.light, density: density).copyWith(
              textTheme:
                  GoogleFonts.interTextTheme(ThemeData.light().textTheme),
            ),
            darkTheme: theme.buildTheme(Brightness.dark, density: density).copyWith(
              textTheme:
                  GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
            ),
            builder: (context, child) {
              // Custom frameless title bar on desktop. No-op on mobile
              // / web so the Column collapses to just the app child.
              // Wrap the whole subtree in a MediaQuery whose textScaler
              // matches the chosen density — that way every Text widget
              // (including ones not styled via Material's TextTheme)
              // scales in unison with the web's rem base trick.
              //
              // The extra `Overlay` is required because the title bar's
              // `MenuBar` lives ABOVE MaterialApp's Navigator (hence
              // outside its built-in Overlay) and Material's MenuBar
              // throws if it can't find an Overlay ancestor for its
              // dropdowns. Wrapping here gives both the title bar and
              // the Navigator (which still has its own Overlay further
              // down) an ancestor — the MenuBar resolves to this one
              // and dropdowns can render below the title bar into the
              // main app area.
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(textScale),
                ),
                child: Overlay(
                  initialEntries: [
                    OverlayEntry(
                      builder: (_) => Column(
                        children: [
                          const DigitornTitleBar(),
                          Expanded(
                            child: child ?? const SizedBox.shrink(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
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
    OnboardingService().addListener(_onOnboardingChange);
  }

  void _onAuthChange() {
    // AuthService notifies on every token refresh and login/logout;
    // the listener can fire during a widget transition when this
    // state is briefly unmounted. Guard setState to avoid the
    // "setState called on unmounted" assertion crash.
    if (mounted) setState(() {});
  }

  void _onOnboardingChange() {
    if (!mounted) return;
    // Rebuild for route decisions (setup/account flags) AND schedule
    // a one-shot consume of `preferredInitialTarget` on the next
    // frame — the workspace must have mounted before we can route
    // into the Hub panel or push the Builder page.
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeConsumeLaunchTarget();
    });
  }

  Future<void> _maybeConsumeLaunchTarget() async {
    if (!mounted) return;
    final ob = OnboardingService();
    final target = ob.preferredInitialTarget;
    if (target == null) return;
    if (!AuthService().isAuthenticated || !ob.accountSetupDone) return;
    ob.preferredInitialTarget = null;
    final state = context.read<AppState>();
    switch (target) {
      case 'hub':
        state.setPanel(ActivePanel.hub);
        break;
      case 'builder':
        await _launchBuilderApp(state);
        break;
      case 'workspace':
      default:
        break;
    }
  }

  /// Launch the always-shipped Digitorn Builder app. Preferred path
  /// is a real daemon-served app (appId `digitorn-builder` or the
  /// first app tagged as Builder) — falls back to the local drafts
  /// page if the daemon hasn't exposed it yet.
  Future<void> _launchBuilderApp(AppState state) async {
    final apps = AppsService();
    if (apps.apps.isEmpty) {
      await apps.refresh();
    }
    AppSummary? builder;
    for (final a in apps.apps) {
      if (a.appId == 'digitorn-builder' ||
          a.appId == 'digitorn.builder' ||
          a.appId == 'builder' ||
          a.category == 'builder') {
        builder = a;
        break;
      }
    }
    if (builder != null) {
      await state.setApp(builder);
      return;
    }
    final navState = rootNavigatorKey.currentState;
    if (navState == null) return;
    navState.push(
      MaterialPageRoute(builder: (_) => const BuilderDraftsPage()),
    );
  }

  @override
  void dispose() {
    AuthService().removeListener(_onAuthChange);
    OnboardingService().removeListener(_onOnboardingChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final onboarding = context.watch<OnboardingService>();

    // First-launch machine setup was removed 2026-04: the daemon URL
    // is build-stamped (``--dart-define=DIGITORN_DAEMON_URL=...``) on
    // the hosted build, and self-hosters can still edit it from
    // Settings → Daemon. Theme / language / accessibility also moved
    // to Settings — forcing those choices before the user has even
    // seen the product was a net loss. ``setupDone`` is left dormant
    // in storage for back-compat, nothing gates on it any more.

    if (!auth.isAuthenticated) {
      return LoginPage(onAuthenticated: () {
        DigitornSocketService().connect(AuthService().baseUrl);
        DigitornApiClient().updateBaseUrl(AuthService().baseUrl,
            token: AuthService().accessToken);
        setState(() {});
      });
    }

    // Authenticated but never ran the account wizard — fresh
    // registration OR first login on this device. Still wrap the
    // wizard in ``_GlobalShortcuts`` so Ctrl+K / Ctrl+P work during
    // onboarding too (user may want to search-jump before finishing).
    if (!onboarding.accountSetupDone) {
      return Scaffold(
        body: _GlobalShortcuts(
          child: AccountWizardPage(onComplete: () => setState(() {})),
        ),
      );
    }

    final state = context.watch<AppState>();
    final bg = context.watch<BackgroundService>();

    final isMobile = MediaQuery.of(context).size.width < 600;

    if (isMobile) {
      // Mobile shell also needs the global shortcut handler — users
      // with a physical keyboard (tablet / foldable / dock) expect
      // Ctrl+K to work, and there's no reason for the handler to be
      // desktop-only. ``_GlobalShortcuts`` is cheap (just a Focus +
      // onKeyEvent) so keeping it on every platform is right.
      return Scaffold(
        backgroundColor: context.colors.bg,
        body: _GlobalShortcuts(
          // Connectivity banner OVERLAYS the body (Positioned at top
          // of the Stack) instead of pushing the chat panel down by
          // ~30 px every time the connection drops. Mirror of the web
          // `position: fixed` overlay rewrite.
          child: Stack(
            children: [
              _ContentArea(state: state),
              const Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  ignoring: false,
                  child: _ConnectivityBanner(),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: _MobileBottomBar(state: state, bg: bg),
      );
    }

    return Scaffold(
      backgroundColor: context.colors.bg,
      body: _GlobalShortcuts(
        child: Stack(children: [
        Row(
            children: [
              _ActivityBar(state: state, bg: bg),
              Container(width: 1, color: context.colors.border),
              Expanded(child: Stack(
        children: [
          // Main layout
          _ContentArea(state: state),
          // Apps popover overlay — hover-driven.
          if (state.showAppsPanel) ...[
            // Invisible barrier: click anywhere outside the popover
            // closes it immediately. Not a fade overlay, so it doesn't
            // steal focus from the underlying UI.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => state.toggleAppsPanel(),
              ),
            ),
            // Popover positioned next to activity bar with animation.
            // Wrapped in a MouseRegion that cancels the close timer on
            // enter and re-schedules it on exit, so cursor movement
            // between the sidebar button and the popover is seamless.
            Positioned(
              left: 70,
              top: 60,
              // Layered transform: slide in from the sidebar, scale
              // up from 0.9, fade opacity in, all with a single
              // easeOutCubic curve for a polished "pop" feel.
              //
              // NOTE: the MouseRegion is placed INSIDE the transforms
              // (as the direct parent of _AppsPopover) so the transform
              // matrix does NOT affect its hit-test bounds — otherwise
              // during the 320ms open animation the shrunken transform
              // could flicker the hover state and close the popover
              // mid-navigation. By wrapping the raw popover widget the
              // MouseRegion always sees the final, full-size rectangle.
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.0, end: 1.0),
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutCubic,
                builder: (_, v, child) {
                  final inv = 1.0 - v;
                  return Opacity(
                    opacity: (v * 1.4).clamp(0.0, 1.0),
                    child: Transform.translate(
                      offset: Offset(-14 * inv, -8 * inv),
                      child: Transform.scale(
                        scale: 0.90 + 0.10 * v,
                        alignment: Alignment.topLeft,
                        child: child,
                      ),
                    ),
                  );
                },
                // Once the popover is open the user is DRIVING —
                // scroll, keyboard nav, search. We must not close
                // on hover-out: the cursor crosses scrollbars,
                // gaps, and reflowed rows mid-gesture and each
                // crossing fires an `onExit` that would debounce
                // the popover shut.
                //
                // `onEnter` still cancels the sidebar-button's
                // open-on-hover timer so moving from the button
                // into the popover stays seamless. Close paths:
                //   1. Click outside (see the barrier above)
                //   2. Press Escape (Shortcuts wrapper below)
                //   3. Sidebar button tap / second click
                child: MouseRegion(
                  onEnter: (_) => state.cancelAppsPanelClose(),
                  child: Shortcuts(
                    shortcuts: const {
                      SingleActivator(LogicalKeyboardKey.escape):
                          _ClosePopoverIntent(),
                    },
                    child: Actions(
                      actions: {
                        _ClosePopoverIntent: CallbackAction<_ClosePopoverIntent>(
                          onInvoke: (_) {
                            state.toggleAppsPanel();
                            return null;
                          },
                        ),
                      },
                      child: Focus(
                        autofocus: true,
                        child: _AppsPopover(
                          state: state,
                          onClose: () => state.toggleAppsPanel(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      )),
            ],
          ),
          // Overlay banner — sits on top of the layout without taking
          // any vertical space. Mirror of the web `position: fixed`
          // overlay rewrite.
          const Positioned(
            top: 8,
            left: 0,
            right: 0,
            child: _ConnectivityBanner(),
          ),
      ]),
      ),
    );
  }
}

// ─── Global keyboard shortcuts ───────────────────────────────────────────────
//
// Lifted out of the chat panel so they fire from anywhere in the
// app (dashboard, hub, settings, admin console, …). Listens at the
// top of the widget tree using a `Focus` node + `KeyEventResult`
// so the shortcuts don't get swallowed by random child focus
// scopes (text fields, dialogs).
//
// Bindings:
//   * Ctrl+K       → Command palette
//   * Ctrl+P       → Global search
//   * Ctrl+T       → Quick switcher (sessions)
//   * Ctrl+/       → Keyboard shortcuts cheat sheet
//   * Ctrl+Shift+A → Admin console (when admin)

class _GlobalShortcuts extends StatefulWidget {
  final Widget child;
  const _GlobalShortcuts({required this.child});

  @override
  State<_GlobalShortcuts> createState() => _GlobalShortcutsState();
}

class _GlobalShortcutsState extends State<_GlobalShortcuts> {
  // Stashed so we can unregister on dispose and never leak the
  // closure into another instance of the shell.
  late final bool Function(KeyEvent) _hwHandler;
  // Kept so we can call the palette from the hardware-keyboard
  // callback, which fires outside a widget build phase.
  late final BuildContext _stableContext;

  @override
  void initState() {
    super.initState();
    _stableContext = context;
    _hwHandler = _onHardwareKey;
    HardwareKeyboard.instance.addHandler(_hwHandler);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_hwHandler);
    super.dispose();
  }

  /// App-level key handler. Runs BEFORE the focus tree, so it keeps
  /// working even when a dialog just closed and no node has focus —
  /// which is the most common reason ``Ctrl+K`` stops responding
  /// mid-session. Returning ``true`` tells Flutter we've consumed
  /// the event (so the focused TextField doesn't ALSO see the K).
  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final kb = HardwareKeyboard.instance;
    final ctrl = kb.isControlPressed || kb.isMetaPressed;
    if (!ctrl) return false;
    final key = event.logicalKey;
    if (!_stableContext.mounted) return false;
    if (key == LogicalKeyboardKey.keyK) {
      CommandPalette.show(_stableContext);
      return true;
    }
    if (key == LogicalKeyboardKey.keyP) {
      GlobalSearch.show(_stableContext);
      return true;
    }
    if (key == LogicalKeyboardKey.keyT) {
      GlobalSearch.show(_stableContext, mode: SearchMode.quickSwitcher);
      return true;
    }
    if (key == LogicalKeyboardKey.slash) {
      KeyboardShortcutsSheet.show(_stableContext);
      return true;
    }
    if (key == LogicalKeyboardKey.keyA && kb.isShiftPressed) {
      if (AuthService().currentUser?.isAdmin == true) {
        Navigator.of(_stableContext).push(
          MaterialPageRoute(
            builder: (_) => const AdminConsolePage(),
          ),
        );
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // Kept as a Focus + onKeyEvent too — belt-and-braces for the
    // rare case where ``HardwareKeyboard.addHandler`` doesn't fire
    // (seen on Flutter Web under certain iframe setups). The two
    // handlers are idempotent because ``CommandPalette.show`` /
    // friends are modal and gate themselves against re-entry.
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final ctrl = HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed;
        if (!ctrl) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.keyK) {
          CommandPalette.show(context);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.keyP) {
          GlobalSearch.show(context);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.keyT) {
          GlobalSearch.show(context, mode: SearchMode.quickSwitcher);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.slash) {
          KeyboardShortcutsSheet.show(context);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.keyA &&
            HardwareKeyboard.instance.isShiftPressed) {
          if (AuthService().currentUser?.isAdmin == true) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AdminConsolePage(),
              ),
            );
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: widget.child,
    );
  }
}

// ─── Connectivity banner ─────────────────────────────────────────────────────
//
// Slim red strip pinned to the top of [MainWindow] whenever the SSE
// Socket.IO connection to the daemon is down. Driven by
// DigitornSocketService so no polling is needed — the socket's own
// connect/disconnect callbacks are the liveness signal.

class _ConnectivityBanner extends StatelessWidget {
  const _ConnectivityBanner();

  // Subtle disconnect banner — tinted bg (red @ 8% alpha) and red-on-
  // transparent text instead of the previous solid red strip with white
  // text. The user explicitly asked for "quelque chose d'un peu plus
  // subtil et simple" with the same retry semantics.
  //
  // This is the SOLE disconnect indicator — the duplicate strip that
  // used to render above the chat composer (`_buildDisconnectedBar` in
  // chat_panel.dart) has been removed now this banner is authoritative.
  @override
  Widget build(BuildContext context) {
    final socket = context.watch<DigitornSocketService>();
    if (socket.isConnected) return const SizedBox.shrink();
    final c = context.colors;
    // Capped to the composer rail (800 px on desktop, full-width on
    // < 600 px) and rendered as a centered chip with a full border
    // instead of an edge-to-edge strip. Strict mirror of the web
    // `ConnectivityBanner` after the same redesign.
    final isSmall = MediaQuery.of(context).size.width < 600;
    return SafeArea(
      bottom: false,
      child: Center(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxWidth: isSmall ? double.infinity : 800),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Material(
              color: c.red.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: c.red.withValues(alpha: 0.22),
                    width: 1,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 3),
                  child: Row(
                    children: [
                      Icon(Icons.cloud_off_rounded, size: 11, color: c.red),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'errors.daemon_unreachable'.tr(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: c.red),
                        ),
                      ),
                      const SizedBox(width: 6),
                      TextButton.icon(
                        onPressed: () => DigitornSocketService()
                            .connect(AuthService().baseUrl),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 1),
                          minimumSize: const Size(0, 22),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          backgroundColor: Colors.transparent,
                          foregroundColor: c.red,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                            side: BorderSide(
                              color: c.red.withValues(alpha: 0.35),
                            ),
                          ),
                        ),
                        icon: Icon(Icons.refresh_rounded,
                            size: 10, color: c.red),
                        label: Text(
                          'common.retry'.tr(),
                          style: GoogleFonts.inter(
                              fontSize: 10.5,
                              color: c.red,
                              fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
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
    final hasApp = state.activeApp != null;
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
                icon: Icons.apps_rounded,
                label: 'Apps',
                isActive: false,
                onTap: () => _showMobileAppsSheet(context, state),
              ),
              _MobileTab(
                icon: Icons.chat_bubble_outline_rounded,
                label: 'Chat',
                isActive: state.panel == ActivePanel.chat && hasApp,
                onTap: () => state.setPanel(ActivePanel.chat),
              ),
              if (hasApp)
                _MobileTab(
                  icon: Icons.history_rounded,
                  label: 'Sessions',
                  isActive: state.panel == ActivePanel.sessions,
                  onTap: () => state.setPanel(
                    state.panel == ActivePanel.sessions
                        ? ActivePanel.chat
                        : ActivePanel.sessions,
                  ),
                ),
              _MobileTab(
                icon: Icons.extension_rounded,
                label: 'Hub',
                isActive: state.panel == ActivePanel.hub,
                onTap: () => state.setPanel(
                  state.panel == ActivePanel.hub
                      ? (hasApp ? ActivePanel.chat : ActivePanel.dashboard)
                      : ActivePanel.hub,
                ),
              ),
              _MobileTab(
                icon: Icons.settings_outlined,
                label: 'Settings',
                isActive: state.panel == ActivePanel.settings,
                onTap: () => state.setPanel(
                  state.panel == ActivePanel.settings
                      ? (hasApp ? ActivePanel.chat : ActivePanel.dashboard)
                      : ActivePanel.settings,
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

// ─── Mobile Apps Sheet — opened from the mobile bottom bar ────────────────

void _showMobileAppsSheet(BuildContext context, AppState state) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _MobileAppsSheet(state: state),
  );
}

class _MobileAppsSheet extends StatefulWidget {
  final AppState state;
  const _MobileAppsSheet({required this.state});

  @override
  State<_MobileAppsSheet> createState() => _MobileAppsSheetState();
}

class _MobileAppsSheetState extends State<_MobileAppsSheet> {
  List<AppSummary> _apps = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final auth = AuthService();
    await auth.ensureValidToken();
    final client = DigitornApiClient()
      ..updateBaseUrl(auth.baseUrl, token: auth.accessToken);
    final fetched = await client.fetchApps();
    // Only deployed-and-healthy apps belong in the quick-launch
    // popover. Broken / not-deployed / disabled rows live in the
    // Hub Installed tab where the user can fix them — offering a
    // tap that would just fail here is worse UX than hiding them.
    final runnable = fetched.where((a) => a.isRunning).toList();
    if (mounted) setState(() { _apps = runnable; _loading = false; });
  }

  void _openApp(AppSummary app) async {
    Navigator.pop(context);
    await widget.state.setApp(app);
    SessionService().loadSessions(app.appId);
    BackgroundService().startPolling(
      app.appId,
      SessionService().activeSession?.sessionId ?? 'default',
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final activeId = widget.state.activeApp?.appId;
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scroll) => Container(
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border.all(color: c.border),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 6),
              child: Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: c.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 0, 12),
              child: Row(
                children: [
                  Icon(Icons.apps_rounded, size: 18, color: c.textBright),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      'Your apps',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: c.textBright,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => Navigator.pop(context),
                      customBorder: const CircleBorder(),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
                        child: Icon(Icons.close_rounded,
                            size: 22, color: c.textMuted),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: c.border),
            Expanded(
              child: _loading
                  ? const Center(
                      child: SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      ),
                    )
                  : _apps.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.inbox_rounded,
                                    size: 40, color: c.textDim),
                                const SizedBox(height: 12),
                                Text('No apps installed yet',
                                  textAlign: TextAlign.center,
                                  style: GoogleFonts.inter(
                                    fontSize: 13, color: c.textMuted)),
                                const SizedBox(height: 4),
                                Text(
                                  'Browse the Hub tab to install one',
                                  textAlign: TextAlign.center,
                                  style: GoogleFonts.inter(
                                    fontSize: 11, color: c.textDim)),
                              ],
                            ),
                          ),
                        )
                      : ListView.separated(
                          controller: scroll,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          itemCount: _apps.length,
                          separatorBuilder: (_, i) => Divider(
                            height: 1, color: c.border.withValues(alpha: 0.4),
                            indent: 20, endIndent: 20),
                          itemBuilder: (_, i) {
                            final app = _apps[i];
                            final isActive = app.appId == activeId;
                            return InkWell(
                              onTap: () => _openApp(app),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 20, vertical: 12),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 38, height: 38,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: c.surfaceAlt,
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                          color: isActive ? c.blue : c.border),
                                      ),
                                      child: Text(
                                        app.icon.isNotEmpty ? app.icon : '📦',
                                        style: const TextStyle(fontSize: 18),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            app.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: GoogleFonts.inter(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: c.textBright,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            app.appId,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: GoogleFonts.firaCode(
                                              fontSize: 10, color: c.textMuted),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (isActive) ...[
                                      const SizedBox(width: 8),
                                      Icon(Icons.check_rounded,
                                          size: 16, color: c.blue),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Activity Bar (Desktop, 56px icon sidebar) ─────────────────────────────

/// Intent used by the Esc shortcut inside the Apps popover to
/// close it. Kept as a lightweight class (no fields) because the
/// action callback knows the AppState from the captured closure.
class _ClosePopoverIntent extends Intent {
  const _ClosePopoverIntent();
}

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
      width: 60,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(
          right: BorderSide(color: c.border, width: 1),
        ),
      ),
      child: LayoutBuilder(builder: (ctx, constraints) {
        return SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: IntrinsicHeight(
              child: Padding(
                padding: const EdgeInsets.only(top: 22, bottom: 12),
                child: Column(
                  children: [
                    _BarItem(
                      icon: Icons.home_rounded,
                      tooltip: 'sidebar.home'.tr(),
                      isActive: state.panel == ActivePanel.dashboard &&
                          state.activeApp == null,
                      onTap: state.goHome,
                    ),
                    const SizedBox(height: 10),

          // Apps grid (waffle menu) — opens on hover, click also toggles.
          MouseRegion(
            onEnter: (_) => state.openAppsPanelHover(),
            onExit: (_) => state.scheduleAppsPanelClose(),
            child: _BarItem(
              icon: Icons.apps_rounded,
              tooltip: 'sidebar.apps'.tr(),
              isActive: state.showAppsPanel,
              onTap: () => state.toggleAppsPanel(),
            ),
          ),

          const SizedBox(height: 4),
          // Hub — install / browse apps, modules, MCP servers.
          // Behaves like Chat / Sessions / Settings: sets the
          // active panel so the activity bar stays visible and
          // the Hub fills the rest of the content area. Toggles
          // back to Chat (or Dashboard if no app is active) when
          // tapped a second time.
          _BarItem(
            icon: Icons.extension_rounded,
            tooltip: 'sidebar.hub'.tr(),
            isActive: state.panel == ActivePanel.hub,
            onTap: () => state.setPanel(
              state.panel == ActivePanel.hub
                  ? (state.activeApp != null
                      ? ActivePanel.chat
                      : ActivePanel.dashboard)
                  : ActivePanel.hub,
            ),
          ),


          if (hasApp) ...[
            const SizedBox(height: 4),
            _BarItem(
              icon: Icons.chat_bubble_outline_rounded,
              tooltip: 'sidebar.chat'.tr(),
              isActive: state.panel == ActivePanel.chat,
              onTap: () {
                state.setPanel(ActivePanel.chat);
                state.closeWorkspace();
              },
            ),
            const SizedBox(height: 4),
            _BarItem(
              icon: Icons.history_rounded,
              tooltip: 'sidebar.sessions'.tr(),
              isActive: state.panel == ActivePanel.sessions,
              onTap: () => state.setPanel(
                state.panel == ActivePanel.sessions
                    ? ActivePanel.chat
                    : ActivePanel.sessions,
              ),
            ),
            // Workspace toggle — only shown when the active app's
            // manifest actually supports a workspace. Apps whose YAML
            // The workspace affordance has moved out of the sidebar
            // — it now lives as a dedicated rail glued to the right
            // edge of the chat (see `WorkspaceRail`). Keeping it
            // here too would duplicate the same click target and
            // muddle the spatial model "your files live on the
            // right, not in a utility sidebar".
          ],

          const Spacer(),

          // Activity inbox bell
          const InboxBell(),
          const SizedBox(height: 6),

          // Account avatar — opens UserMenu (Settings / Language / Theme /
          // Help / Log out). Replaces the previous theme-toggle and
          // settings _BarItems. Mirror of web `<UserMenuButton/>`.
          const UserMenuButton(),
          const SizedBox(height: 10),

          // Connection dot
          Tooltip(
            message: socket.isConnected
                ? 'sidebar.connected'.tr()
                : 'sidebar.disconnected'.tr(),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 7, height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: socket.isConnected ? c.green : c.red,
                boxShadow: [
                  BoxShadow(
                    color: (socket.isConnected ? c.green : c.red)
                        .withValues(alpha: 0.45),
                    blurRadius: 6,
                  ),
                ],
              ),
            ),
          ),
                  ],
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _BarItem extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final bool isActive;
  final VoidCallback onTap;
  const _BarItem({
    required this.icon, required this.tooltip,
    required this.isActive, required this.onTap,
  });

  @override
  State<_BarItem> createState() => _BarItemState();
}

class _BarItemState extends State<_BarItem> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isActive = widget.isActive;

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOutCubic,
                width: 44,
                height: 44,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: isActive
                      ? Color.lerp(c.surfaceAlt, c.accentPrimary, 0.08) ??
                          c.surfaceAlt
                      : (_h ? c.surfaceAlt : c.surface),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isActive
                        ? c.accentPrimary.withValues(alpha: 0.4)
                        : (_h ? c.border : c.surface),
                  ),
                  boxShadow: isActive
                      ? [
                          BoxShadow(
                            color: c.glow.withValues(alpha: 0.22),
                            blurRadius: 14,
                            spreadRadius: -4,
                          ),
                        ]
                      : null,
                ),
                child: Center(
                  child: Icon(
                    widget.icon,
                    size: 20,
                    color: isActive
                        ? c.textBright
                        : (_h ? c.text : c.textMuted),
                  ),
                ),
              ),
              // Active indicator rail — thin accent bar on the left
              // edge. VS Code / Linear pattern.
              if (isActive)
                Positioned(
                  left: -2,
                  top: 10,
                  bottom: 10,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 3,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [c.accentPrimary, c.accentSecondary],
                      ),
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

// ─── Apps Popover (Google-waffle-style floating grid) ──────────────────────
//
// 3×3 grid of app tiles: logo on top, name centred below. Hovering a
// tile highlights it with a soft background + scale-up, and surfaces
// the app's description as a themed tooltip after a short delay.
// A green dot on the tile indicates a background app (subtle, only
// visible on those). If more than 9 apps are deployed, a "More apps"
// link at the bottom expands the grid to show all of them.

class _AppsPopover extends StatefulWidget {
  final AppState state;
  final VoidCallback onClose;
  const _AppsPopover({required this.state, required this.onClose});

  @override
  State<_AppsPopover> createState() => _AppsPopoverState();
}

class _AppsPopoverState extends State<_AppsPopover> {
  List<AppSummary> _apps = [];
  bool _loading = true;
  bool _showAll = false;

  static const int _initialCount = 9;

  @override
  void initState() {
    super.initState();
    // Pre-populate from cache so the popover renders instantly.
    final cache = widget.state.appsListCache;
    if (cache.isNotEmpty) {
      _apps = cache;
      _loading = false;
    }
    _load();
  }

  Future<void> _load() async {
    // Skip the network call if the cache is still fresh.
    if (widget.state.appsListCacheValid) return;

    // Cache stale or empty — fetch in background.
    try {
      final auth = AuthService();
      await auth.ensureValidToken();
      final client = DigitornApiClient()
        ..updateBaseUrl(auth.baseUrl, token: auth.accessToken);
      final fetched = await client.fetchApps();
      // Only deployed-and-healthy apps belong in the quick-launch
      // popover. Broken / not-deployed / disabled rows live in the
      // Hub Installed tab where the user can fix them — offering a
      // tap that would just fail here is worse UX than hiding them.
      final runnable = fetched.where((a) => a.isRunning).toList();
      widget.state.updateAppsCache(runnable);
      if (mounted) setState(() { _apps = runnable; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _loading = false; });
    }
  }

  void _openApp(AppSummary app) async {
    // Close the popover SYNCHRONOUSLY first. ``setApp`` awaits a
    // cascade (credentials gate, manifest fetch, widgets spec,
    // workspace reset) that can take 300-2000 ms. Leaving the
    // popover open during that wait used to look like "click did
    // nothing" — the user would tap again, racing two ``setApp``
    // calls and sometimes opening the wrong app.
    widget.onClose();
    await widget.state.setApp(app);
    SessionService().loadSessions(app.appId);
    BackgroundService().startPolling(
      app.appId,
      SessionService().activeSession?.sessionId ?? 'default',
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final visible = _showAll ? _apps : _apps.take(_initialCount).toList();
    final hasMore = _apps.length > _initialCount;

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 380,
        constraints: const BoxConstraints(maxHeight: 560),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.border),
          boxShadow: [
            BoxShadow(
              color: c.shadow,
              blurRadius: 40,
              offset: const Offset(0, 12),
            ),
            BoxShadow(
              color: c.shadow.withValues(alpha: 0.25),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: _loading
            ? const SizedBox(
                height: 220,
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PopoverHeader(
                    onDeploy: () async {
                      // Keep the popover alive during the deploy. The
                      // file picker opens as a native OS dialog, the
                      // mouse leaves the popover, and without this
                      // sticky block the hover-close would unmount us
                      // before we can show success / error snackbars.
                      widget.state.setAppsPanelBlockClose(true);
                      try {
                        final deployed = await runDeployFlow(context);
                        if (deployed != null && mounted) {
                          await _load();
                        }
                      } finally {
                        widget.state.setAppsPanelBlockClose(false);
                      }
                    },
                  ),
                  Container(height: 1, color: c.border),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                      child: GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: visible.length,
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 16,
                          crossAxisSpacing: 16,
                          childAspectRatio: 0.85,
                        ),
                        itemBuilder: (_, i) => _AppTile(
                          app: visible[i],
                          onTap: () => _openApp(visible[i]),
                        ),
                      ),
                    ),
                  ),
                  if (hasMore) ...[
                    Container(height: 1, color: c.border),
                    _MoreAppsButton(
                      showingAll: _showAll,
                      hiddenCount: _apps.length - _initialCount,
                      onTap: () => setState(() => _showAll = !_showAll),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}

// ─── Apps popover header (title + "+" deploy button) ──────────────────────

class _PopoverHeader extends StatelessWidget {
  final VoidCallback onDeploy;
  const _PopoverHeader({required this.onDeploy});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 10, 0),
        child: Row(
          children: [
            Text(
              'APPS',
              style: GoogleFonts.inter(
                fontSize: 10,
                color: c.textDim,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.6,
              ),
            ),
            const Spacer(),
            _PlusBtn(onTap: onDeploy),
          ],
        ),
      ),
    );
  }
}

class _PlusBtn extends StatefulWidget {
  final VoidCallback onTap;
  const _PlusBtn({required this.onTap});

  @override
  State<_PlusBtn> createState() => _PlusBtnState();
}

class _PlusBtnState extends State<_PlusBtn> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: 'Deploy a new app (YAML)',
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: _h
                  ? c.blue.withValues(alpha: 0.14)
                  : c.surfaceAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _h
                    ? c.blue.withValues(alpha: 0.4)
                    : c.border,
                width: _h ? 1.2 : 1,
              ),
              boxShadow: _h
                  ? [
                      BoxShadow(
                        color: c.blue.withValues(alpha: 0.2),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              Icons.add_rounded,
              size: 18,
              color: _h ? c.blue : c.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Apps tile ─────────────────────────────────────────────────────────────

class _AppTile extends StatefulWidget {
  final AppSummary app;
  final VoidCallback onTap;
  const _AppTile({required this.app, required this.onTap});

  @override
  State<_AppTile> createState() => _AppTileState();
}

class _AppTileState extends State<_AppTile> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final app = widget.app;
    final isBg = app.mode == 'background';

    // Real description from YAML first, heuristic fallback second.
    final desc = app.description.isNotEmpty
        ? app.description
        : _appDescription(app);

    return Tooltip(
      message: desc,
      waitDuration: const Duration(milliseconds: 400),
      preferBelow: true,
      verticalOffset: 12,
      textStyle: GoogleFonts.inter(
        fontSize: 11.5,
        color: c.text,
        height: 1.45,
      ),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
        boxShadow: [
          BoxShadow(
            color: c.shadow,
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.onTap,
          onSecondaryTapDown: (details) =>
              _showContextMenu(context, details.globalPosition),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(
                horizontal: 6, vertical: 8),
            decoration: BoxDecoration(
              color: _h
                  ? c.surfaceAlt.withValues(alpha: 0.9)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _h ? c.borderHover : Colors.transparent,
                width: 1,
              ),
              boxShadow: _h
                  ? [
                      BoxShadow(
                        color: c.shadow.withValues(alpha: 0.6),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: AnimatedScale(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              scale: _h ? 1.04 : 1.0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Icon (48×48) — real app icon from
                  // /api/apps/{id}/icon, no background, with the
                  // running-dot overlay for background apps.
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      RemoteIcon(
                        id: app.appId,
                        kind: RemoteIconKind.app,
                        size: 48,
                        transparent: true,
                        emojiFallback: app.icon,
                        nameFallback: app.name,
                      ),
                      if (isBg)
                        Positioned(
                          top: -2,
                          right: -2,
                          child: Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: c.green,
                              border: Border.all(
                                color: c.surface,
                                width: 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: c.green.withValues(alpha: 0.5),
                                  blurRadius: 6,
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // App name — 2 lines max, centred, tightened.
                  Text(
                    app.name,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 11.5,
                      height: 1.25,
                      fontWeight: FontWeight.w500,
                      color: _h ? c.textBright : c.text,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Context menu (right-click) ───────────────────────────────────────
  //
  // Built-in apps never show Stop/Delete — the daemon rejects those
  // calls with `Cannot remove built-in app`. Regular apps get all
  // three: Open, Stop, Delete. Delete asks for confirmation; Stop does
  // not (it's reversible, the daemon just evicts the app from memory).

  Future<void> _showContextMenu(BuildContext ctx, Offset pos) async {
    final app = widget.app;
    final c = ctx.colors;
    // Keep the popover open while the menu / confirmation dialog
    // is visible — otherwise mouse exits trigger the hover close.
    final appState = ctx.read<AppState>();
    appState.setAppsPanelBlockClose(true);
    try {
      final selected = await showMenu<String>(
        context: ctx,
        position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
        color: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: c.border),
        ),
        items: [
          PopupMenuItem(
            value: 'open',
            height: 36,
            child: _menuRow(c, Icons.open_in_new_rounded, 'Open', c.text),
          ),
          if (!app.builtin) ...[
            const PopupMenuDivider(height: 6),
            PopupMenuItem(
              value: 'stop',
              height: 36,
              child: _menuRow(c, Icons.pause_circle_outline_rounded,
                  'Stop', c.orange),
            ),
            PopupMenuItem(
              value: 'delete',
              height: 36,
              child: _menuRow(
                  c, Icons.delete_outline_rounded, 'Delete…', c.red),
            ),
          ],
        ],
      );
      if (!mounted || !ctx.mounted || selected == null) return;
      switch (selected) {
        case 'open':
          widget.onTap();
          break;
        case 'stop':
          await _runStop(ctx);
          break;
        case 'delete':
          await _runDelete(ctx);
          break;
      }
    } finally {
      appState.setAppsPanelBlockClose(false);
    }
  }

  Widget _menuRow(
      AppColors c, IconData icon, String label, Color color) {
    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 10),
        Text(label,
            style: GoogleFonts.inter(
                fontSize: 12, color: c.text, fontWeight: FontWeight.w500)),
      ],
    );
  }

  Future<void> _runStop(BuildContext ctx) async {
    final c = ctx.colors;
    try {
      await AppsService().stop(widget.app.appId);
      if (!ctx.mounted) return;
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
        content: Text(
          'Stopped: ${widget.app.name} · will reload at next daemon restart',
        ),
        backgroundColor: c.orange.withValues(alpha: 0.9),
      ));
    } on DeployException catch (e) {
      if (!ctx.mounted) return;
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
        content: Text('Stop failed: ${e.message}'),
        backgroundColor: c.red.withValues(alpha: 0.9),
      ));
    }
  }

  Future<void> _runDelete(BuildContext ctx) async {
    final confirmed = await _confirmDelete(ctx);
    if (!confirmed || !ctx.mounted) return;
    final c = ctx.colors;
    try {
      await AppsService().delete(widget.app.appId);
      if (!ctx.mounted) return;
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
        content: Text('Deleted: ${widget.app.name}'),
        backgroundColor: c.green.withValues(alpha: 0.9),
      ));
    } on DeployException catch (e) {
      if (!ctx.mounted) return;
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
        content: Text('Delete failed: ${e.message}'),
        backgroundColor: c.red.withValues(alpha: 0.9),
      ));
    }
  }

  Future<bool> _confirmDelete(BuildContext ctx) async {
    final c = ctx.colors;
    final res = await showDialog<bool>(
      context: ctx,
      barrierDismissible: true,
      builder: (_) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c.border),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded, size: 18, color: c.red),
            const SizedBox(width: 10),
            Text('Delete permanently?',
                style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: c.textBright)),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(
            "Delete '${widget.app.name}' permanently?\n\n"
            'This removes the bundle, database records, sessions and '
            'secrets. Cannot be undone.',
            style: GoogleFonts.inter(
                fontSize: 12.5, color: c.text, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel',
                style: GoogleFonts.inter(
                    fontSize: 12, color: c.textMuted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: c.red,
              foregroundColor: c.contrastOn(c.red),
              elevation: 0,
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6)),
            ),
            child: Text('Delete permanently',
                style: GoogleFonts.inter(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    return res == true;
  }
}

// ─── "More apps" footer ────────────────────────────────────────────────────

class _MoreAppsButton extends StatefulWidget {
  final bool showingAll;
  final int hiddenCount;
  final VoidCallback onTap;
  const _MoreAppsButton({
    required this.showingAll,
    required this.hiddenCount,
    required this.onTap,
  });

  @override
  State<_MoreAppsButton> createState() => _MoreAppsButtonState();
}

class _MoreAppsButtonState extends State<_MoreAppsButton> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final label = widget.showingAll
        ? 'Show less'
        : 'More apps  (${widget.hiddenCount})';
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 44,
          alignment: Alignment.center,
          color: _h ? c.surfaceAlt.withValues(alpha: 0.4) : Colors.transparent,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: _h ? c.textBright : c.textMuted,
                  decoration: _h ? TextDecoration.underline : null,
                  decorationColor: c.textBright,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                widget.showingAll
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_right_rounded,
                size: 14,
                color: _h ? c.textBright : c.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _appDescription(AppSummary app) {
  // Try to generate a meaningful description
  final name = app.name.toLowerCase();
  final mods = app.modules;

  // Known app patterns
  if (name.contains('chat') || name.contains('code') || name.contains('opencode')) {
    return 'AI coding assistant · ${app.totalTools} tools';
  }
  if (name.contains('job') || name.contains('match')) {
    return 'Automated job matching agent';
  }
  if (name.contains('review')) {
    return 'Code review automation';
  }
  if (name.contains('monitor') || name.contains('watch')) {
    return 'Monitoring & alerting agent';
  }
  if (name.contains('doc') || name.contains('write')) {
    return 'Document generation agent';
  }

  // Fallback: describe by capabilities
  if (mods.isNotEmpty) {
    final capabilities = <String>[];
    if (mods.contains('web') || mods.contains('http')) capabilities.add('web');
    if (mods.contains('git')) capabilities.add('git');
    if (mods.contains('shell') || mods.contains('filesystem')) capabilities.add('system');
    if (mods.contains('database') || mods.contains('sql')) capabilities.add('database');
    if (mods.contains('memory')) capabilities.add('memory');
    if (capabilities.isNotEmpty) {
      return '${capabilities.join(', ')} · ${app.totalTools} tools';
    }
    return '${mods.take(3).join(', ')} · ${app.totalTools} tools';
  }

  return '${app.totalTools} tools · ${app.agents.length} agent${app.agents.length > 1 ? 's' : ''}';
}

class _AppCard2 extends StatefulWidget {
  final AppSummary app;
  final VoidCallback onTap;
  const _AppCard2({required this.app, required this.onTap});

  @override
  State<_AppCard2> createState() => _AppCard2State();
}

class _AppCard2State extends State<_AppCard2> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final app = widget.app;
    final isBg = app.mode == 'background';

    // Icon
    final hash = app.name.hashCode;
    final hue1 = (hash % 360).toDouble();
    final hue2 = ((hash ~/ 7) % 360).toDouble();
    final c1 = HSLColor.fromAHSL(1, hue1, 0.6, 0.5).toColor();
    final c2 = HSLColor.fromAHSL(1, hue2, 0.5, 0.4).toColor();

    // Semantic icon
    final iconData = isBg ? Icons.bolt_rounded : Icons.chat_rounded;

    // Smart description
    final desc = _appDescription(app);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _h ? c.surfaceAlt : c.bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _h ? c.borderHover : c.border,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Icon row
              Row(
                children: [
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [c1, c2],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(iconData,
                        size: 18, color: c.contrastOn(c1)),
                  ),
                  const Spacer(),
                  if (isBg)
                    Container(
                      width: 8, height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: c.green,
                        boxShadow: [BoxShadow(
                          color: c.green.withValues(alpha: 0.4),
                          blurRadius: 4,
                        )],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              // Name
              Text(app.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 13, fontWeight: FontWeight.w600, color: c.textBright)),
              const SizedBox(height: 3),
              // Description
              Text(desc,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(fontSize: 10, color: c.textMuted)),
              const SizedBox(height: 8),
              // Footer
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: (isBg ? c.purple : c.blue).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      isBg ? 'Background' : 'Chat',
                      style: GoogleFonts.firaCode(
                        fontSize: 8, color: isBg ? c.purple : c.blue),
                    ),
                  ),
                  const Spacer(),
                  Text('v${app.version}',
                    style: GoogleFonts.firaCode(fontSize: 9, color: c.textDim)),
                ],
              ),
            ],
          ),
        ),
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
  double _sessionDrawerWidth = 280;
  // Default split: chat ~62%, workspace ~38%. Workspace is capped
  // at half the viewport so it never out-shouts the conversation —
  // the chat is the primary surface, the workspace is a sidekick.
  final SplitViewController _splitCtrl = SplitViewController(
    weights: [0.62, 0.38],
    limits: [
      WeightLimit(min: 0.5, max: 0.8),
      WeightLimit(min: 0.2, max: 0.5),
    ],
  );

  AppState get state => widget.state;

  @override
  Widget build(BuildContext context) {
    // ── Settings and Hub are kept mounted at all times (Offstage) ──────────
    // Previously these were conditional returns — every open destroyed the
    // widget and recreated it, firing all initState() network calls.
    // Offstage keeps the widget tree alive (state preserved, no refetch)
    // and only skips layout/painting when not visible.
    final inSettings = state.panel == ActivePanel.settings;
    final inHub = state.panel == ActivePanel.hub;
    final inOther = !inSettings && !inHub;

    // Positioned.fill gives each child tight constraints matching the
    // Stack's own size (which fills the parent Expanded). Without it,
    // Stack gives non-positioned children *loose* constraints — the Row
    // and AppSelector would collapse to zero height and be invisible.
    return Stack(
      children: [
        // Settings — always mounted, hidden when not active
        Positioned.fill(
          child: Offstage(
            offstage: !inSettings,
            child: IgnorePointer(
              ignoring: !inSettings,
              child: const SettingsPage(),
            ),
          ),
        ),
        // Hub — always mounted, hidden when not active
        Positioned.fill(
          child: Offstage(
            offstage: !inHub,
            child: IgnorePointer(
              ignoring: !inHub,
              child: const HubPage(embedded: true),
            ),
          ),
        ),
        // Everything else (dashboard, chat, background, oneshot)
        if (inOther) Positioned.fill(child: _buildMainContent(context)),
      ],
    );
  }

  Widget _buildMainContent(BuildContext context) {
    if (state.activeApp == null) {
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: AppSelector(
          key: const ValueKey('dashboard'),
          onAppSelected: (app, {String? initialMessage}) async {
            state.pendingMessage = initialMessage;
            await state.setApp(app);
            SessionService().loadSessions(app.appId);
            BackgroundService().startPolling(
              app.appId,
              SessionService().activeSession?.sessionId ?? 'default',
            );
          },
        ),
      );
    }

    // ── Mode dispatch ───────────────────────────────────────────────────
    // Three execution modes drive three completely different UIs:
    //   * background   → [BackgroundDashboard] (triggers, runs, health)
    //   * oneshot      → [OneshotPanel]        (stateless API-style form)
    //   * conversation → standard chat (falls through below)
    //
    // Both AppSummary.mode (aggregated at /api/apps time) and the
    // manifest's execution.mode are accepted — whichever resolves
    // first wins, so a late-arriving manifest still routes correctly.
    final summaryMode = state.activeApp!.mode;
    final isBackgroundApp =
        summaryMode == 'background' || state.manifest.isBackground;
    if (isBackgroundApp) {
      return BackgroundDashboard(
        app: state.activeApp!,
        onBack: () => state.clearApp(),
      );
    }
    final isOneshotApp =
        summaryMode == 'oneshot' || state.manifest.isOneshot;
    if (isOneshotApp) {
      return const OneshotPanel();
    }

    // ── Conversation app: chat + optional panels ─────────────────────────
    final showSessions = state.panel == ActivePanel.sessions;

    final screenWidth = MediaQuery.of(context).size.width;
    // Auto-close sessions/workspace on narrow viewports — strict
    // parity with web (`client.tsx` resize hook). Threshold 900 for
    // the history drawer (320 + chat 580 = floor before the composer
    // truncates), 700 for the workspace (which is the active surface
    // and survives a tighter chat). We CLOSE the panel state via a
    // post-frame callback so the next rebuild renders the chat
    // full-width — identical to the web's `setDrawerOpen(false)`.
    final shouldAutoCloseSessions = showSessions && screenWidth < 900;
    final shouldAutoCloseWorkspace =
        state.isWorkspaceVisible && screenWidth < 700;
    if (shouldAutoCloseSessions || shouldAutoCloseWorkspace) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (shouldAutoCloseSessions) state.setPanel(ActivePanel.chat);
        if (shouldAutoCloseWorkspace) state.closeWorkspace();
      });
    }
    final effectiveShowSessions = showSessions && screenWidth >= 900;

    return Row(
      children: [
        // Session drawer (animated slide-in, resizable)
        if (effectiveShowSessions) ...[
          SizedBox(
            width: _sessionDrawerWidth,
            child: SessionDrawer(
              appId: state.activeApp!.appId,
              onClose: () => state.setPanel(ActivePanel.chat),
            ),
          ),
          // Resize handle
          MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              onHorizontalDragUpdate: (d) {
                setState(() {
                  _sessionDrawerWidth = (_sessionDrawerWidth + d.delta.dx).clamp(200, 450);
                });
              },
              child: Container(
                width: 4,
                color: Colors.transparent,
                child: Center(
                  child: Container(width: 1, color: context.colors.border),
                ),
              ),
            ),
          ),
        ],

        // Main content area
        Expanded(
          child: _chatOrSplit(context, state),
        ),
      ],
    );
  }

  widgets_disp.ActionHooks _buildWidgetHooks(AppState state) {
    return widgets_disp.ActionHooks(
      chatSender: (msg, {bool silent = false, Map<String, dynamic>? context}) async {
        if (silent) return;
        state.injectChatMessage(msg);
      },
      toolRunner: (tool, args) async {
        // Route tool invocation through the widgets endpoint —
        // the daemon handles tool execution centrally and returns
        // the result envelope.
        final resp = await widgets_service.WidgetsService().postAction(
          state.activeApp?.appId ?? '',
          payload: {
            'type': 'tool',
            'payload': {'tool': tool, 'args': args},
          },
        );
        if (resp == null) return null;
        return resp['result'] ?? resp['data'] ?? resp;
      },
      openModal: (name, ctx) {
        final modal = state.activeAppWidgets.modals[name];
        if (modal == null) return;
        final navCtx = rootNavigatorKey.currentContext;
        if (navCtx == null) return;
        widgets_zones.showWidgetModalZ4(
          navCtx,
          appId: state.activeApp?.appId ?? '',
          modalName: name,
          pane: modal,
          hooks: _buildWidgetHooks(state),
          ctx: ctx ?? const {},
        );
      },
      openWorkspace: ({
        String? tabId,
        widgets_models.WidgetNode? tree,
        String? ref,
        Map<String, dynamic>? ctx,
        String? title,
        String? icon,
      }) {
        // Goes through `showWorkspace` so the workspace_mode: none
        // opt-out is honoured and the dismissed latch clears.
        state.showWorkspace();
        WorkspaceService().setActiveTab('widgets');
      },
      navigate: ({String? appId, String? workspaceTab}) {
        if (workspaceTab != null) {
          state.showWorkspace();
          WorkspaceService().setActiveTab(workspaceTab);
        }
      },
      closeHost: null,
    );
  }

  Widget _chatOrSplit(BuildContext context, AppState state) {
    final chat = ChatPanel(key: _chatKey);
    final screenWidth = MediaQuery.of(context).size.width;

    // Z2 — chat companion panel. Mounted to the left of the chat
    // when the app declares `widgets.chat_side:` AND the screen is
    // wide enough (< 980px collapses to avoid crushing the chat).
    final chatSide = state.activeAppWidgets.chatSide;
    Widget primary = chat;
    if (chatSide != null && screenWidth >= 980) {
      primary = Row(
        children: [
          widgets_zones.ChatSidePanelZ2(
            key: ValueKey('z2-${state.activeApp?.appId}'),
            appId: state.activeApp?.appId ?? '',
            pane: chatSide,
            hooks: _buildWidgetHooks(state),
            session: {
              'session_id':
                  SessionService().activeSession?.sessionId ?? '',
              'user': AuthService().currentUser?.displayName ?? '',
              'app_id': state.activeApp?.appId ?? '',
            },
            app: {
              'id': state.activeApp?.appId ?? '',
              'name': state.activeApp?.name ?? '',
            },
          ),
          Expanded(child: chat),
        ],
      );
    }

    // Auto-hide workspace and sessions on narrow screens
    if (screenWidth < 600) {
      // Mobile: no split, only chat or workspace (toggle via bottom bar)
      if (state.isWorkspaceVisible && state.panel == ActivePanel.workspace) {
        return const WorkspacePanel();
      }
      return primary;
    }

    if (state.isWorkspaceVisible) {
      return SplitView(
        key: const ValueKey('split'),
        viewMode: SplitViewMode.Horizontal,
        // Visible 2px gripper in the theme border colour so the
        // resize affordance is discoverable. Was 4px transparent — a
        // hot-zone with no visual hint, so users couldn't see they
        // could drag.
        gripSize: 2,
        gripColor: context.colors.border,
        gripColorActive: context.colors.accentPrimary,
        indicator: const SizedBox.shrink(),
        controller: _splitCtrl,
        children: [
          ClipRect(child: primary),
          const ClipRect(child: WorkspacePanel()),
        ],
      );
    }

    // Workspace rail removed — the compact "Workspace" toggle now
    // lives in the top-right of the chat panel (see
    // `_buildWorkspaceToggle` in chat_panel.dart). Avoids two
    // affordances doing the same job.
    return primary;
  }
}



