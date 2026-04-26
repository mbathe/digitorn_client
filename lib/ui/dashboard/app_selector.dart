import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shimmer/shimmer.dart';
import '../../main.dart';
import '../../models/app_summary.dart';
import '../../services/api_client.dart';
import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';
import '../common/remote_icon.dart';
import 'deploy_flow.dart';

class AppSelector extends StatefulWidget {
  final Function(AppSummary, {String? initialMessage}) onAppSelected;
  const AppSelector({super.key, required this.onAppSelected});

  @override
  State<AppSelector> createState() => _AppSelectorState();
}

class _AppSelectorState extends State<AppSelector> {
  List<AppSummary> apps = [];
  bool isLoading = true;
  bool _launching = false;
  final _chatCtrl = TextEditingController();
  final _chatFocus = FocusNode();
  final _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    // Pre-populate from cache so the dashboard renders instantly.
    final appState = context.read<AppState>();
    final cached = appState.appsListCache;
    if (cached.isNotEmpty) {
      apps = cached;
      isLoading = false;
    }
    _fetchApps(appState);
  }

  @override
  void dispose() {
    _chatCtrl.dispose();
    _chatFocus.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchApps([AppState? appState]) async {
    final state = appState ?? context.read<AppState>();
    // Skip if the cache is still fresh and we already have data.
    if (state.appsListCacheValid && apps.isNotEmpty) return;
    final auth = AuthService();
    await auth.ensureValidToken();
    final client = DigitornApiClient()
      ..updateBaseUrl(auth.baseUrl, token: auth.accessToken);
    final fetched = await client.fetchApps();
    state.updateAppsCache(fetched);
    if (!mounted) return;
    if (isLoading) {
      // Transitioning from the shimmer — must call setState.
      setState(() { apps = fetched; isLoading = false; });
    } else {
      // Already showing content. Silently update the data so the next
      // interaction (chip tap, send) uses fresh app status without
      // triggering a visible rebuild that the user might see as a
      // "refresh" just before they press Enter.
      apps = fetched;
    }
  }

  Future<void> _deployApp() async {
    final deployed = await runDeployFlow(context);
    if (deployed != null && mounted) {
      setState(() => isLoading = true);
      _fetchApps();
    }
  }

  /// Only deployed-and-healthy apps can serve a session. The daemon's
  /// unified `runtime_status` contract says `"running"` is the only
  /// value the UI may surface as launchable — every other value
  /// (`broken`, `not_deployed`, `disabled`) belongs in the Hub
  /// Installed tab with its own lifecycle actions.
  List<AppSummary> get _launchableApps =>
      apps.where((a) => a.isRunning).toList();

  /// Find the default conversation app (digitorn-chat).
  AppSummary? get _defaultChatApp {
    final runnable = _launchableApps;
    final digitornChat = runnable.where((a) =>
        a.appId == 'digitorn-chat' ||
        a.appId == 'digitorn_chat' ||
        a.name.toLowerCase().contains('digitorn') &&
            a.name.toLowerCase().contains('chat'));
    if (digitornChat.isNotEmpty) return digitornChat.first;
    final conv = runnable.where((a) => a.mode != 'background');
    if (conv.isNotEmpty) return conv.first;
    return runnable.isNotEmpty ? runnable.first : null;
  }

  void _onChatSubmit() {
    if (_launching) return;
    final defaultApp = _defaultChatApp;
    debugPrint(
        '_onChatSubmit: defaultApp=${defaultApp?.appId} (${defaultApp?.name})');
    if (defaultApp != null) {
      _launching = true;
      final text = _chatCtrl.text.trim();
      widget.onAppSelected(defaultApp,
          initialMessage: text.isNotEmpty ? text : null);
    }
  }

  /// Apps to surface on the dashboard. We don't show everything —
  /// only a handful of "important" ones so the home stays uncluttered.
  /// Priority: conversation apps first, then background; `digitorn-*`
  /// system apps first inside each bucket so the official ones show
  /// up above third-party deployments. Capped at 4. Only apps whose
  /// `runtime_status == "running"` are eligible — the others live in
  /// the Hub so the user can fix or delete them there.
  List<AppSummary> get _featuredApps {
    final defaultApp = _defaultChatApp;
    final runnable = _launchableApps;
    final convApps = runnable
        .where((a) => a.mode != 'background' && a.appId != defaultApp?.appId)
        .toList();
    final bgApps = runnable.where((a) => a.mode == 'background').toList();
    int rank(AppSummary a) {
      if (a.appId.startsWith('digitorn-') ||
          a.appId.startsWith('digitorn_')) {
        return 0;
      }
      return 1;
    }

    convApps.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.name.compareTo(b.name);
    });
    bgApps.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.name.compareTo(b.name);
    });
    return [...convApps, ...bgApps].take(4).toList();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    if (isLoading) {
      return Container(color: c.bg, child: _LoadingSkeleton());
    }

    if (apps.isEmpty) {
      return _EmptyState(onRefresh: _fetchApps, onDeploy: _deployApp);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // ── Responsive breakpoints ─────────────────────────────────
        // mobile  < 600  → 1 col featured apps, compact padding
        // tablet  < 900  → 2 col featured apps
        // desktop >= 900 → 2 col featured apps, generous padding
        final w = constraints.maxWidth;
        final isMobile = w < 600;
        final isTablet = w >= 600 && w < 900;
        final hPad = isMobile ? 18.0 : (isTablet ? 32.0 : 48.0);
        final vPad = isMobile ? 24.0 : 40.0;

        return Container(
          color: c.bg,
          child: SafeArea(
            child: Scrollbar(
              controller: _scrollCtrl,
              child: SingleChildScrollView(
                controller: _scrollCtrl,
                padding: EdgeInsets.symmetric(
                    horizontal: hPad, vertical: vPad),
                child: Center(
                  // The outer column is slightly wider than the
                  // chat input so the apps row can breathe — the
                  // chat input itself is still capped at the chat
                  // panel's native 720px (see Center wrapper below).
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 880),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // ── Hero header ─────────────────────────
                        Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: isMobile ? 56 : 72,
                                height: isMobile ? 56 : 72,
                                child: Image.asset(
                                  'assets/logo.png',
                                  fit: BoxFit.contain,
                                ),
                              ),
                              SizedBox(height: isMobile ? 12 : 16),
                              Text(
                                'Hello',
                                style: GoogleFonts.inter(
                                  fontSize: isMobile ? 24 : 30,
                                  fontWeight: FontWeight.w700,
                                  color: c.textBright,
                                  letterSpacing: -0.5,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'How can I help you today?',
                                textAlign: TextAlign.center,
                                style: GoogleFonts.inter(
                                  fontSize: isMobile ? 13 : 15,
                                  color: c.textMuted,
                                  height: 1.45,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(height: isMobile ? 20 : 28),

                        // ── Chat input ──────────────────────────
                        // Capped at 720px to mirror exactly the
                        // ConstrainedBox in chat_panel.dart so the
                        // user sees the same input width on the
                        // home screen as inside any app.
                        Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: isMobile ? double.infinity : 720,
                            ),
                            child: _DashboardChatInput(
                              controller: _chatCtrl,
                              focusNode: _chatFocus,
                              onSend: _onChatSubmit,
                              compact: isMobile,
                            ),
                          ),
                        ),
                        SizedBox(height: isMobile ? 22 : 28),

                        // ── Featured apps ───────────────────────
                        // Only a few important apps make it to the
                        // home screen; the rest live behind the
                        // sidebar's Apps button.
                        _buildFeaturedAppsSection(
                          c,
                          isMobile: isMobile,
                          isTablet: isTablet,
                        ),

                        SizedBox(height: isMobile ? 22 : 32),

                        // ── Footer ──────────────────────────────
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _FooterBtn(
                              icon: Icons.refresh_rounded,
                              label: 'dashboard.refresh'.tr(),
                              onTap: () {
                                setState(() => isLoading = true);
                                _fetchApps();
                              },
                            ),
                            const SizedBox(width: 24),
                            _FooterBtn(
                              icon: Icons.logout_rounded,
                              label: 'dashboard.logout'.tr(),
                              onTap: () => AuthService().logout(),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Centered wrap of small icon-only app chips. No header, no
  /// background — just the apps floating directly under the chat
  /// input. The "See all" link only renders when there are more
  /// apps than what we surface (and points at the sidebar's apps
  /// panel for the full list).
  Widget _buildFeaturedAppsSection(
    AppColors c, {
    required bool isMobile,
    required bool isTablet,
  }) {
    final featured = _featuredApps;
    final extra = apps.length - featured.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          spacing: isMobile ? 18 : 28,
          runSpacing: isMobile ? 16 : 22,
          children: [
            for (final a in featured)
              _AppChip(
                app: a,
                onTap: () => widget.onAppSelected(a),
              ),
          ],
        ),
        if (extra > 0) ...[
          const SizedBox(height: 14),
          Center(
            child: _SeeAllButton(
              label: 'dashboard.see_all_more'
                  .tr(namedArgs: {'n': '$extra'}),
              onTap: () {
                Provider.of<AppState>(context, listen: false)
                    .toggleAppsPanel();
              },
            ),
          ),
        ],
      ],
    );
  }
}

class _SeeAllButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const _SeeAllButton({
    required this.label,
    required this.onTap,
  });

  @override
  State<_SeeAllButton> createState() => _SeeAllButtonState();
}

class _SeeAllButtonState extends State<_SeeAllButton> {
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
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: _h ? c.textMuted.withValues(alpha: 0.1) : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            widget.label,
            style: GoogleFonts.inter(
              fontSize: 10.5,
              color: c.textMuted,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Dashboard chat input ──────────────────────────────────────────────────
//
// Single-unit design: one rounded container with the textarea and a
// small floating send button on the right. **No separator, no bottom
// bar, no extra icons** — the whole thing is one visual block that
// leaves space for the 4 suggestion chips below it.
//
// Behaviour still mirrors the real chat input (`chat_panel._ChatInput`):
// - Enter submits, Shift+Enter inserts a newline (multiline TextField).
// - The textarea grows from 1 to 8 lines on content.
// - Same typography tokens (inter 14 / line-height 1.55).

class _SendIntent extends Intent {
  const _SendIntent();
}

class _DashboardChatInput extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final bool compact;

  const _DashboardChatInput({
    required this.controller,
    required this.focusNode,
    required this.onSend,
    this.compact = false,
  });

  @override
  State<_DashboardChatInput> createState() => _DashboardChatInputState();
}

class _DashboardChatInputState extends State<_DashboardChatInput> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    super.dispose();
  }

  void _onFocusChange() {
    if (!mounted) return;
    setState(() => _focused = widget.focusNode.hasFocus);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: c.inputBg,
        // Border radius 12 matches chat_panel._ChatInput exactly so
        // users feel the same corner curvature on both surfaces.
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _focused ? c.blue.withValues(alpha: 0.5) : c.inputBorder,
          width: _focused ? 1.4 : 1.0,
        ),
        // Elevation — deliberately strong so the input pops above the
        // rest of the page. Two layered shadows: a wide soft ambient
        // one, and a tighter key shadow right under the container for
        // a clear "floating" feel.
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: _focused ? 0.20 : 0.14),
            blurRadius: _focused ? 32 : 24,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Padding(
              // Vertical padding shrinks on mobile so the input
              // doesn't eat half the viewport on short screens.
              padding: EdgeInsets.fromLTRB(
                widget.compact ? 14 : 20,
                widget.compact ? 16 : 26,
                10,
                widget.compact ? 16 : 26,
              ),
              child: Shortcuts(
                shortcuts: const {
                  SingleActivator(LogicalKeyboardKey.enter): _SendIntent(),
                },
                child: Actions(
                  actions: {
                    _SendIntent: CallbackAction<_SendIntent>(
                      onInvoke: (_) {
                        widget.onSend();
                        return null;
                      },
                    ),
                  },
                  child: TextField(
                    controller: widget.controller,
                    focusNode: widget.focusNode,
                    minLines: 1,
                    maxLines: 8,
                    maxLength: 32000,
                    keyboardType: TextInputType.multiline,
                    style: GoogleFonts.inter(
                        fontSize: 14.5,
                        color: c.text,
                        height: 1.55),
                    decoration: InputDecoration(
                      hintText: 'dashboard.ask_anything'.tr(),
                      hintStyle: GoogleFonts.inter(
                          fontSize: 14.5, color: c.textMuted),
                      border: InputBorder.none,
                      isCollapsed: true,
                      counterText: '',
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 14, bottom: 14),
            child: _SendBtn(onTap: widget.onSend),
          ),
        ],
      ),
    );
  }
}

/// Small circular send button — **pixel-identical** to
/// `chat_panel._SendButton`: 28×28 circle, `borderHover` at rest and
/// `textMuted` on hover, with a white (`textBright`) arrow inside.
/// We deliberately do *not* use an accent colour here so the dashboard
/// input looks and feels the same as the real chat composer.
class _SendBtn extends StatefulWidget {
  final VoidCallback onTap;
  const _SendBtn({required this.onTap});

  @override
  State<_SendBtn> createState() => _SendBtnState();
}

class _SendBtnState extends State<_SendBtn> {
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
          duration: const Duration(milliseconds: 100),
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: _h ? c.textMuted : c.borderHover,
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.arrow_upward_rounded,
            size: 14,
            color: c.textBright,
          ),
        ),
      ),
    );
  }
}

// ─── App chip ──────────────────────────────────────────────────────────────
//
// Tiny launcher entry — the real app icon (fetched from the daemon
// via `/api/apps/{id}/icon` through [RemoteIcon]) on top, the name
// underneath. No background, no border, no shadow — the icon
// floats directly on the home screen background. Hover lifts the
// row by a couple of pixels and brightens the label.

class _AppChip extends StatefulWidget {
  final AppSummary app;
  final VoidCallback onTap;
  const _AppChip({required this.app, required this.onTap});

  @override
  State<_AppChip> createState() => _AppChipState();
}

class _AppChipState extends State<_AppChip> {
  bool _h = false;
  bool _busy = false;

  /// Click handler — flips the chip into a busy state immediately so
  /// the user gets visual feedback while [setApp] does its async
  /// work (credentials gate + widgets fetch + session create can
  /// take 200–500ms combined). Also guards against double-tap: the
  /// second click inside the same open is swallowed instead of
  /// firing [setApp] twice.
  Future<void> _handleTap() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // `onTap` is a VoidCallback but in practice points at an async
      // function in main.dart (`state.setApp(app)`). We don't await
      // it — the parent rebuild will swap the dashboard out once
      // activeApp is set. We just keep the busy flag up long enough
      // for that rebuild to happen.
      widget.onTap();
      // Give the parent rebuild ~800ms to swap us out. If we're
      // still mounted after that, reset the busy flag so the user
      // can try again (gate was cancelled, error, etc.).
      await Future.delayed(const Duration(milliseconds: 800));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final app = widget.app;
    return Tooltip(
      // Tooltip wants either `message` or `richMessage`, not both.
      // We use `richMessage` below so we can split bold name from
      // muted description with two TextSpans.
      waitDuration: const Duration(milliseconds: 350),
      preferBelow: true,
      verticalOffset: 36,
      // Themed decoration that matches the app's surface palette
      // — the default Material tooltip is a flat dark rect that
      // looks out of place on light themes and on our dark theme
      // alike. This one is a card that blends in.
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      margin: const EdgeInsets.symmetric(horizontal: 12),
      textStyle: GoogleFonts.inter(
        fontSize: 12,
        color: c.text,
        height: 1.5,
      ),
      // Keep the tooltip narrow so long descriptions wrap rather
      // than stretching across the screen.
      constraints: const BoxConstraints(maxWidth: 280),
      richMessage: TextSpan(
        children: [
          TextSpan(
            text: app.name,
            style: GoogleFonts.inter(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: c.textBright,
              letterSpacing: -0.1,
              height: 1.45,
            ),
          ),
          if (app.description.trim().isNotEmpty)
            TextSpan(
              text: '\n${app.description.trim()}',
              style: GoogleFonts.inter(
                fontSize: 11.5,
                color: c.textMuted,
                height: 1.5,
              ),
            ),
        ],
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: _busy ? null : _handleTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            width: 84,
            transform: Matrix4.identity()
              ..translateByDouble(0.0, _h ? -2.0 : 0.0, 0.0, 1.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Stack the icon with a translucent overlay + spinner
                // when we're busy, so the user gets instant feedback
                // that their click registered without having to wait
                // for the parent rebuild.
                SizedBox(
                  width: 56,
                  height: 56,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Opacity(
                        opacity: _busy ? 0.35 : 1.0,
                        child: RemoteIcon(
                          id: app.appId,
                          kind: RemoteIconKind.app,
                          size: 56,
                          transparent: true,
                          emojiFallback: app.icon,
                          nameFallback: app.name,
                        ),
                      ),
                      if (_busy)
                        SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: c.blue,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 9),
                Text(
                  app.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _busy
                        ? c.textMuted
                        : (_h ? c.textBright : c.text),
                    letterSpacing: -0.1,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Footer button ─────────────────────────────────────────────────────────

class _FooterBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _FooterBtn(
      {required this.icon, required this.label, required this.onTap});

  @override
  State<_FooterBtn> createState() => _FooterBtnState();
}

class _FooterBtnState extends State<_FooterBtn> {
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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(widget.icon, size: 12, color: _h ? c.text : c.textDim),
            const SizedBox(width: 5),
            Text(
              widget.label,
              style: GoogleFonts.inter(
                fontSize: 11,
                color: _h ? c.text : c.textDim,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Loading skeleton ──────────────────────────────────────────────────────

class _LoadingSkeleton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Shimmer.fromColors(
        baseColor: c.skeleton,
        highlightColor: c.skeletonHighlight,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(12))),
            const SizedBox(height: 24),
            Container(
                width: 120,
                height: 16,
                decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(4))),
            const SizedBox(height: 12),
            Container(
                width: 200,
                height: 12,
                decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(4))),
            const SizedBox(height: 32),
            Container(
                constraints: const BoxConstraints(maxWidth: 480),
                width: double.infinity,
                height: 60,
                decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(14))),
            const SizedBox(height: 32),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                    width: 110,
                    height: 42,
                    decoration: BoxDecoration(
                        color: c.surface,
                        borderRadius: BorderRadius.circular(22))),
                const SizedBox(width: 10),
                Container(
                    width: 110,
                    height: 42,
                    decoration: BoxDecoration(
                        color: c.surface,
                        borderRadius: BorderRadius.circular(22))),
                const SizedBox(width: 10),
                Container(
                    width: 110,
                    height: 42,
                    decoration: BoxDecoration(
                        color: c.surface,
                        borderRadius: BorderRadius.circular(22))),
                const SizedBox(width: 10),
                Container(
                    width: 110,
                    height: 42,
                    decoration: BoxDecoration(
                        color: c.surface,
                        borderRadius: BorderRadius.circular(22))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Empty state ───────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final VoidCallback onRefresh;
  final VoidCallback onDeploy;
  const _EmptyState({required this.onRefresh, required this.onDeploy});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      color: c.bg,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 88,
                height: 88,
                child:
                    Image.asset('assets/logo.png', fit: BoxFit.contain),
              ),
              const SizedBox(height: 24),
              Text('dashboard.no_apps_title'.tr(),
                  style: GoogleFonts.inter(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: c.textBright)),
              const SizedBox(height: 10),
              Text('dashboard.no_apps_subtitle'.tr(),
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                      fontSize: 13,
                      color: c.textMuted,
                      height: 1.5)),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: c.codeBlockBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: c.border),
                ),
                child: SelectableText(
                  'digitorn deploy examples/chat.yaml',
                  style: GoogleFonts.firaCode(
                      fontSize: 12, color: c.text),
                ),
              ),
              const SizedBox(height: 28),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _FooterBtn(
                      icon: Icons.add_rounded,
                      label: 'dashboard.deploy'.tr(),
                      onTap: onDeploy),
                  const SizedBox(width: 20),
                  _FooterBtn(
                      icon: Icons.refresh_rounded,
                      label: 'dashboard.refresh'.tr(),
                      onTap: onRefresh),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
