import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../constants/api_endpoints.dart';

class SocketService extends ChangeNotifier {
  WebSocket? _socket;
  bool _isConnected = false;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  String? _currentToken;

  bool get isConnected => _isConnected;

  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;

  final _ackController = StreamController<String>.broadcast();
  Stream<String> get ackStream => _ackController.stream;

  void connect(String token) {
    _currentToken = token;
    _doConnect();
  }

  Future<void> _doConnect() async {
    if (_currentToken == null) return;
    _reconnectTimer?.cancel();

    try {
      final uri = Uri.parse('${ApiEndpoints.wsUrl}?token=$_currentToken');
      _socket = await WebSocket.connect(uri.toString());
      _isConnected = true;
      notifyListeners();

      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 25), (t) {
        if (_isConnected && _socket != null) {
          sendFrame({'type': 'ping'});
        }
      });

      _socket!.listen(
        (data) {
          _onData(data);
        },
        onError: (err) {
          _handleDisconnect();
        },
        onDone: () {
          _handleDisconnect();
        },
        cancelOnError: false,
      );
    } catch (e) {
      _handleDisconnect();
    }
  }

  void _onData(dynamic data) {
    try {
      final String text = data is List<int> ? utf8.decode(data) : data.toString();
      final lines = text.split('\n');
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        final json = jsonDecode(line) as Map<String, dynamic>;
        final type = json['type'];

        if (type == 'msg') {
          _messageController.add(json);
          // Auto send ack for delivery
          if (json['message_id'] != null) {
            sendFrame({
              'type': 'ack',
              'message_id': json['message_id'],
            });
          }
        } else if (type == 'server_ack') {
          if (json['message_id'] != null) {
            _ackController.add(json['message_id'] as String);
          }
        }
      }
    } catch (e) {
      debugPrint('[WS] parse error: $e');
    }
  }

  void sendFrame(Map<String, dynamic> frame) {
    if (_socket != null && _isConnected) {
      try {
        _socket!.add(jsonEncode(frame));
      } catch (e) {
        _handleDisconnect();
      }
    }
  }

  void sendEncryptedMessage({
    required String messageId,
    required int recipientUserId,
    required String recipientDeviceId,
    required String ciphertext,
  }) {
    sendFrame({
      'type': 'msg',
      'message_id': messageId,
      'recipient_user_id': recipientUserId,
      'recipient_device_id': recipientDeviceId,
      'ciphertext': ciphertext,
    });
  }

  void _handleDisconnect() {
    _isConnected = false;
    _pingTimer?.cancel();
    notifyListeners();

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 4), () {
      _doConnect();
    });
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _socket?.close();
    _socket = null;
    _isConnected = false;
    _currentToken = null;
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    _messageController.close();
    _ackController.close();
    super.dispose();
  }
}
