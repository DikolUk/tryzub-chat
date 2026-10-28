import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../constants/api_endpoints.dart';

class SocketService extends ChangeNotifier {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _isConnected = false;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  String? _currentToken;

  bool get isConnected => _isConnected;

  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;

  final _ackController = StreamController<String>.broadcast();
  Stream<String> get ackStream => _ackController.stream;

  final _deliveryController = StreamController<String>.broadcast();
  Stream<String> get deliveryStream => _deliveryController.stream;

  final _readReceiptController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get readReceiptStream => _readReceiptController.stream;

  final _typingController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get typingStream => _typingController.stream;

  final _reactionController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get reactionStream => _reactionController.stream;

  final _deleteController = StreamController<String>.broadcast();
  Stream<String> get deleteStream => _deleteController.stream;

  void connect(String token) {
    if (_currentToken == token && _isConnected) return;
    _currentToken = token;
    _doConnect();
  }

  Future<void> _doConnect() async {
    if (_currentToken == null) return;
    _reconnectTimer?.cancel();

    try {
      const wsUrl = ApiEndpoints.wsUrl;
      final uri = Uri.parse('$wsUrl?token=$_currentToken');
      
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;

      _isConnected = true;
      notifyListeners();

      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 25), (t) {
        if (_isConnected) {
          sendFrame({'type': 'ping'});
        }
      });

      _subscription = _channel!.stream.listen(
        (data) {
          _onData(data);
        },
        onError: (err) {
          debugPrint('[WS] Error: $err');
          _handleDisconnect();
        },
        onDone: () {
          debugPrint('[WS] Connection closed');
          _handleDisconnect();
        },
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('[WS] Connect error: $e');
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
        final type = json['type'] as String?;

        switch (type) {
          case 'msg':
            _messageController.add(json);
            if (json['message_id'] != null) {
              sendFrame({
                'type': 'ack',
                'message_id': json['message_id'],
              });
            }
            break;

          case 'server_ack':
            if (json['message_id'] != null) {
              _ackController.add(json['message_id'] as String);
            }
            break;

          case 'delivery_receipt':
            if (json['message_id'] != null) {
              _deliveryController.add(json['message_id'] as String);
            }
            break;

          case 'read_receipt':
            _readReceiptController.add(json);
            break;

          case 'typing':
            _typingController.add(json);
            break;

          case 'reaction':
            _reactionController.add(json);
            break;

          case 'msg_deleted':
            if (json['message_id'] != null) {
              _deleteController.add(json['message_id'] as String);
            }
            break;

          case 'pong':
            break;
        }
      }
    } catch (e) {
      debugPrint('[WS] parse error: $e');
    }
  }

  void sendFrame(Map<String, dynamic> frame) {
    if (_channel != null && _isConnected) {
      try {
        _channel!.sink.add(jsonEncode(frame));
      } catch (e) {
        debugPrint('[WS] sendFrame error: $e');
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

  void sendTyping({required int recipientUserId, required bool isTyping}) {
    sendFrame({
      'type': 'typing',
      'recipient_user_id': recipientUserId,
      'is_typing': isTyping,
    });
  }

  void sendReadReceipt({required List<String> messageIds, required int recipientUserId}) {
    sendFrame({
      'type': 'read',
      'recipient_user_id': recipientUserId,
      'message_ids': messageIds,
    });
  }

  void sendReaction({required String messageId, required String emoji}) {
    sendFrame({
      'type': 'reaction',
      'message_id': messageId,
      'emoji': emoji,
    });
  }

  void sendDeleteMessage({required String messageId}) {
    sendFrame({
      'type': 'delete',
      'message_id': messageId,
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
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _isConnected = false;
    _currentToken = null;
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    _messageController.close();
    _ackController.close();
    _deliveryController.close();
    _readReceiptController.close();
    _typingController.close();
    _reactionController.close();
    _deleteController.close();
    super.dispose();
  }
}
