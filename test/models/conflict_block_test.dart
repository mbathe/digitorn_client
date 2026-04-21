/// Guards the conflict-marker parser.
library;

import 'package:digitorn_client/models/conflict_block.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a classic 2-way conflict', () {
    const src = 'line one\n'
        '<<<<<<< HEAD\n'
        'ours line A\n'
        'ours line B\n'
        '=======\n'
        'theirs line A\n'
        '>>>>>>> feature-x\n'
        'line five\n';
    final parsed = parseConflicts(src);
    expect(parsed.hasConflicts, isTrue);
    expect(parsed.blocks, hasLength(1));
    final b = parsed.blocks.first;
    expect(b.oursLabel, 'HEAD');
    expect(b.theirsLabel, 'feature-x');
    expect(b.ours, ['ours line A', 'ours line B']);
    expect(b.theirs, ['theirs line A']);
    expect(b.base, isNull);
    // Line numbers are 0-based — start=1 (second line), end=6 (>>>>>>>)
    expect(b.startLine, 1);
    expect(b.endLine, 6);
  });

  test('parses a diff3 conflict with |||||||', () {
    const src = '<<<<<<< HEAD\n'
        'ours\n'
        '||||||| merged common ancestors\n'
        'base\n'
        '=======\n'
        'theirs\n'
        '>>>>>>> other\n';
    final parsed = parseConflicts(src);
    expect(parsed.blocks, hasLength(1));
    expect(parsed.blocks.first.baseLabel, 'merged common ancestors');
    expect(parsed.blocks.first.base, ['base']);
    expect(parsed.blocks.first.ours, ['ours']);
    expect(parsed.blocks.first.theirs, ['theirs']);
  });

  test('returns empty for clean files', () {
    final parsed = parseConflicts('nothing special here\njust plain\n');
    expect(parsed.hasConflicts, isFalse);
    expect(parsed.blocks, isEmpty);
  });

  test('ignores unterminated blocks instead of hanging', () {
    const src = '<<<<<<< HEAD\n'
        'open\n'
        '=======\n'
        'theirs but no closing marker\n';
    final parsed = parseConflicts(src);
    // Unterminated → bails; nothing reported (we'd rather render raw
    // than pretend a half-block is a real conflict).
    expect(parsed.blocks, isEmpty);
  });

  test('applyResolutions — ours choice drops markers + theirs', () {
    const src = '<<<<<<< HEAD\n'
        'OURS\n'
        '=======\n'
        'THEIRS\n'
        '>>>>>>> x\n';
    final parsed = parseConflicts(src);
    final merged =
        applyResolutions(parsed, {0: ConflictResolution.ours});
    expect(merged, equals('OURS\n'));
  });

  test('applyResolutions — theirs choice', () {
    const src = '<<<<<<< HEAD\n'
        'OURS\n'
        '=======\n'
        'THEIRS\n'
        '>>>>>>> x\n';
    final parsed = parseConflicts(src);
    final merged =
        applyResolutions(parsed, {0: ConflictResolution.theirs});
    expect(merged, equals('THEIRS\n'));
  });

  test('applyResolutions — both choice concatenates ours then theirs',
      () {
    const src = 'prefix\n'
        '<<<<<<< HEAD\n'
        'OURS\n'
        '=======\n'
        'THEIRS\n'
        '>>>>>>> x\n'
        'suffix\n';
    final parsed = parseConflicts(src);
    final merged =
        applyResolutions(parsed, {0: ConflictResolution.both});
    expect(merged, equals('prefix\nOURS\nTHEIRS\nsuffix\n'));
  });

  test('applyResolutions — multiple blocks resolved independently', () {
    const src = '<<<<<<< HEAD\n'
        'A1\n'
        '=======\n'
        'A2\n'
        '>>>>>>> x\n'
        'mid\n'
        '<<<<<<< HEAD\n'
        'B1\n'
        '=======\n'
        'B2\n'
        '>>>>>>> y\n';
    final parsed = parseConflicts(src);
    final merged = applyResolutions(parsed, {
      0: ConflictResolution.ours,
      1: ConflictResolution.theirs,
    });
    expect(merged, equals('A1\nmid\nB2\n'));
  });

  test('applyResolutions — unchosen block keeps its markers', () {
    const src = '<<<<<<< HEAD\n'
        'A1\n'
        '=======\n'
        'A2\n'
        '>>>>>>> x\n';
    final parsed = parseConflicts(src);
    final merged = applyResolutions(parsed, const {});
    // No choice → original markers stay (caller enforces all-or-nothing).
    expect(merged.contains('<<<<<<<'), isTrue);
    expect(merged.contains('>>>>>>>'), isTrue);
  });
}
