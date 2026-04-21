import 'dart:async';

/// Thin bridge so the session drawer (a widget that lives outside
/// the chat panel) can trigger chat-export actions on whichever
/// [ChatPanel] is currently active.
///
/// The ChatPanel registers its private `_exportChat` handler on
/// mount and clears it on dispose. [export] does nothing when no
/// chat is mounted — which is the expected state between sessions.
typedef ChatExportHandler =
    Future<void> Function(String mode, String? sessionTitle);

class ChatExportBridge {
  ChatExportBridge._();
  static final ChatExportBridge _i = ChatExportBridge._();
  factory ChatExportBridge() => _i;

  ChatExportHandler? _handler;

  void register(ChatExportHandler handler) {
    _handler = handler;
  }

  void unregister(ChatExportHandler handler) {
    if (_handler == handler) _handler = null;
  }

  bool get hasActive => _handler != null;

  /// Trigger the mounted chat's export with the requested [mode]
  /// (`'clipboard'` or `'markdown'`). Safe no-op when no chat panel
  /// is currently mounted.
  Future<void> export(String mode, {String? sessionTitle}) async {
    final h = _handler;
    if (h == null) return;
    await h(mode, sessionTitle);
  }
}
