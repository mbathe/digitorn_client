import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../models/workspace_state.dart';
import '../../theme/app_theme.dart';

class WorkspaceSidebar extends StatelessWidget {
  const WorkspaceSidebar({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: WorkspaceState(),
      builder: (_, __) {
        final ws = WorkspaceState();
        if (!ws.hasContent) return const SizedBox.shrink();

        return Container(
          width: 220,
          decoration: BoxDecoration(
            color: context.colors.bg,
            border: Border(left: BorderSide(color: context.colors.border)),
          ),
          child: Column(
            children: [
              // Header
              Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: context.colors.border)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.dashboard_outlined, color: context.colors.textDim, size: 14),
                    const SizedBox(width: 8),
                    Text('Workspace',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: context.colors.textBright,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),

              // Content
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    if (ws.goal.isNotEmpty) ...[
                      _GoalSection(goal: ws.goal),
                      const SizedBox(height: 16),
                    ],
                    if (ws.todos.isNotEmpty) ...[
                      _TodoSection(
                        todos: ws.todosSorted,
                        done: ws.todoDone,
                        total: ws.todoTotal,
                        progress: ws.todoProgress,
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (ws.agents.isNotEmpty) ...[
                      _AgentSection(agents: ws.agents),
                      const SizedBox(height: 16),
                    ],
                    if (ws.facts.isNotEmpty)
                      _FactsSection(facts: ws.facts),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Goal ────────────────────────────────────────────────────────────────────

class _GoalSection extends StatelessWidget {
  final String goal;
  const _GoalSection({required this.goal});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(icon: '●', iconColor: context.colors.orange, label: 'Goal'),
        const SizedBox(height: 6),
        Text(
          goal,
          style: GoogleFonts.inter(
            fontSize: 12,
            color: context.colors.textBright,
            height: 1.5,
          ),
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

// ─── Todo list ───────────────────────────────────────────────────────────────

class _TodoSection extends StatelessWidget {
  final List<TodoItem> todos;
  final int done;
  final int total;
  final double progress;
  const _TodoSection({
    required this.todos,
    required this.done,
    required this.total,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(icon: '☰', iconColor: context.colors.text, label: 'Tasks'),
        const SizedBox(height: 8),

        // Progress bar
        _ProgressBar(progress: progress, label: '$done/$total (${(progress * 100).round()}%)'),
        const SizedBox(height: 8),

        // Todo items
        for (int i = 0; i < todos.length && i < 10; i++)
          _TodoRow(item: todos[i]),

        if (todos.length > 10)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '+${todos.length - 10} more',
              style: GoogleFonts.inter(fontSize: 11, color: context.colors.textDim),
            ),
          ),
      ],
    );
  }
}

class _ProgressBar extends StatelessWidget {
  final double progress;
  final String label;
  const _ProgressBar({required this.progress, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 6,
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: context.colors.border,
              valueColor: AlwaysStoppedAnimation(context.colors.green),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: GoogleFonts.firaCode(fontSize: 10, color: context.colors.textDim),
        ),
      ],
    );
  }
}

class _TodoRow extends StatelessWidget {
  final TodoItem item;
  const _TodoRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final (String icon, Color color, TextDecoration? deco) = switch (item.status) {
      TodoStatus.done       => ('✓', context.colors.textDim,  TextDecoration.lineThrough),
      TodoStatus.inProgress => ('▶', context.colors.orange,   null),
      TodoStatus.blocked    => ('■', context.colors.red,      null),
      TodoStatus.pending    => ('▫', context.colors.text,     null),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 16,
            child: Text(icon, style: TextStyle(fontSize: 11, color: color)),
          ),
          Expanded(
            child: Text(
              item.content,
              style: GoogleFonts.inter(
                fontSize: 11.5,
                color: item.status == TodoStatus.done ? context.colors.textDim : context.colors.text,
                height: 1.4,
                decoration: deco,
                decorationColor: context.colors.textDim,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Agents ──────────────────────────────────────────────────────────────────

class _AgentSection extends StatelessWidget {
  final List<SubAgent> agents;
  const _AgentSection({required this.agents});

  @override
  Widget build(BuildContext context) {
    final active = agents.where((a) =>
        a.status == AgentStatus.spawned || a.status == AgentStatus.running);
    final done = agents.where((a) =>
        a.status == AgentStatus.completed || a.status == AgentStatus.failed);

    final countLabel = active.isNotEmpty
        ? '${active.length} running'
        : '${done.length} done';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          icon: '●',
          iconColor: active.isNotEmpty ? context.colors.cyan : context.colors.green,
          label: 'Agents',
          badge: countLabel,
        ),
        const SizedBox(height: 6),
        // Active first, then done
        for (final a in [...active, ...done].take(8))
          _AgentRow(agent: a),
      ],
    );
  }
}

class _AgentRow extends StatelessWidget {
  final SubAgent agent;
  const _AgentRow({required this.agent});

  @override
  Widget build(BuildContext context) {
    final (String icon, Color color) = switch (agent.status) {
      AgentStatus.spawned   => ('◌', context.colors.orange),
      AgentStatus.running   => ('●', context.colors.cyan),
      AgentStatus.completed => ('✓', context.colors.green),
      AgentStatus.failed    => ('✗', context.colors.red),
      AgentStatus.cancelled => ('○', context.colors.textDim),
    };

    final name = agent.specialist.isNotEmpty
        ? agent.specialist
        : (agent.id.length > 8 ? agent.id.substring(0, 8) : agent.id);

    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          Text(icon, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold)),
          const SizedBox(width: 6),
          Text(
            name,
            style: GoogleFonts.inter(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          if (agent.task.isNotEmpty) ...[
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                agent.task,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(fontSize: 11, color: context.colors.textDim),
              ),
            ),
          ],
          if (agent.duration > 0) ...[
            const SizedBox(width: 4),
            Text(
              '${agent.duration.toStringAsFixed(1)}s',
              style: GoogleFonts.firaCode(fontSize: 10, color: context.colors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Facts ──���────────────────────────────────────────────────────────────────

class _FactsSection extends StatelessWidget {
  final List<String> facts;
  const _FactsSection({required this.facts});

  @override
  Widget build(BuildContext context) {
    final shown = facts.length > 6 ? facts.sublist(facts.length - 6) : facts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          icon: '•',
          iconColor: context.colors.text,
          label: 'Memory',
          badge: '(${facts.length})',
        ),
        const SizedBox(height: 6),
        for (final f in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('• ', style: TextStyle(fontSize: 11, color: context.colors.text)),
                Expanded(
                  child: Text(
                    f,
                    style: GoogleFonts.inter(fontSize: 11, color: context.colors.text, height: 1.4),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ─── Section header ──────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String icon;
  final Color iconColor;
  final String label;
  final String? badge;
  const _SectionHeader({
    required this.icon,
    required this.iconColor,
    required this.label,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(icon, style: TextStyle(fontSize: 11, color: iconColor)),
        const SizedBox(width: 6),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: context.colors.textDim,
            letterSpacing: 0.5,
          ),
        ),
        if (badge != null) ...[
          const SizedBox(width: 6),
          Text(
            badge!,
            style: GoogleFonts.firaCode(fontSize: 10, color: context.colors.textMuted),
          ),
        ],
      ],
    );
  }
}
