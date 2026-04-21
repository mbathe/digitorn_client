/// Guards the daemon ↔ client hunk-hash contract.
///
/// The Dart hash formula MUST match the daemon's `_finalize_hunk`.
/// If this test ever fails, per-hunk approve/reject will silently
/// stop working ("no hunks matched selection" 400 from the daemon).
///
/// Reference hash captured by `scout/scout_workspace_validation.py`
/// against the live daemon (`ws-validate-manual` app, hello.txt
/// with "LINE ONE\nline two\nline three\nline four added\n" vs
/// the 3-line baseline).
library;

import 'package:digitorn_client/models/unified_diff_hunk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parseUnifiedDiffHunks produces the daemon-compatible hash', () {
    const diff = '--- a/hello.txt\n'
        '+++ b/hello.txt\n'
        '@@ -1,3 +1,4 @@\n'
        '-line one\n'
        '+LINE ONE\n'
        ' line two\n'
        ' line three\n'
        '+line four added\n';
    final hunks = parseUnifiedDiffHunks(diff);
    expect(hunks, hasLength(1));
    expect(hunks.first.hash, '2ec6cce5cc4e',
        reason: 'Daemon-produced hash from '
            'scout_workspace_validation.py — client formula must match '
            'or per-hunk approve/reject returns 400 "no hunks matched".');
    expect(hunks.first.oldStart, 1);
    expect(hunks.first.oldLen, 3);
    expect(hunks.first.newStart, 1);
    expect(hunks.first.newLen, 4);
    expect(hunks.first.insertions, 2);
    expect(hunks.first.deletions, 1);
  });

  test('body filter drops file-marker lines and empty tail', () {
    const diff = '--- a/x\n'
        '+++ b/x\n'
        '@@ -1,1 +1,1 @@\n'
        '-old\n'
        '+new\n'
        '';
    final hunks = parseUnifiedDiffHunks(diff);
    expect(hunks, hasLength(1));
    expect(hunks.first.body, ['-old', '+new'],
        reason: 'Must filter out the `---/+++` file markers and the '
            'trailing empty string produced by diff.split("\\n").');
  });

  test('multiple hunks each get independent, deterministic hashes', () {
    const diff = '@@ -1,1 +1,1 @@\n'
        '-a\n'
        '+A\n'
        '@@ -5,1 +5,1 @@\n'
        '-b\n'
        '+B\n';
    final hunks = parseUnifiedDiffHunks(diff);
    expect(hunks, hasLength(2));
    expect(hunks[0].index, 0);
    expect(hunks[1].index, 1);
    expect(hunks[0].hash, isNot(hunks[1].hash));
    // Idempotency — re-parsing the same source produces the same hashes.
    final again = parseUnifiedDiffHunks(diff);
    expect(again[0].hash, hunks[0].hash);
    expect(again[1].hash, hunks[1].hash);
  });
}
