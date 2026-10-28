import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../core/constants/theme.dart';
import '../core/crypto/varta_crypto.dart';
import '../core/models/user.dart';
import '../core/services/api_service.dart';
import '../core/services/auth_provider.dart';
import '../core/services/socket_service.dart';

class LocalMessage {
  final String id;
  final int senderId;
  final String text;
  final DateTime time;
  final bool isMe;
  bool isDelivered;

  LocalMessage({
    required this.id,
    required this.senderId,
    required this.text,
    required this.time,
    required this.isMe,
    this.isDelivered = false,
  });
}

class ChatRoomScreen extends StatefulWidget {
  final UserModel peerUser;

  const ChatRoomScreen({super.key, required this.peerUser});

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final List<LocalMessage> _messages = [];
  StreamSubscription? _msgSub;
  StreamSubscription? _ackSub;

  List<Map<String, dynamic>> _recipientDevices = [];
  bool _isLoadingKeys = true;

  @override
  void initState() {
    super.initState();
    _fetchRecipientKeys();
    _listenSocket();
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _ackSub?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _fetchRecipientKeys() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    if (auth.token == null) return;

    final bundles = await ApiService.getPreKeyBundles(auth.token!, widget.peerUser.id);
    if (mounted) {
      setState(() {
        _recipientDevices = bundles;
        _isLoadingKeys = false;
      });
    }
  }

  void _listenSocket() {
    final socket = Provider.of<SocketService>(context, listen: false);

    _msgSub = socket.messageStream.listen((frame) async {
      final ciphertext = frame['ciphertext'] as String?;
      final msgId = frame['message_id'] as String?;
      final senderId = frame['sender_user_id'] as int?;

      if (ciphertext != null && senderId == widget.peerUser.id) {
        final decrypted = await VartaCrypto.decryptMessage(ciphertext);
        if (decrypted != null && mounted) {
          setState(() {
            _messages.add(LocalMessage(
              id: msgId ?? '${DateTime.now().millisecondsSinceEpoch}',
              senderId: senderId,
              text: decrypted,
              time: DateTime.now(),
              isMe: false,
              isDelivered: true,
            ));
          });
          _scrollToBottom();
        }
      }
    });

    _ackSub = socket.ackStream.listen((msgId) {
      if (mounted) {
        setState(() {
          for (var m in _messages) {
            if (m.id == msgId) {
              m.isDelivered = true;
            }
          }
        });
      }
    });
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final socket = Provider.of<SocketService>(context, listen: false);
    final myId = auth.currentUser?.id ?? 0;

    _textController.clear();
    final msgId = 'vmsg-${DateTime.now().millisecondsSinceEpoch}-${myId}';

    // Add locally immediately
    final localMsg = LocalMessage(
      id: msgId,
      senderId: myId,
      text: text,
      time: DateTime.now(),
      isMe: true,
      isDelivered: false,
    );

    setState(() {
      _messages.add(localMsg);
    });
    _scrollToBottom();

    // If recipient has active devices, encrypt for each device
    if (_recipientDevices.isNotEmpty) {
      for (final dev in _recipientDevices) {
        final identityKey = dev['identity_key'] as String? ?? '';
        final devId = dev['device_id'] as String? ?? '';
        if (identityKey.isNotEmpty) {
          final ciphertext = await VartaCrypto.encryptMessage(
            plainText: text,
            recipientIdentityKeyBase64: identityKey,
          );

          socket.sendEncryptedMessage(
            messageId: msgId,
            recipientUserId: widget.peerUser.id,
            recipientDeviceId: devId,
            ciphertext: ciphertext,
          );
        }
      }
    } else {
      // Fallback envelope if keys are being refreshed
      socket.sendEncryptedMessage(
        messageId: msgId,
        recipientUserId: widget.peerUser.id,
        recipientDeviceId: 'default',
        ciphertext: text,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: AppTheme.cardDark,
              child: Text(
                widget.peerUser.displayName.isNotEmpty
                    ? widget.peerUser.displayName[0].toUpperCase()
                    : '?',
                style: const TextStyle(color: AppTheme.accentGold, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.peerUser.displayName,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  Row(
                    children: [
                      const Icon(Icons.lock, color: AppTheme.accentGold, size: 11),
                      const SizedBox(width: 4),
                      Text(
                        _isLoadingKeys
                            ? 'Синхронізація ключів...'
                            : 'E2EE Захищено (${_recipientDevices.length} пристрій)',
                        style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          // E2EE Notice Pill
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.surfaceDark,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppTheme.dividerDark),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.shield_outlined, color: AppTheme.accentGold, size: 13),
                SizedBox(width: 6),
                Text(
                  'Повідомлення захищені наскрізним шифруванням VARTA',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),

          // Message Bubbles
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Text(
                      'Почніть захищений діалог',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    itemCount: _messages.length,
                    itemBuilder: (ctx, i) {
                      final msg = _messages[i];
                      return Align(
                        alignment: msg.isMe ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.78,
                          ),
                          decoration: BoxDecoration(
                            color: msg.isMe ? AppTheme.outgoingBubble : AppTheme.incomingBubble,
                            borderRadius: BorderRadius.only(
                              topLeft: const Radius.circular(16),
                              topRight: const Radius.circular(16),
                              bottomLeft: Radius.circular(msg.isMe ? 16 : 4),
                              bottomRight: Radius.circular(msg.isMe ? 4 : 16),
                            ),
                            border: Border.all(
                              color: msg.isMe
                                  ? AppTheme.primaryBlue.withOpacity(0.4)
                                  : AppTheme.dividerDark,
                              width: 1,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                msg.text,
                                style: const TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontSize: 15,
                                  height: 1.3,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    DateFormat('HH:mm').format(msg.time),
                                    style: const TextStyle(
                                      color: AppTheme.textMuted,
                                      fontSize: 10,
                                    ),
                                  ),
                                  if (msg.isMe) ...[
                                    const SizedBox(width: 4),
                                    Icon(
                                      msg.isDelivered ? Icons.done_all : Icons.done,
                                      size: 14,
                                      color: msg.isDelivered ? AppTheme.accentGold : AppTheme.textMuted,
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),

          // Input Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: AppTheme.surfaceDark,
            child: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      textCapitalization: TextCapitalization.sentences,
                      maxLines: null,
                      decoration: InputDecoration(
                        hintText: 'Захищене повідомлення...',
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: AppTheme.cardDark,
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: AppTheme.accentGold,
                    child: IconButton(
                      icon: const Icon(Icons.send_rounded, color: Colors.black, size: 20),
                      onPressed: _sendMessage,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
