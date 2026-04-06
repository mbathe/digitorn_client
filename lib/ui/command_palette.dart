import 'package:digitorn_client/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/session_service.dart';
import '../services/theme_service.dart';
import '../main.dart';

/// Command palette overlay (Ctrl+K)
class CommandPalette extends StatefulWidget {
  const CommandPalette({super.key});

  static void show(BuildContext context) {
    showDialog(
      context: context,
      barrierColor: Colors.black38,
      builder: (_) => const CommandPalette(),
    );
  }

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  final _ctrl = TextEditingController();
  List<_Command> _filtered = [];

  late final List<_Command> _commands = [
    _Command('New Session', 'Create a new conversation', Icons.add_rounded, () {
      final app = AppState().activeApp;
      if (app != null) SessionService().createAndSetSession(app.appId);
    }),
    _Command('Clear Chat', 'Clear current messages', Icons.clear_all_rounded, () {
      // Will be handled by caller
    }),
    _Command('Toggle Theme', 'Switch between light and dark', Icons.brightness_6_rounded, () {
      ThemeService().toggle();
    }),
    _Command('Sessions', 'Open session drawer', Icons.history_rounded, () {
      AppState().setPanel(ActivePanel.sessions);
    }),
    _Command('Tools', 'Browse available tools', Icons.build_outlined, () {
      AppState().setPanel(ActivePanel.tools);
    }),
    _Command('Settings', 'Open settings', Icons.settings_outlined, () {
      AppState().setPanel(ActivePanel.settings);
    }),
    _Command('Workspace', 'Toggle workspace panel', Icons.code_rounded, () {
      final s = AppState();
      if (s.isWorkspaceVisible) { s.closeWorkspace(); } else { s.showWorkspace(); }
    }),
    _Command('Export Chat', 'Copy conversation as Markdown', Icons.download_rounded, () {
      // Will be handled by caller
    }),
    _Command('Back to Apps', 'Return to app selector', Icons.apps_rounded, () {
      AppState().clearApp();
    }),
  ];

  @override
  void initState() {
    super.initState();
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
    Navigator.pop(context);
    cmd.action();
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
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 400),
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
                  hintText: 'Type a command...',
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
                  Text('to select', style: GoogleFonts.inter(fontSize: 10, color: c.textMuted)),
                  const SizedBox(width: 12),
                  _KeyHint(label: 'Esc'),
                  const SizedBox(width: 4),
                  Text('to close', style: GoogleFonts.inter(fontSize: 10, color: c.textMuted)),
                ],
              ),
            ),
          ],
        ),
      ),
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
