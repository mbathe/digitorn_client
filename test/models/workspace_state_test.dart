import 'package:flutter_test/flutter_test.dart';
import 'package:digitorn_client/models/workspace_state.dart';

void main() {
  late WorkspaceState ws;

  setUp(() {
    ws = WorkspaceState();
    ws.clear();
  });

  group('WorkspaceState', () {
    group('goal', () {
      test('set_goal replaces previous goal', () {
        ws.handleMemoryUpdate('set_goal', {'goal': 'First goal'});
        expect(ws.goal, 'First goal');

        ws.handleMemoryUpdate('set_goal', {'goal': 'Second goal'});
        expect(ws.goal, 'Second goal');
      });

      test('set_goal clears facts', () {
        ws.handleMemoryUpdate('remember', {'content': 'fact1'});
        expect(ws.facts.length, 1);

        ws.handleMemoryUpdate('set_goal', {'goal': 'New goal'});
        expect(ws.facts, isEmpty);
      });

      test('SetGoal (PascalCase) normalized', () {
        ws.handleMemoryUpdate('SetGoal', {'goal': 'PascalCase goal'});
        expect(ws.goal, 'PascalCase goal');
      });
    });

    group('todos', () {
      test('add_todo replaces entire list', () {
        ws.handleMemoryUpdate('add_todo', {
          'todos': [
            {'content': 'Task 1', 'status': 'pending'},
            {'content': 'Task 2', 'status': 'in_progress'},
          ],
        });
        expect(ws.todos.length, 2);
        expect(ws.todoTotal, 2);
        expect(ws.todoDone, 0);
      });

      test('update_todo replaces list and updates goal', () {
        ws.handleMemoryUpdate('update_todo', {
          'goal': 'Updated goal',
          'todos': [
            {'content': 'Task 1', 'status': 'done'},
            {'content': 'Task 2', 'status': 'pending'},
          ],
        });
        expect(ws.goal, 'Updated goal');
        expect(ws.todoDone, 1);
        expect(ws.todoProgress, 0.5);
      });

      test('todosSorted orders by status', () {
        ws.handleMemoryUpdate('add_todo', {
          'todos': [
            {'content': 'Done', 'status': 'done'},
            {'content': 'Blocked', 'status': 'blocked'},
            {'content': 'Pending', 'status': 'pending'},
            {'content': 'Active', 'status': 'in_progress'},
          ],
        });
        final sorted = ws.todosSorted;
        expect(sorted[0].status, TodoStatus.inProgress);
        expect(sorted[1].status, TodoStatus.blocked);
        expect(sorted[2].status, TodoStatus.pending);
        expect(sorted[3].status, TodoStatus.done);
      });
    });

    group('agents', () {
      test('updateAgent adds and updates', () {
        ws.updateAgent(SubAgent(
          id: 'a1', specialist: 'Researcher', task: 'Find docs',
          status: AgentStatus.spawned, updatedAt: DateTime.now(),
        ));
        expect(ws.agents.length, 1);
        expect(ws.activeAgentCount, 1);

        ws.updateAgent(SubAgent(
          id: 'a1', specialist: 'Researcher', task: 'Find docs',
          status: AgentStatus.completed, duration: 3.0, updatedAt: DateTime.now(),
        ));
        expect(ws.agents.length, 1);
        expect(ws.agents.first.status, AgentStatus.completed);
        expect(ws.activeAgentCount, 0);
      });

      test('onTurnStart cleans finished agents', () {
        ws.updateAgent(SubAgent(
          id: 'a1', specialist: 'Done', task: '',
          status: AgentStatus.completed, updatedAt: DateTime.now(),
        ));
        ws.updateAgent(SubAgent(
          id: 'a2', specialist: 'Active', task: '',
          status: AgentStatus.running, updatedAt: DateTime.now(),
        ));
        expect(ws.agents.length, 2);

        ws.onTurnStart();
        expect(ws.agents.length, 1);
        expect(ws.agents.first.id, 'a2');
      });

      test('onNewSession clears everything (session isolation)', () {
        ws.handleMemoryUpdate('set_goal', {'goal': 'Old goal'});
        ws.updateAgent(SubAgent(
          id: 'a1', specialist: 'Agent', task: '',
          status: AgentStatus.running, updatedAt: DateTime.now(),
        ));

        ws.onNewSession();
        expect(ws.agents, isEmpty);
        expect(ws.goal, isEmpty); // cleared for session isolation
        expect(ws.todos, isEmpty);
        expect(ws.facts, isEmpty);
      });
    });

    group('facts', () {
      test('remember appends, max 10', () {
        for (int i = 0; i < 12; i++) {
          ws.handleMemoryUpdate('remember', {'content': 'fact $i'});
        }
        expect(ws.facts.length, 10);
        expect(ws.facts.first, 'fact 2'); // oldest pruned
        expect(ws.facts.last, 'fact 11');
      });

      test('forget removes by content', () {
        ws.handleMemoryUpdate('remember', {'content': 'important fact'});
        ws.handleMemoryUpdate('forget', {'forgotten': 'important'});
        expect(ws.facts, isEmpty);
      });
    });

    group('hasContent', () {
      test('false when empty', () {
        expect(ws.hasContent, false);
      });

      test('true with goal', () {
        ws.handleMemoryUpdate('set_goal', {'goal': 'test'});
        expect(ws.hasContent, true);
      });

      test('true with todos', () {
        ws.handleMemoryUpdate('add_todo', {
          'todos': [{'content': 'task', 'status': 'pending'}],
        });
        expect(ws.hasContent, true);
      });

      test('true with agents', () {
        ws.updateAgent(SubAgent(
          id: 'a', specialist: '', task: '',
          status: AgentStatus.running, updatedAt: DateTime.now(),
        ));
        expect(ws.hasContent, true);
      });
    });

    group('silent tool detection', () {
      test('isSilentTool detects memory tools', () {
        expect(WorkspaceState.isSilentTool('memory.set_goal'), true);
        expect(WorkspaceState.isSilentTool('SetGoal'), true);
        expect(WorkspaceState.isSilentTool('TodoAdd'), true);
        expect(WorkspaceState.isSilentTool('memory__remember'), true);
        expect(WorkspaceState.isSilentTool('agent_spawn.spawn_agent'), true);
        expect(WorkspaceState.isSilentTool('search_tools'), true);
      });

      test('isSilentTool passes visible tools', () {
        expect(WorkspaceState.isSilentTool('filesystem.read'), false);
        expect(WorkspaceState.isSilentTool('shell.bash'), false);
        expect(WorkspaceState.isSilentTool('git.status'), false);
      });

      test('isMemoryTool detects memory tools', () {
        expect(WorkspaceState.isMemoryTool('memory.set_goal'), true);
        expect(WorkspaceState.isMemoryTool('SetGoal'), true);
        expect(WorkspaceState.isMemoryTool('filesystem.read'), false);
      });
    });

    group('clear', () {
      test('resets everything', () {
        ws.handleMemoryUpdate('set_goal', {'goal': 'test'});
        ws.handleMemoryUpdate('remember', {'content': 'fact'});
        ws.updateAgent(SubAgent(
          id: 'a', specialist: '', task: '',
          status: AgentStatus.running, updatedAt: DateTime.now(),
        ));

        ws.clear();
        expect(ws.goal, '');
        expect(ws.todos, isEmpty);
        expect(ws.facts, isEmpty);
        expect(ws.agents, isEmpty);
        expect(ws.hasContent, false);
      });
    });
  });
}
