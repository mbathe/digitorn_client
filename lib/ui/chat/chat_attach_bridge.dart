/// Cross-widget bridge that lets any panel push an attachment into
/// the currently-mounted chat composer without taking a direct Dart
/// reference to `_ChatPanelState`.
///
/// Today used by the Monaco editor header's "Add to chat" button —
/// clicking it writes the current file's content to a temp path and
/// calls [attach], which forwards the payload to the chat panel's
/// own `_addAttachmentExternal` handler. Same pattern as
/// [ChatExportBridge] for drawer→chat export actions.
///
/// Safe no-op when no chat panel is mounted (e.g. dashboard only).
library;

import '../chat/attach/attachment_helpers.dart' show AttachmentEntry;

typedef ChatAttachHandler = void Function(AttachmentEntry entry);

class ChatAttachBridge {
  ChatAttachBridge._();
  static final ChatAttachBridge _i = ChatAttachBridge._();
  factory ChatAttachBridge() => _i;

  ChatAttachHandler? _handler;

  void register(ChatAttachHandler handler) {
    _handler = handler;
  }

  void unregister(ChatAttachHandler handler) {
    if (_handler == handler) _handler = null;
  }

  bool get hasActive => _handler != null;

  /// Push an attachment into the mounted chat composer. Does nothing
  /// when no chat is currently mounted.
  void attach(AttachmentEntry entry) {
    _handler?.call(entry);
  }
}
