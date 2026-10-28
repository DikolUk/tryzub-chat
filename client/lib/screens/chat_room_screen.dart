import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../core/constants/theme.dart';
import '../core/crypto/varta_crypto.dart';
import '../core/models/chat_message.dart';
import '../core/models/user.dart';
import '../core/services/api_service.dart';
import '../core/services/auth_provider.dart';
import '../core/services/chat_storage.dart';
import '../core/services/media_service.dart';
import '../core/services/socket_service.dart';
import '../widgets/image_bubble.dart';
import '../widgets/voice_bubble.dart';

class ChatRoomScreen extends StatefulWidget {
  final UserModel peerUser;

  const ChatRoomScreen({super.key, required this.peerUser});

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];

  StreamSubscription? _msgSub;
  StreamSubscription? _ackSub;
  StreamSubscription? _delivSub;
  StreamSubscription? _readSub;
  StreamSubscription? _typingSub;
  StreamSubscription? _reactionSub;
  StreamSubscription? _deleteSub;

  List<Map<String, dynamic>> _recipientDevices = [];
  bool _isLoadingKeys = true;
  bool _isPeerTyping = false;
  Timer? _peerTypingTimer;
  Timer? _myTypingDebounce;

  // Quoted reply
  ChatMessage? _replyingTo;

  // Voice Recording state
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecordingVoice = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;

  @override
  void initState() {
    super.initState();
    _loadLocalChat();
    _fetchRecipientKeys();
    _fetchServerHistory();
    _listenSocket();
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _ackSub?.cancel();
    _delivSub?.cancel();
    _readSub?.cancel();
    _typingSub?.cancel();
    _reactionSub?.cancel();
    _deleteSub?.cancel();
    _peerTypingTimer?.cancel();
    _myTypingDebounce?.cancel();
    _recordTimer?.cancel();
    _audioRecorder.dispose();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadLocalChat() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final myId = auth.currentUser?.id ?? 0;
    if (myId == 0) return;

    final saved = await ChatStorage.loadMessages(myId, widget.peerUser.id);
    if (mounted && saved.isNotEmpty) {
      setState(() {
        _messages.clear();
        _messages.addAll(saved);
      });
      _scrollToBottom();
    }
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

  Future<void> _fetchServerHistory() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final myId = auth.currentUser?.id ?? 0;
    if (auth.token == null || myId == 0) return;

    final history = await ApiService.getConversationHistory(auth.token!, widget.peerUser.id);
    final List<String> unreadIncomingIds = [];
    bool hasNew = false;

    for (final raw in history) {
      final msgId = raw['message_id'] as String? ?? '';
      final senderId = raw['sender_user_id'] as int? ?? 0;
      final ciphertext = raw['ciphertext'] as String? ?? '';
      final isDelivered = raw['delivered'] == true;
      final isRead = raw['read_at'] != null;
      final isDeleted = raw['is_deleted'] == true;

      if (_messages.any((m) => m.id == msgId)) {
        // Update delivery/read status if already stored
        final existing = _messages.firstWhere((m) => m.id == msgId);
        if (isRead && existing.status != 'read') {
          existing.status = 'read';
          hasNew = true;
        } else if (isDelivered && existing.status == 'sent') {
          existing.status = 'delivered';
          hasNew = true;
        }
        continue;
      }

      if (ciphertext.isNotEmpty && !isDeleted) {
        final decrypted = await VartaCrypto.decryptMessage(ciphertext);
        if (decrypted != null) {
          final isMe = senderId == myId;
          final parsedMsg = _parsePayload(
            id: msgId,
            senderId: senderId,
            recipientId: isMe ? widget.peerUser.id : myId,
            decrypted: decrypted,
            time: DateTime.tryParse(raw['created_at']?.toString() ?? '') ?? DateTime.now(),
            isMe: isMe,
            status: isRead ? 'read' : (isDelivered ? 'delivered' : 'sent'),
          );
          _messages.add(parsedMsg);
          hasNew = true;

          if (!isMe && !isRead) {
            unreadIncomingIds.add(msgId);
          }
        }
      }
    }

    if (hasNew && mounted) {
      _messages.sort((a, b) => a.time.compareTo(b.time));
      setState(() {});
      await ChatStorage.saveMessages(myId, widget.peerUser.id, _messages);
      _scrollToBottom();
    }

    if (unreadIncomingIds.isNotEmpty) {
      await ApiService.markMessagesRead(auth.token!, unreadIncomingIds);
      if (mounted) {
        final socket = Provider.of<SocketService>(context, listen: false);
        socket.sendReadReceipt(messageIds: unreadIncomingIds, recipientUserId: widget.peerUser.id);
      }
    }
  }

  ChatMessage _parsePayload({
    required String id,
    required int senderId,
    required int recipientId,
    required String decrypted,
    required DateTime time,
    required bool isMe,
    required String status,
  }) {
    try {
      if (decrypted.trim().startsWith('{') && decrypted.contains('"varta_type"')) {
        final Map<String, dynamic> json = jsonDecode(decrypted);
        if (json['varta_type'] == 'media') {
          return ChatMessage(
            id: id,
            senderId: senderId,
            recipientId: recipientId,
            text: json['file_name'] ?? '',
            type: 'media',
            mediaType: json['media_type']?.toString() ?? 'image',
            mediaId: json['media_id']?.toString() ?? '',
            mediaKeyB64: json['key_b64']?.toString() ?? '',
            mediaDuration: json['duration_sec'] is int ? json['duration_sec'] : 0,
            fileName: json['file_name']?.toString(),
            time: time,
            isMe: isMe,
            status: status,
          );
        }
      }
    } catch (_) {}

    return ChatMessage(
      id: id,
      senderId: senderId,
      recipientId: recipientId,
      text: decrypted,
      type: 'text',
      time: time,
      isMe: isMe,
      status: status,
    );
  }

  void _listenSocket() {
    final socket = Provider.of<SocketService>(context, listen: false);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final myId = auth.currentUser?.id ?? 0;

    // Incoming messages
    _msgSub = socket.messageStream.listen((frame) async {
      final ciphertext = frame['ciphertext'] as String?;
      final msgId = frame['message_id'] as String?;
      final senderId = frame['sender_user_id'] as int?;

      if (ciphertext != null && senderId == widget.peerUser.id) {
        final decrypted = await VartaCrypto.decryptMessage(ciphertext);
        if (decrypted != null && mounted) {
          final newMsg = _parsePayload(
            id: msgId ?? 'vmsg-${DateTime.now().millisecondsSinceEpoch}',
            senderId: senderId ?? 0,
            recipientId: myId,
            decrypted: decrypted,
            time: DateTime.now(),
            isMe: false,
            status: 'read',
          );

          setState(() {
            _messages.add(newMsg);
          });
          _scrollToBottom();
          await ChatStorage.saveOrUpdateMessage(myId, widget.peerUser.id, newMsg);

          // Immediately send read receipt since user is active in this room
          if (msgId != null) {
            socket.sendReadReceipt(messageIds: [msgId], recipientUserId: widget.peerUser.id);
            if (auth.token != null) {
              await ApiService.markMessagesRead(auth.token!, [msgId]);
            }
          }
        }
      }
    });

    // Server ACK (single checkmark)
    _ackSub = socket.ackStream.listen((msgId) {
      if (mounted) {
        setState(() {
          for (var m in _messages) {
            if (m.id == msgId && m.status == 'sending') {
              m.status = 'sent';
            }
          }
        });
        ChatStorage.saveMessages(myId, widget.peerUser.id, _messages);
      }
    });

    // Recipient Delivery ACK (double grey checkmark)
    _delivSub = socket.deliveryStream.listen((msgId) {
      if (mounted) {
        setState(() {
          for (var m in _messages) {
            if (m.id == msgId && m.status != 'read') {
              m.status = 'delivered';
            }
          }
        });
        ChatStorage.saveMessages(myId, widget.peerUser.id, _messages);
      }
    });

    // Read Receipt (double gold checkmark)
    _readSub = socket.readReceiptStream.listen((frame) {
      final ids = frame['message_ids'] as List?;
      if (ids != null && mounted) {
        setState(() {
          for (var m in _messages) {
            if (ids.contains(m.id)) {
              m.status = 'read';
            }
          }
        });
        ChatStorage.saveMessages(myId, widget.peerUser.id, _messages);
      }
    });

    // Typing indicator
    _typingSub = socket.typingStream.listen((frame) {
      final senderId = frame['sender_user_id'] as int?;
      final isTyping = frame['is_typing'] == true;
      if (senderId == widget.peerUser.id && mounted) {
        setState(() {
          _isPeerTyping = isTyping;
        });
        _peerTypingTimer?.cancel();
        if (isTyping) {
          _peerTypingTimer = Timer(const Duration(seconds: 4), () {
            if (mounted) setState(() => _isPeerTyping = false);
          });
        }
      }
    });

    // Reaction update
    _reactionSub = socket.reactionStream.listen((frame) {
      final msgId = frame['message_id'] as String?;
      final emoji = frame['emoji'] as String?;
      if (msgId != null && emoji != null && mounted) {
        setState(() {
          for (var m in _messages) {
            if (m.id == msgId) {
              m.reaction = emoji;
            }
          }
        });
        ChatStorage.updateReaction(
          myUserId: myId,
          peerUserId: widget.peerUser.id,
          messageId: msgId,
          emoji: emoji,
        );
      }
    });

    // Delete message
    _deleteSub = socket.deleteStream.listen((msgId) {
      if (mounted) {
        setState(() {
          for (var m in _messages) {
            if (m.id == msgId) {
              m.isDeleted = true;
              m.text = 'Повідомлення видалено';
            }
          }
        });
        ChatStorage.deleteMessage(
          myUserId: myId,
          peerUserId: widget.peerUser.id,
          messageId: msgId,
        );
      }
    });
  }

  void _onTextChanged(String text) {
    _myTypingDebounce?.cancel();
    final socket = Provider.of<SocketService>(context, listen: false);

    if (text.isNotEmpty) {
      socket.sendTyping(recipientUserId: widget.peerUser.id, isTyping: true);
      _myTypingDebounce = Timer(const Duration(seconds: 3), () {
        socket.sendTyping(recipientUserId: widget.peerUser.id, isTyping: false);
      });
    } else {
      socket.sendTyping(recipientUserId: widget.peerUser.id, isTyping: false);
    }
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

  Future<void> _sendMessage({
    String? customPayload,
    String? previewText,
    String type = 'text',
    String? mediaType,
    String? mediaId,
    String? mediaKeyB64,
    int? mediaDuration,
    String? fileName,
  }) async {
    final text = customPayload ?? _textController.text.trim();
    if (text.isEmpty) return;

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final socket = Provider.of<SocketService>(context, listen: false);
    final myId = auth.currentUser?.id ?? 0;

    _textController.clear();
    socket.sendTyping(recipientUserId: widget.peerUser.id, isTyping: false);

    final msgId = 'vmsg-${DateTime.now().millisecondsSinceEpoch}-$myId';
    final replyId = _replyingTo?.id;
    final replySnippet = _replyingTo?.text;

    final localMsg = ChatMessage(
      id: msgId,
      senderId: myId,
      recipientId: widget.peerUser.id,
      text: previewText ?? text,
      type: type,
      mediaType: mediaType,
      mediaId: mediaId,
      mediaKeyB64: mediaKeyB64,
      mediaDuration: mediaDuration,
      fileName: fileName,
      time: DateTime.now(),
      isMe: true,
      status: 'sending',
      replyToId: replyId,
      replyToText: replySnippet,
    );

    setState(() {
      _messages.add(localMsg);
      _replyingTo = null;
    });
    _scrollToBottom();
    await ChatStorage.saveOrUpdateMessage(myId, widget.peerUser.id, localMsg);

    // E2EE Transmission to each recipient device
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
      socket.sendEncryptedMessage(
        messageId: msgId,
        recipientUserId: widget.peerUser.id,
        recipientDeviceId: 'default',
        ciphertext: text,
      );
    }
  }

  // Voice recording controls
  Future<void> _startVoiceRecord() async {
    if (await _audioRecorder.hasPermission()) {
      await _audioRecorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000),
        path: '',
      );
      setState(() {
        _isRecordingVoice = true;
        _recordSeconds = 0;
      });
      _recordTimer?.cancel();
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() => _recordSeconds++);
        }
      });
    }
  }

  Future<void> _stopVoiceRecordAndSend() async {
    _recordTimer?.cancel();
    final path = await _audioRecorder.stop();
    setState(() => _isRecordingVoice = false);

    if (path == null || _recordSeconds < 1 || !mounted) return;

    final auth = Provider.of<AuthProvider>(context, listen: false);
    if (auth.token == null) return;

    try {
      final xfile = XFile(path);
      final bytes = await xfile.readAsBytes();

      final res = await MediaService.uploadEncryptedMedia(
        token: auth.token!,
        fileBytes: bytes,
        mediaType: 'voice',
        durationSec: _recordSeconds,
      );

      if (res != null) {
        final payloadJson = jsonEncode({
          'varta_type': 'media',
          'media_type': 'voice',
          'media_id': res['media_id'],
          'key_b64': res['key_b64'],
          'duration_sec': _recordSeconds,
        });

        await _sendMessage(
          customPayload: payloadJson,
          previewText: '🎤 Голосове повідомлення ($_recordSeconds с)',
          type: 'media',
          mediaType: 'voice',
          mediaId: res['media_id'],
          mediaKeyB64: res['key_b64'],
          mediaDuration: _recordSeconds,
        );
      }
    } catch (e) {
      debugPrint('[VoiceRecord] send error: $e');
    }
  }

  Future<void> _cancelVoiceRecord() async {
    _recordTimer?.cancel();
    await _audioRecorder.stop();
    setState(() => _isRecordingVoice = false);
  }

  // Photo & Attachment Picker
  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source, imageQuality: 85);
    if (picked == null || !mounted) return;

    final auth = Provider.of<AuthProvider>(context, listen: false);
    if (auth.token == null) return;

    final bytes = await picked.readAsBytes();
    final res = await MediaService.uploadEncryptedMedia(
      token: auth.token!,
      fileBytes: bytes,
      mediaType: 'image',
      fileName: picked.name,
    );

    if (res != null) {
      final payloadJson = jsonEncode({
        'varta_type': 'media',
        'media_type': 'image',
        'media_id': res['media_id'],
        'key_b64': res['key_b64'],
        'file_name': picked.name,
      });

      await _sendMessage(
        customPayload: payloadJson,
        previewText: '📷 Фото',
        type: 'media',
        mediaType: 'image',
        mediaId: res['media_id'],
        mediaKeyB64: res['key_b64'],
        fileName: picked.name,
      );
    }
  }

  void _showAttachmentSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.cardDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildAttachmentItem(
                      icon: Icons.photo_library_rounded,
                      color: AppTheme.primaryBlue,
                      label: 'Галерея',
                      onTap: () {
                        Navigator.pop(ctx);
                        _pickImage(ImageSource.gallery);
                      },
                    ),
                    _buildAttachmentItem(
                      icon: Icons.camera_alt_rounded,
                      color: AppTheme.accentGold,
                      label: 'Камера',
                      onTap: () {
                        Navigator.pop(ctx);
                        _pickImage(ImageSource.camera);
                      },
                    ),
                    _buildAttachmentItem(
                      icon: Icons.mic_rounded,
                      color: Colors.redAccent,
                      label: 'Голосове',
                      onTap: () {
                        Navigator.pop(ctx);
                        _startVoiceRecord();
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAttachmentItem({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: color.withValues(alpha: 0.15),
              child: Icon(icon, color: color, size: 28),
            ),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary)),
          ],
        ),
      ),
    );
  }

  // Message Options Modal (Reactions, Reply, Delete)
  void _showMessageOptions(ChatMessage msg) {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final socket = Provider.of<SocketService>(context, listen: false);
    final myId = auth.currentUser?.id ?? 0;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.cardDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Emoji reaction bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: ['👍', '❤️', '🔥', '👏', '🤣', '🛡️'].map((emoji) {
                    return InkWell(
                      onTap: () {
                        Navigator.pop(ctx);
                        socket.sendReaction(messageId: msg.id, emoji: emoji);
                        if (auth.token != null) {
                          ApiService.addReaction(auth.token!, msg.id, emoji);
                        }
                        setState(() => msg.reaction = emoji);
                        ChatStorage.updateReaction(
                          myUserId: myId,
                          peerUserId: widget.peerUser.id,
                          messageId: msg.id,
                          emoji: emoji,
                        );
                      },
                      child: Text(emoji, style: const TextStyle(fontSize: 28)),
                    );
                  }).toList(),
                ),
              ),
              const Divider(color: AppTheme.dividerDark, height: 1),
              // Reply action
              ListTile(
                leading: const Icon(Icons.reply_rounded, color: AppTheme.accentGold),
                title: const Text('Відповісти', style: TextStyle(color: AppTheme.textPrimary)),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() => _replyingTo = msg);
                },
              ),
              // Delete action (if my message)
              if (msg.isMe)
                ListTile(
                  leading: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                  title: const Text('Видалити для всіх', style: TextStyle(color: Colors.redAccent)),
                  onTap: () {
                    Navigator.pop(ctx);
                    socket.sendDeleteMessage(messageId: msg.id);
                    if (auth.token != null) {
                      ApiService.deleteMessage(auth.token!, msg.id);
                    }
                    setState(() {
                      msg.isDeleted = true;
                      msg.text = 'Повідомлення видалено';
                    });
                    ChatStorage.deleteMessage(
                      myUserId: myId,
                      peerUserId: widget.peerUser.id,
                      messageId: msg.id,
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);
    final token = auth.token ?? '';

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
                  if (_isPeerTyping)
                    const Text(
                      'друкує...',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.accentGold,
                        fontStyle: FontStyle.italic,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  else
                    Row(
                      children: [
                        const Icon(Icons.lock, color: AppTheme.accentGold, size: 11),
                        const SizedBox(width: 4),
                        Text(
                          _isLoadingKeys
                              ? 'Синхронізація ключів...'
                              : 'E2EE Захищено (${_recipientDevices.length} пристроїв)',
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
            margin: const EdgeInsets.symmetric(vertical: 6),
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
                  'Наскрізне шифрування VARTA Zero-Knowledge',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),

          // Message Bubbles List
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
                      return GestureDetector(
                        onLongPress: () => _showMessageOptions(msg),
                        child: Align(
                          alignment: msg.isMe ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            constraints: BoxConstraints(
                              maxWidth: MediaQuery.of(context).size.width * 0.82,
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
                                    ? AppTheme.primaryBlue.withValues(alpha: 0.4)
                                    : AppTheme.dividerDark,
                                width: 1,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                // Quoted Reply
                                if (msg.replyToText != null && msg.replyToText!.isNotEmpty)
                                  Container(
                                    margin: const EdgeInsets.only(bottom: 6),
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.black26,
                                      borderRadius: BorderRadius.circular(6),
                                      border: const Border(
                                        left: BorderSide(color: AppTheme.accentGold, width: 3),
                                      ),
                                    ),
                                    child: Text(
                                      msg.replyToText!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                                    ),
                                  ),

                                // Message Body
                                if (msg.isDeleted)
                                  const Text(
                                    'Повідомлення видалено',
                                    style: TextStyle(
                                      color: AppTheme.textMuted,
                                      fontStyle: FontStyle.italic,
                                      fontSize: 13,
                                    ),
                                  )
                                else if (msg.type == 'media') ...[
                                  if (msg.mediaType == 'voice' && msg.mediaId != null && msg.mediaKeyB64 != null)
                                    VoiceBubble(
                                      mediaId: msg.mediaId!,
                                      keyB64: msg.mediaKeyB64!,
                                      durationSec: msg.mediaDuration ?? 0,
                                      token: token,
                                      isMe: msg.isMe,
                                    )
                                  else if (msg.mediaType == 'image' && msg.mediaId != null && msg.mediaKeyB64 != null)
                                    ImageBubble(
                                      mediaId: msg.mediaId!,
                                      keyB64: msg.mediaKeyB64!,
                                      token: token,
                                      isMe: msg.isMe,
                                    )
                                  else
                                    Text(
                                      msg.text,
                                      style: const TextStyle(color: AppTheme.textPrimary, fontSize: 15),
                                    ),
                                ] else
                                  Text(
                                    msg.text,
                                    style: const TextStyle(
                                      color: AppTheme.textPrimary,
                                      fontSize: 15,
                                      height: 1.3,
                                    ),
                                  ),

                                const SizedBox(height: 4),

                                // Timestamp, Status & Reaction
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (msg.reaction != null) ...[
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: Colors.black38,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text(msg.reaction!, style: const TextStyle(fontSize: 12)),
                                      ),
                                      const SizedBox(width: 4),
                                    ],
                                    Text(
                                      DateFormat('HH:mm').format(msg.time),
                                      style: const TextStyle(color: AppTheme.textMuted, fontSize: 10),
                                    ),
                                    if (msg.isMe) ...[
                                      const SizedBox(width: 4),
                                      if (msg.status == 'read')
                                        const Icon(Icons.done_all, size: 14, color: AppTheme.accentGold)
                                      else if (msg.status == 'delivered')
                                        const Icon(Icons.done_all, size: 14, color: AppTheme.textMuted)
                                      else if (msg.status == 'sent')
                                        const Icon(Icons.done, size: 14, color: AppTheme.textMuted)
                                      else
                                        const Icon(Icons.access_time_rounded, size: 12, color: AppTheme.textMuted),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),

          // Quoted reply banner
          if (_replyingTo != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              color: AppTheme.cardDark,
              child: Row(
                children: [
                  const Icon(Icons.reply_rounded, color: AppTheme.accentGold, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Відповідь на повідомлення',
                          style: TextStyle(fontSize: 11, color: AppTheme.accentGold, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          _replyingTo!.text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18, color: AppTheme.textMuted),
                    onPressed: () => setState(() => _replyingTo = null),
                  ),
                ],
              ),
            ),

          // Voice Recording Active Bar
          if (_isRecordingVoice)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              color: AppTheme.surfaceDark,
              child: Row(
                children: [
                  const Icon(Icons.fiber_manual_record_rounded, color: Colors.redAccent, size: 18),
                  const SizedBox(width: 10),
                  Text(
                    'Запис: 0:${_recordSeconds.toString().padLeft(2, '0')}',
                    style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _cancelVoiceRecord,
                    child: const Text('Скасувати', style: TextStyle(color: AppTheme.textMuted)),
                  ),
                  const SizedBox(width: 8),
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: AppTheme.accentGold,
                    child: IconButton(
                      icon: const Icon(Icons.send_rounded, color: Colors.black, size: 18),
                      onPressed: _stopVoiceRecordAndSend,
                    ),
                  ),
                ],
              ),
            )
          else
            // Regular Input Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              color: AppTheme.surfaceDark,
              child: SafeArea(
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.attach_file_rounded, color: AppTheme.textSecondary),
                      onPressed: _showAttachmentSheet,
                    ),
                    Expanded(
                      child: TextField(
                        controller: _textController,
                        textCapitalization: TextCapitalization.sentences,
                        maxLines: null,
                        onChanged: _onTextChanged,
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
                    const SizedBox(width: 6),
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: AppTheme.cardDark,
                      child: IconButton(
                        icon: const Icon(Icons.mic_rounded, color: AppTheme.accentGold, size: 20),
                        onPressed: _startVoiceRecord,
                      ),
                    ),
                    const SizedBox(width: 6),
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: AppTheme.accentGold,
                      child: IconButton(
                        icon: const Icon(Icons.send_rounded, color: Colors.black, size: 20),
                        onPressed: () => _sendMessage(),
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
