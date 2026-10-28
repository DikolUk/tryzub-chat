import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/chat_message.dart';

class ChatStorage {
  static String _chatKey(int myUserId, int peerUserId) => 'varta_chat_${myUserId}_$peerUserId';
  static String _recentChatsKey(int myUserId) => 'varta_recent_chats_$myUserId';

  /// Loads stored messages for a specific peer conversation
  static Future<List<ChatMessage>> loadMessages(int myUserId, int peerUserId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_chatKey(myUserId, peerUserId));
      if (raw == null || raw.isEmpty) return [];

      final List list = jsonDecode(raw);
      return list
          .map((item) => ChatMessage.fromJson(item as Map<String, dynamic>))
          .where((m) => !m.isDeleted)
          .toList();
    } catch (e) {
      debugPrint('[ChatStorage] loadMessages error: $e');
      return [];
    }
  }

  /// Saves list of messages for a peer conversation
  static Future<void> saveMessages(int myUserId, int peerUserId, List<ChatMessage> messages) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Keep last 300 messages per conversation locally
      final listToSave = messages.length > 300 ? messages.sublist(messages.length - 300) : messages;
      final encoded = jsonEncode(listToSave.map((m) => m.toJson()).toList());
      await prefs.setString(_chatKey(myUserId, peerUserId), encoded);

      if (messages.isNotEmpty) {
        final lastMsg = messages.last;
        await _updateRecentChat(myUserId, peerUserId, lastMsg);
      }
    } catch (e) {
      debugPrint('[ChatStorage] saveMessages error: $e');
    }
  }

  /// Appends or updates a single message in storage
  static Future<void> saveOrUpdateMessage(int myUserId, int peerUserId, ChatMessage msg) async {
    final list = await loadMessages(myUserId, peerUserId);
    final idx = list.indexWhere((m) => m.id == msg.id);
    if (idx >= 0) {
      list[idx] = msg;
    } else {
      list.add(msg);
    }
    await saveMessages(myUserId, peerUserId, list);
  }

  /// Marks messages as delivered or read
  static Future<void> updateMessageStatus({
    required int myUserId,
    required int peerUserId,
    required List<String> messageIds,
    required String status,
  }) async {
    final list = await loadMessages(myUserId, peerUserId);
    bool changed = false;
    for (final m in list) {
      if (messageIds.contains(m.id)) {
        m.status = status;
        changed = true;
      }
    }
    if (changed) {
      await saveMessages(myUserId, peerUserId, list);
    }
  }

  /// Updates reaction on a message
  static Future<void> updateReaction({
    required int myUserId,
    required int peerUserId,
    required String messageId,
    required String emoji,
  }) async {
    final list = await loadMessages(myUserId, peerUserId);
    final idx = list.indexWhere((m) => m.id == messageId);
    if (idx >= 0) {
      list[idx].reaction = emoji;
      await saveMessages(myUserId, peerUserId, list);
    }
  }

  /// Marks a message as deleted
  static Future<void> deleteMessage({
    required int myUserId,
    required int peerUserId,
    required String messageId,
  }) async {
    final list = await loadMessages(myUserId, peerUserId);
    final idx = list.indexWhere((m) => m.id == messageId);
    if (idx >= 0) {
      list[idx].isDeleted = true;
      list[idx].text = 'Повідомлення видалено';
      await saveMessages(myUserId, peerUserId, list);
    }
  }

  static Future<void> _updateRecentChat(int myUserId, int peerUserId, ChatMessage lastMsg) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _recentChatsKey(myUserId);
      final raw = prefs.getString(key);
      Map<String, dynamic> recents = {};
      if (raw != null && raw.isNotEmpty) {
        recents = jsonDecode(raw) as Map<String, dynamic>;
      }

      String previewText = lastMsg.text;
      if (lastMsg.type == 'media') {
        if (lastMsg.mediaType == 'voice') {
          previewText = '🎤 Голосове повідомлення';
        } else if (lastMsg.mediaType == 'image') {
          previewText = '📷 Фотографія';
        } else if (lastMsg.mediaType == 'video') {
          previewText = '🎥 Відеоповідомлення';
        } else {
          previewText = '📎 Вкладений файл';
        }
      }

      recents['$peerUserId'] = {
        'peer_user_id': peerUserId,
        'last_text': previewText,
        'last_time': lastMsg.time.toIso8601String(),
        'is_read': lastMsg.isMe || lastMsg.status == 'read',
      };

      await prefs.setString(key, jsonEncode(recents));
    } catch (e) {
      debugPrint('[ChatStorage] updateRecentChat error: $e');
    }
  }

  static Future<Map<String, dynamic>> getRecentChats(int myUserId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_recentChatsKey(myUserId));
      if (raw == null || raw.isEmpty) return {};
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      return {};
    }
  }
}
