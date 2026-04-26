import 'package:digitorn_client/theme/app_theme.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/onboarding_service.dart';
import '../services/session_service.dart';
import '../services/theme_service.dart';
import '../main.dart';
import 'admin/admin_console_page.dart';
import 'chat/artifacts/artifact_service.dart';
import 'admin/quotas_admin_page.dart';
import 'approvals/approvals_page.dart';
import 'builder/builder_drafts_page.dart';
import 'hub/hub_page.dart';
import 'credentials/credentials_form.dart';
import 'credentials/my_credentials_page.dart';
import 'global_search.dart';
import 'keyboard_shortcuts_sheet.dart';
import 'sessions/recent_conversations_page.dart';
import 'settings/diagnostics_page.dart';

/// Command palette overlay (Ctrl+K)
class CommandPalette extends StatefulWidget {
  const CommandPalette({super.key});

  static void show(BuildContext context) {
    final appState = Provider.of<AppState>(context, listen: false);
    showDialog(
      context: context,
      barrierColor: Colors.black38,
      builder: (_) => ChangeNotifierProvider.value(
        value: appState,
        child: const CommandPalette(),
      ),
    );
  }

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  final _ctrl = TextEditingController();
  List<_Command> _filtered = [];

  late final List<_Command> _commands;

  List<_Command> _buildCommands(AppState appState) {
    final app = appState.activeApp;
    final appLabel = app?.name ?? '';
    // Conversation-flow commands only appear when there's an
    // active app AND the user is on the chat panel — they make
    // no sense from Settings, Hub, Admin Console or the dashboard.
    final inChat = app != null && appState.panel == ActivePanel.chat;
    return [
      // ── Conversation flow (chat-only) ────────────────────────────
      if (inChat) ...[
        _Command('New Session', 'Create a new conversation',
            Icons.add_rounded, () async {
          // Atomic-create contract — the daemon refuses to spawn
          // empty sessions. ``New Session`` just resets the chat
          // panel to its empty welcome state; the daemon row is
          // created when the user types their first message and
          // ``_send`` posts ``message + workspace`` together.
          SessionService().clearActiveSession();
        }),
        _Command('Clear Chat', 'Clear current messages',
            Icons.clear_all_rounded, () {
          // Handled by caller
        }),
        _Command('Export Chat', 'Copy conversation as Markdown',
            Icons.download_rounded, () {
          // Handled by caller
        }),
      ],

      // ── Credentials ──────────────────────────────────────────────
      if (app != null)
        _Command(
          'Open Credentials · $appLabel',
          'Configure API keys, OAuth, MCP for the current app',
          Icons.key_rounded,
          () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => CredentialsFormPage(
                appId: app.appId,
                appName: app.name,
              ),
            ),
          ),
        ),
      _Command(
        'My Credentials',
        'Cross-app credentials dashboard',
        Icons.vpn_key_outlined,
        () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const MyCredentialsPage()),
        ),
      ),
      _Command(
        'Hub',
        'Browse and install apps, modules and MCP servers',
        Icons.extension_rounded,
        () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const HubPage()),
        ),
      ),
      _Command(
        'Pending Approvals',
        'Cross-app queue of tool calls awaiting your decision',
        Icons.front_hand_outlined,
        () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ApprovalsPage()),
        ),
      ),
      _Command(
        'Recent Conversations',
        'Every session you touched across every app',
        Icons.history_rounded,
        () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const RecentConversationsPage()),
        ),
      ),
      _Command(
        'Builder Drafts',
        'In-progress app specs — resume, rename, delete',
        Icons.architecture_outlined,
        () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const BuilderDraftsPage()),
        ),
      ),
      // Artifacts are per-session (extracted from a specific chat
      // transcript). Hide outside the chat view — you can't open a
      // session artifact from the Hub or the Admin console.
      if (inChat && ArtifactService().hasAny)
        _Command(
          'Show artifacts panel',
          '${ArtifactService().artifacts.length} extracted from this session',
          Icons.auto_awesome_rounded,
          () => ArtifactService().openLatest(),
        ),
      _Command(
        'Replay account setup',
        'Re-run the post-register wizard (profile, providers, apps, tour)',
        Icons.refresh_rounded,
        () => OnboardingService().resetAccount(),
      ),
      _Command(
        'Replay full onboarding',
        'Re-run setup + account wizards from scratch',
        Icons.restart_alt_rounded,
        () => OnboardingService().reset(),
      ),
      if (AuthService().currentUser?.isAdmin == true) ...[
        _Command(
          'Admin console',
          'Workspace overview · users · quotas · system creds · MCP pool · audit',
          Icons.shield_rounded,
          () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AdminConsolePage()),
          ),
        ),
        _Command(
          'Manage Quotas',
          'Admin · jump straight to the quotas table',
          Icons.speed_rounded,
          () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const QuotasAdminPage()),
          ),
        ),
      ],

      // ── Panels / navigation (chat-scoped) ────────────────────────
      // Sessions / Tools / Workspace are sub-views of the chat shell
      // and make no sense outside of it. Previously gated only on
      // ``app != null`` which leaked them into Settings / Hub /
      // Admin views — confusing because the commands fired a panel
      // switch that threw the user back into chat without warning.
      if (inChat) ...[
        _Command('Sessions', 'Open session drawer', Icons.history_rounded,
            () => appState.setPanel(ActivePanel.sessions)),
        _Command('Tools', 'Browse available tools', Icons.build_outlined,
            () => appState.setPanel(ActivePanel.tools)),
      ],
      _Command('Settings', 'Open settings', Icons.settings_outlined,
          () => appState.setPanel(ActivePanel.settings)),
      _Command(
        'Diagnostics',
        'Probe services, check latency + errors',
        Icons.network_check_rounded,
        () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const DiagnosticsPage()),
        ),
      ),
      _Command(
        'Search everything',
        'Fuzzy search apps, sessions, settings (Ctrl+P)',
        Icons.search_rounded,
        () => GlobalSearch.show(context),
      ),
      _Command(
        'Quick switch',
        'Jump to an app or session (Ctrl+T)',
        Icons.swap_horiz_rounded,
        () => GlobalSearch.show(context, mode: SearchMode.quickSwitcher),
      ),
      _Command(
        'Keyboard shortcuts',
        'Show all keybindings (Ctrl+/)',
        Icons.keyboard_alt_outlined,
        () => KeyboardShortcutsSheet.show(context),
      ),
      // Workspace toggle is a chat-shell control — it flips the
      // side pane that shows the current session's files / preview /
      // terminal. Pointless outside the chat view.
      if (inChat)
        _Command('Workspace', 'Toggle workspace panel', Icons.code_rounded,
            () {
          if (appState.isWorkspaceVisible) {
            appState.closeWorkspace();
          } else {
            appState.showWorkspace();
          }
        }),
      _Command('Back to Apps', 'Return to app selector',
          Icons.apps_rounded, appState.goHome),

      // ── Preferences ──────────────────────────────────────────────
      _Command('Toggle Theme', 'Switch between light and dark',
          Icons.brightness_6_rounded, () => ThemeService().toggle()),
    ];
  }

  @override
  void initState() {
    super.initState();
    final appState = Provider.of<AppState>(context, listen: false);
    _commands = _buildCommands(appState);
    _filtered = _commands;
    _ctrl.addListener(_filter);
  }

  void _filter() {
    final q = _ctrl.text.toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? _commands
          : _commands.where((c) =>
              c.label.toLowerCase().contains(q) ||
              c.description.toLowerCase().contains(q)
            ).toList();
    });
  }

  void _execute(_Command cmd) {
    // Close the palette FIRST via the ROOT navigator (not a nested
    // one that might sit inside the dialog), then defer the action
    // one frame so the pop animation fully commits before any
    // follow-up navigation / modal fires.
    //
    // Previous code popped + ran the action synchronously. Many
    // commands call ``Navigator.of(context).push(...)`` using the
    // context captured at ``_buildCommands()`` time — a context
    // INSIDE the dialog route. Pushing on that context BEFORE the
    // pop finishes could target the dying dialog's local navigator
    // rather than the root one, which left the palette visible
    // behind the pushed page (the "ça reste affiché" symptom).
    Navigator.of(context, rootNavigator: true).pop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      cmd.action();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.only(top: 80, left: 40, right: 40),
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      child: Builder(builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        final w = size.width < 560 ? size.width - 32 : 520.0;
        final h = size.height < 440 ? size.height - 100 : 400.0;
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: w, maxHeight: h),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Search input
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                style: GoogleFonts.inter(fontSize: 14, color: c.text),
                decoration: InputDecoration(
                  hintText: 'command_palette.type_command'.tr(),
                  hintStyle: GoogleFonts.inter(fontSize: 14, color: c.textMuted),
                  prefixIcon: Icon(Icons.search_rounded, size: 18, color: c.textMuted),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
                onSubmitted: (_) {
                  if (_filtered.isNotEmpty) _execute(_filtered.first);
                },
              ),
            ),
            Divider(height: 1, color: c.border),
            // Results
            Flexible(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4),
                shrinkWrap: true,
                itemCount: _filtered.length,
                itemBuilder: (_, i) {
                  final cmd = _filtered[i];
                  return _CommandTile(
                    command: cmd,
                    onTap: () => _execute(cmd),
                  );
                },
              ),
            ),
            // Footer
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.border)),
              ),
              child: Row(
                children: [
                  _KeyHint(label: 'Enter'),
                  const SizedBox(width: 4),
                  Text('command_palette.to_select'.tr(), style: GoogleFonts.inter(fontSize: 10, color: c.textMuted)),
                  const SizedBox(width: 12),
                  _KeyHint(label: 'Esc'),
                  const SizedBox(width: 4),
                  Text('command_palette.to_close'.tr(), style: GoogleFonts.inter(fontSize: 10, color: c.textMuted)),
                ],
              ),
            ),
          ],
        ),
        );
      }),
    );
  }
}

class _Command {
  final String label;
  final String description;
  final IconData icon;
  final VoidCallback action;
  const _Command(this.label, this.description, this.icon, this.action);
}

class _CommandTile extends StatefulWidget {
  final _Command command;
  final VoidCallback onTap;
  const _CommandTile({
    required this.command, required this.onTap,
  });

  @override
  State<_CommandTile> createState() => _CommandTileState();
}

class _CommandTileState extends State<_CommandTile> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          color: _h ? c.surfaceAlt : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(widget.command.icon, size: 16, color: c.textMuted),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.command.label,
                      style: GoogleFonts.inter(fontSize: 13, color: c.text)),
                    Text(widget.command.description,
                      style: GoogleFonts.inter(fontSize: 11, color: c.textMuted)),
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

class _KeyHint extends StatelessWidget {
  final String label;
  const _KeyHint({required this.label});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: c.border),
      ),
      child: Text(label, style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted)),
    );
  }
}
