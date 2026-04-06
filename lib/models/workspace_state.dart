import 'package:flutter/foundation.dart';

// ─── Todo item ───────────────────────────────────────────────────────────────

enum TodoStatus { pending, inProgress, done, blocked }

class TodoItem {
  final String content;
  final TodoStatus status;

  const TodoItem({required this.content, required this.status});

  factory TodoItem.fromJson(Map<String, dynamic> json) {
    final s = (json['status'] as String? ?? 'pending').toLowerCase();
    return TodoItem(
      content: json['content'] as String? ?? '',
      status: switch (s) {
        'in_progress' => TodoStatus.inProgress,
        'done'        => TodoStatus.done,
        'blocked'     => TodoStatus.blocked,
        _             => TodoStatus.pending,
      },
    );
  }
}

// ─── Sub-agent ───────────────────────────────────────────────────────────────

enum AgentStatus { spawned, running, completed, failed, cancelled }

class SubAgent {
  final String id;
  final String specialist;
  final String task;
  final AgentStatus status;
  final double duration;
  final String preview;
  final DateTime updatedAt;

  const SubAgent({
    required this.id,
    required this.specialist,
    required this.task,
    required this.status,
    this.duration = 0,
    this.preview = '',
    required this.updatedAt,
  });
}

// ─── Workspace state (sidebar data) ──────────────────────────────────────────

class WorkspaceState extends ChangeNotifier {
  static final WorkspaceState _i = WorkspaceState._();
  factory WorkspaceState() => _i;
  WorkspaceState._();

  String _goal = '';
  String get goal => _goal;

  List<TodoItem> _todos = [];
  List<TodoItem> get todos => _todos;

  List<String> _facts = [];
  List<String> get facts => _facts;

  final Map<String, SubAgent> _agents = {};
  List<SubAgent> get agents => _agents.values.toList();

  // ── Computed ─────────────────────────────────────────────────────────────

  int get todoDone => _todos.where((t) => t.status == TodoStatus.done).length;
  int get todoTotal => _todos.length;
  double get todoProgress => todoTotal > 0 ? todoDone / todoTotal : 0;

  List<TodoItem> get todosSorted {
    final order = {
      TodoStatus.inProgress: 0,
      TodoStatus.blocked: 1,
      TodoStatus.pending: 2,
      TodoStatus.done: 3,
    };
    return List.of(_todos)..sort((a, b) => order[a.status]!.compareTo(order[b.status]!));
  }

  int get activeAgentCount =>
      _agents.values.where((a) =>
          a.status == AgentStatus.spawned || a.status == AgentStatus.running
      ).length;

  /// Only show sidebar when there's meaningful live content
  bool get hasContent =>
      _goal.isNotEmpty || _todos.isNotEmpty || _agents.isNotEmpty;

  // ── Mutations ────────────────────────────────────────────────────────────

  void handleMemoryUpdate(String action, Map<String, dynamic> data) {
    // Normalize action name
    final a = _normalizeAction(action);

    switch (a) {
      case 'set_goal':
        _goal = data['goal'] as String? ?? '';
        _facts.clear();
        notifyListeners();
        break;

      case 'add_todo':
      case 'update_todo':
        // Result contains full todo list
        if (data.containsKey('todos')) {
          final list = data['todos'] as List<dynamic>? ?? [];
          _todos = list
              .whereType<Map<String, dynamic>>()
              .map((j) => TodoItem.fromJson(j))
              .toList();
        }
        // May also contain updated goal
        if (data.containsKey('goal')) {
          final g = data['goal'] as String? ?? '';
          if (g.isNotEmpty) _goal = g;
        }
        notifyListeners();
        break;

      case 'remember':
        final content = data['content'] as String? ?? '';
        if (content.isNotEmpty) {
          _facts.add(content);
          if (_facts.length > 10) _facts.removeAt(0);
        }
        notifyListeners();
        break;

      case 'forget':
        final id = data['forgotten'] as String? ?? data['fact_id'] as String? ?? '';
        if (id.isNotEmpty) {
          _facts.removeWhere((f) => f.contains(id));
        }
        notifyListeners();
        break;

      case 'recall':
        // No sidebar update needed for recall
        break;
    }
  }

  void updateAgent(SubAgent agent) {
    _agents[agent.id] = agent;
    notifyListeners();
  }

  /// Called at the start of a new agent turn — clean up finished agents
  void onTurnStart() {
    // Remove completed/failed/cancelled agents from previous turn
    _agents.removeWhere((_, a) =>
        a.status == AgentStatus.completed ||
        a.status == AgentStatus.failed ||
        a.status == AgentStatus.cancelled);
    if (_agents.isNotEmpty) notifyListeners();
  }

  /// Called when switching apps — full reset
  void clear() {
    _goal = '';
    _todos = [];
    _facts = [];
    _agents.clear();
    notifyListeners();
  }

  /// Called when switching sessions — full reset (goal, todos, agents)
  void onNewSession() {
    _goal = '';
    _todos = [];
    _facts = [];
    _agents.clear();
    notifyListeners();
  }

  // ── Silent tool detection ─────────────────────────────────────────��──────

  static bool isSilentTool(String name) {
    final action = name.split(RegExp(r'[.__]')).last.toLowerCase();
    return _silentActions.contains(action) ||
        name.contains('memory') ||
        name.contains('agent_spawn') ||
        name.contains('spawn_agent') ||
        name.contains('agent_wait') ||
        name.contains('search_tools') ||
        name.contains('list_categories') ||
        name.contains('browse_category');
  }

  static bool isMemoryTool(String name) {
    final action = name.split(RegExp(r'[.__]')).last.toLowerCase();
    return _memoryActions.contains(action) || name.contains('memory');
  }

  static String _normalizeAction(String action) {
    return _shortToAction[action] ?? action.toLowerCase();
  }

  static const _shortToAction = {
    'SetGoal': 'set_goal',
    'Remember': 'remember',
    'Recall': 'recall',
    'Forget': 'forget',
    'TodoAdd': 'add_todo',
    'TodoUpdate': 'update_todo',
  };

  static const _memoryActions = {
    'set_goal', 'remember', 'recall', 'forget',
    'add_todo', 'update_todo',
    'setgoal', 'todoadd', 'todoupdate',
  };

  static const _silentActions = {
    'set_goal', 'remember', 'recall', 'forget',
    'add_todo', 'update_todo',
    'setgoal', 'todoadd', 'todoupdate',
    'spawn_agent', 'agent_wait', 'agent_wait_all',
    'agent_result', 'agent_status', 'agent_cancel', 'agent_list',
    'search_tools', 'get_tool', 'list_categories', 'browse_category',
  };
}
