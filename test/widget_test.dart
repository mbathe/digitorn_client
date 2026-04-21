// Placeholder smoke test. The real app entrypoint (main.dart) pulls
// in native services (sockets, storage, webview) that can't run in a
// unit-test sandbox, so we don't boot it here. Feature-level widget
// tests live in test/models/ and test/services/.

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('placeholder', () {
    expect(1 + 1, 2);
  });
}
