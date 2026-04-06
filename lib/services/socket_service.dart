import 'dart:async';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter/foundation.dart';

class DigitornSocketService extends ChangeNotifier {
  static final DigitornSocketService _instance = DigitornSocketService._internal();
  factory DigitornSocketService() => _instance;
  DigitornSocketService._internal();

  IO.Socket? _socket;
  bool isConnected = false;
  String? currentAppId;

  // Stream controllers to broadcast events to UI listeners
  final _workbenchEventsCtrl = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get workbenchEvents => _workbenchEventsCtrl.stream;

  void connect(String baseUrl, {String? token}) {
    if (_socket != null && _socket!.connected) return;

    final options = IO.OptionBuilder()
        .setTransports(['websocket'])
        .disableAutoConnect()
        .build();

    // The daemon expects connections on /events namespace
    _socket = IO.io('$baseUrl/events', options);

    _socket!.onConnect((_) {
      debugPrint('Socket Connected to /events');
      isConnected = true;
      notifyListeners();
      
      // Auto-join if we had an app selected
      if (currentAppId != null) {
        joinApp(currentAppId!);
      }
    });

    _socket!.onDisconnect((_) {
      debugPrint('Socket Disconnected');
      isConnected = false;
      notifyListeners();
    });

    _socket!.on('event', (data) {
      // General bus event
      _handleBusEvent(data);
    });

    _socket!.connect();
  }

  void joinApp(String appId) {
    currentAppId = appId;
    if (isConnected) {
      _socket?.emit('join_app', {'app_id': appId});
    }
  }

  void joinSession(String appId, String sessionId) {
    if (isConnected) {
      _socket?.emit('join_session', {'app_id': appId, 'session_id': sessionId});
    }
  }

  void _handleBusEvent(dynamic data) {
    if (data is! Map) return;
    
    final eventType = data['event'] as String?;
    final payload = data['data'];

    if (eventType == 'workbench_read' || eventType == 'workbench_write') {
      _workbenchEventsCtrl.add({
        'type': eventType,
        'payload': payload,
      });
    }
    // We can handle tool_call, diagnostics here for background processes
  }

  void disconnect() {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    isConnected = false;
    notifyListeners();
  }
}
