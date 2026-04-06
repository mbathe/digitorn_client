import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_theme.dart';
import '../../models/app_summary.dart';

/// Slash command definition
class SlashCommand {
  final String command;
  final String label;
  final String description;
  final IconData icon;
  final Set<String> requiredModules; // empty = always available

  const SlashCommand({
    required this.command,
    required this.label,
    required this.description,
    required this.icon,
    this.requiredModules = const {},
  });
}

/// All available slash commands
const _allCommands = [
  // Universal (no module required)
  SlashCommand(command: '/explain', label: 'Explain', description: 'Explain the code or concept', icon: Icons.lightbulb_outline, requiredModules: {}),
  SlashCommand(command: '/summarize', label: 'Summarize', description: 'Summarize what was done', icon: Icons.summarize_outlined, requiredModules: {}),
  SlashCommand(command: '/continue', label: 'Continue', description: 'Continue the current task', icon: Icons.arrow_forward_rounded, requiredModules: {}),
  SlashCommand(command: '/plan', label: 'Plan', description: 'Create a plan before acting', icon: Icons.map_outlined, requiredModules: {}),
  SlashCommand(command: '/review', label: 'Review', description: 'Review the recent changes', icon: Icons.rate_review_outlined, requiredModules: {}),

  // Filesystem module
  SlashCommand(command: '/read', label: 'Read', description: 'Read a file', icon: Icons.visibility_outlined, requiredModules: {'filesystem'}),
  SlashCommand(command: '/edit', label: 'Edit', description: 'Edit a file', icon: Icons.edit_outlined, requiredModules: {'filesystem'}),
  SlashCommand(command: '/find', label: 'Find', description: 'Search for files', icon: Icons.search_rounded, requiredModules: {'filesystem'}),

  // Shell module
  SlashCommand(command: '/run', label: 'Run', description: 'Run a shell command', icon: Icons.terminal_rounded, requiredModules: {'shell'}),
  SlashCommand(command: '/test', label: 'Test', description: 'Run the test suite', icon: Icons.science_outlined, requiredModules: {'shell'}),
  SlashCommand(command: '/install', label: 'Install', description: 'Install dependencies', icon: Icons.download_rounded, requiredModules: {'shell'}),

  // Git module
  SlashCommand(command: '/commit', label: 'Commit', description: 'Create a git commit', icon: Icons.check_circle_outline, requiredModules: {'git'}),
  SlashCommand(command: '/diff', label: 'Diff', description: 'Show git diff', icon: Icons.compare_arrows_rounded, requiredModules: {'git'}),
  SlashCommand(command: '/pr', label: 'PR', description: 'Create a pull request', icon: Icons.call_merge_rounded, requiredModules: {'git'}),

  // Web module
  SlashCommand(command: '/search', label: 'Search', description: 'Search the web', icon: Icons.language_rounded, requiredModules: {'web', 'http'}),
  SlashCommand(command: '/fetch', label: 'Fetch', description: 'Fetch a URL', icon: Icons.cloud_download_outlined, requiredModules: {'web', 'http'}),

  // Memory module
  SlashCommand(command: '/goal', label: 'Goal', description: 'Set a project goal', icon: Icons.flag_rounded, requiredModules: {'memory'}),
  SlashCommand(command: '/todo', label: 'Todo', description: 'Add a task to the list', icon: Icons.checklist_rounded, requiredModules: {'memory'}),

  // Database module
  SlashCommand(command: '/query', label: 'Query', description: 'Run a database query', icon: Icons.storage_rounded, requiredModules: {'database'}),
];

/// Filter commands based on app modules
List<SlashCommand> getAvailableCommands(AppSummary? app, String query) {
  final appModules = app?.modules.toSet() ?? <String>{};

  return _allCommands.where((cmd) {
    // Check if required modules are available
    if (cmd.requiredModules.isNotEmpty &&
        !cmd.requiredModules.any((m) => appModules.contains(m))) {
      return false;
    }
    // Filter by query
    if (query.isNotEmpty) {
      final q = query.toLowerCase();
      return cmd.command.contains(q) ||
          cmd.label.toLowerCase().contains(q) ||
          cmd.description.toLowerCase().contains(q);
    }
    return true;
  }).toList();
}

/// Slash command popup overlay
class SlashCommandMenu extends StatelessWidget {
  final List<SlashCommand> commands;
  final void Function(SlashCommand) onSelect;

  const SlashCommandMenu({
    super.key,
    required this.commands,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (commands.isEmpty) return const SizedBox.shrink();

    return Container(
      constraints: const BoxConstraints(maxHeight: 280),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        shrinkWrap: true,
        itemCount: commands.length,
        itemBuilder: (_, i) => _CommandRow(
          command: commands[i],
          onTap: () => onSelect(commands[i]),
        ),
      ),
    );
  }
}

class _CommandRow extends StatefulWidget {
  final SlashCommand command;
  final VoidCallback onTap;
  const _CommandRow({required this.command, required this.onTap});

  @override
  State<_CommandRow> createState() => _CommandRowState();
}

class _CommandRowState extends State<_CommandRow> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cmd = widget.command;
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: _h ? c.surfaceAlt : Colors.transparent,
          child: Row(
            children: [
              Icon(cmd.icon, size: 16, color: c.blue),
              const SizedBox(width: 10),
              Text(cmd.command,
                style: GoogleFonts.firaCode(
                  fontSize: 13, fontWeight: FontWeight.w500, color: c.text)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(cmd.description,
                  style: GoogleFonts.inter(fontSize: 12, color: c.textMuted),
                  overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
