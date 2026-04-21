import 'package:flutter_test/flutter_test.dart';
import 'package:digitorn_client/models/chat_message.dart';

void main() {
  group('ChatMessage', () {
    test('creates with initial text', () {
      final msg = ChatMessage(id: '1', role: MessageRole.user, initialText: 'hello');
      expect(msg.text, 'hello');
      expect(msg.role, MessageRole.user);
      expect(msg.isStreaming, false);
      expect(msg.toolCalls, isEmpty);
    });

    test('appends text to last text block', () {
      final msg = ChatMessage(id: '1', role: MessageRole.assistant);
      msg.appendText('Hello');
      msg.appendText(' world');
      expect(msg.text, 'Hello world');
      expect(msg.timeline.length, 1); // single text block
    });

    test('creates new text block after tool call', () {
      final msg = ChatMessage(id: '1', role: MessageRole.assistant);
      msg.appendText('Before tool');
      msg.addOrUpdateToolCall(ToolCall(
        id: 'tc1', name: 'read', params: {'path': 'test.py'},
        status: 'completed', result: {'content': 'code'},
      ));
      msg.appendText('After tool');
      expect(msg.timeline.length, 3); // text + tool + text
      // Text blocks separated by a non-text block (tool call) keep their
      // paragraph separation when flattened — otherwise copy/paste glues
      // sentences together (e.g. "Before toolAfter tool").
      expect(msg.text, 'Before tool\n\nAfter tool');
    });

    test('thinking text is separate from main text', () {
      final msg = ChatMessage(id: '1', role: MessageRole.assistant);
      msg.setThinkingState(true);
      msg.appendThinking('Let me think...');
      msg.setThinkingState(false);
      msg.appendText('Here is my answer');
      expect(msg.thinkingText, 'Let me think...');
      expect(msg.text, 'Here is my answer');
      expect(msg.isThinking, false);
    });

    test('tool calls match by id', () {
      final msg = ChatMessage(id: '1', role: MessageRole.assistant);
      msg.addOrUpdateToolCall(ToolCall(
        id: 'tc1', name: 'read', params: {}, status: 'started',
      ));
      expect(msg.toolCalls.length, 1);
      expect(msg.toolCalls.first.status, 'started');

      msg.addOrUpdateToolCall(ToolCall(
        id: 'tc1', name: 'read', params: {}, status: 'completed',
        result: {'lines': 10},
      ));
      expect(msg.toolCalls.length, 1); // updated in place
      expect(msg.toolCalls.first.status, 'completed');
    });

    test('multiple tool calls with different ids', () {
      final msg = ChatMessage(id: '1', role: MessageRole.assistant);
      msg.addOrUpdateToolCall(ToolCall(id: 'a', name: 'read', params: {}, status: 'completed'));
      msg.addOrUpdateToolCall(ToolCall(id: 'b', name: 'write', params: {}, status: 'completed'));
      expect(msg.toolCalls.length, 2);
    });

    test('agent events replace by agentId', () {
      final msg = ChatMessage(id: '1', role: MessageRole.assistant);
      msg.addAgentEvent(AgentEventData(agentId: 'a1', status: 'spawned'));
      msg.addAgentEvent(AgentEventData(agentId: 'a1', status: 'completed', duration: 2.5));
      expect(msg.agentEvents.length, 1);
      expect(msg.agentEvents.first.status, 'completed');
    });

    test('token counts accumulate', () {
      final msg = ChatMessage(id: '1', role: MessageRole.assistant);
      msg.addTokens(out: 10);
      msg.addTokens(out: 5);
      msg.addTokens(inT: 100);
      expect(msg.outTokens, 15);
      expect(msg.inTokens, 100);
    });

    test('streaming state notifies listeners', () {
      final msg = ChatMessage(id: '1', role: MessageRole.assistant);
      int notifyCount = 0;
      msg.addListener(() => notifyCount++);

      msg.setStreamingState(true);
      expect(msg.isStreaming, true);
      expect(notifyCount, 1);

      msg.setStreamingState(false);
      expect(msg.isStreaming, false);
      expect(notifyCount, 2);
    });

    test('ToolCall displayLabel uses label field', () {
      final tc = ToolCall(id: '1', name: 'filesystem__read', label: 'Read', params: {});
      expect(tc.displayLabel, 'Read');
    });

    test('ToolCall displayLabel falls back to parsed name', () {
      final tc = ToolCall(id: '1', name: 'filesystem__read', params: {});
      expect(tc.displayLabel, 'Read');
    });

    test('ToolCall displayDetail uses detail field', () {
      final tc = ToolCall(id: '1', name: 'read', detail: 'src/main.py', params: {});
      expect(tc.displayDetail, 'src/main.py');
    });

    test('ToolCall displayDetail falls back to params', () {
      final tc = ToolCall(id: '1', name: 'read', params: {'path': '/tmp/test.py'});
      expect(tc.displayDetail, '/tmp/test.py');
    });

    test('createdAt is set on construction', () {
      final before = DateTime.now();
      final msg = ChatMessage(id: '1', role: MessageRole.user);
      final after = DateTime.now();
      expect(msg.createdAt.isAfter(before.subtract(const Duration(seconds: 1))), true);
      expect(msg.createdAt.isBefore(after.add(const Duration(seconds: 1))), true);
    });
  });
}
