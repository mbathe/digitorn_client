import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_theme.dart';
import '../../models/app_summary.dart';

/// Slash command definition
class SlashCommand {
  final String command;
  final String labelKey;
  final String descriptionKey;
  final IconData icon;
  final Set<String> requiredModules; // empty = always available

  const SlashCommand({
    required this.command,
    required this.labelKey,
    required this.descriptionKey,
    required this.icon,
    this.requiredModules = const {},
  });

  String get label => labelKey.tr();
  String get description => descriptionKey.tr();
}

/// All available slash commands
const _allCommands = [
  // Universal (no module required)
  SlashCommand(command: '/explain', labelKey: 'chat_slash.explain_label', descriptionKey: 'chat_slash.explain_desc', icon: Icons.lightbulb_outline, requiredModules: {}),
  SlashCommand(command: '/summarize', labelKey: 'chat_slash.summarize_label', descriptionKey: 'chat_slash.summarize_desc', icon: Icons.summarize_outlined, requiredModules: {}),
  SlashCommand(command: '/continue', labelKey: 'chat_slash.continue_label', descriptionKey: 'chat_slash.continue_desc', icon: Icons.arrow_forward_rounded, requiredModules: {}),
  SlashCommand(command: '/plan', labelKey: 'chat_slash.plan_label', descriptionKey: 'chat_slash.plan_desc', icon: Icons.map_outlined, requiredModules: {}),
  SlashCommand(command: '/review', labelKey: 'chat_slash.review_label', descriptionKey: 'chat_slash.review_desc', icon: Icons.rate_review_outlined, requiredModules: {}),

  // Filesystem module
  SlashCommand(command: '/read', labelKey: 'chat_slash.read_label', descriptionKey: 'chat_slash.read_desc', icon: Icons.visibility_outlined, requiredModules: {'filesystem'}),
  SlashCommand(command: '/edit', labelKey: 'chat_slash.edit_label', descriptionKey: 'chat_slash.edit_desc', icon: Icons.edit_outlined, requiredModules: {'filesystem'}),
  SlashCommand(command: '/find', labelKey: 'chat_slash.find_label', descriptionKey: 'chat_slash.find_desc', icon: Icons.search_rounded, requiredModules: {'filesystem'}),

  // Shell module
  SlashCommand(command: '/run', labelKey: 'chat_slash.run_label', descriptionKey: 'chat_slash.run_desc', icon: Icons.terminal_rounded, requiredModules: {'shell'}),
  SlashCommand(command: '/test', labelKey: 'chat_slash.test_label', descriptionKey: 'chat_slash.test_desc', icon: Icons.science_outlined, requiredModules: {'shell'}),
  SlashCommand(command: '/install', labelKey: 'chat_slash.install_label', descriptionKey: 'chat_slash.install_desc', icon: Icons.download_rounded, requiredModules: {'shell'}),

  // Git module
  SlashCommand(command: '/commit', labelKey: 'chat_slash.commit_label', descriptionKey: 'chat_slash.commit_desc', icon: Icons.check_circle_outline, requiredModules: {'git'}),
  SlashCommand(command: '/diff', labelKey: 'chat_slash.diff_label', descriptionKey: 'chat_slash.diff_desc', icon: Icons.compare_arrows_rounded, requiredModules: {'git'}),
  SlashCommand(command: '/pr', labelKey: 'chat_slash.pr_label', descriptionKey: 'chat_slash.pr_desc', icon: Icons.call_merge_rounded, requiredModules: {'git'}),

  // Web module
  SlashCommand(command: '/search', labelKey: 'chat_slash.search_label', descriptionKey: 'chat_slash.search_desc', icon: Icons.language_rounded, requiredModules: {'web', 'http'}),
  SlashCommand(command: '/fetch', labelKey: 'chat_slash.fetch_label', descriptionKey: 'chat_slash.fetch_desc', icon: Icons.cloud_download_outlined, requiredModules: {'web', 'http'}),

  // Memory module
  SlashCommand(command: '/goal', labelKey: 'chat_slash.goal_label', descriptionKey: 'chat_slash.goal_desc', icon: Icons.flag_rounded, requiredModules: {'memory'}),
  SlashCommand(command: '/todo', labelKey: 'chat_slash.todo_label', descriptionKey: 'chat_slash.todo_desc', icon: Icons.checklist_rounded, requiredModules: {'memory'}),

  // Database module
  SlashCommand(command: '/query', labelKey: 'chat_slash.query_label', descriptionKey: 'chat_slash.query_desc', icon: Icons.storage_rounded, requiredModules: {'database'}),
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
              Flexible(
                child: Text(cmd.command,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.firaCode(
                    fontSize: 13, fontWeight: FontWeight.w500, color: c.text)),
              ),
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
