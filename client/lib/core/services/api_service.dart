import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../constants/api_endpoints.dart';
import '../models/user.dart';

class ApiService {
  static Future<Map<String, dynamic>> checkInvite(String token) async {
    try {
      final res = await http.post(
        Uri.parse('${ApiEndpoints.baseUrl}/api/v1/auth/invite/check'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'token': token.trim()}),
      );
      if (res.statusCode == 200) {
        return jsonDecode(res.body);
      }
      final body = jsonDecode(res.body);
      return {'valid': false, 'error': body['error'] ?? 'Недійсний інвайт'};
    } catch (e) {
      return {'valid': false, 'error': 'Помилка підключення: $e'};
    }
  }

  static Future<Map<String, dynamic>> register({
    required String inviteToken,
    required String username,
    required String displayName,
    required String password,
    required String deviceId,
    required String deviceName,
    required String identityKey,
    required String signedPreKey,
    required String signedPreKeySig,
    required int registrationId,
    required List<Map<String, dynamic>> oneTimePreKeys,
  }) async {
    try {
      final res = await http.post(
        Uri.parse('${ApiEndpoints.baseUrl}/api/v1/auth/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'invite_token': inviteToken.trim(),
          'username': username.trim(),
          'display_name': displayName.trim(),
          'password': password,
          'device_id': deviceId,
          'device_name': deviceName,
          'identity_key': identityKey,
          'signed_prekey': signedPreKey,
          'signed_prekey_sig': signedPreKeySig,
          'registration_id': registrationId,
          'one_time_prekeys': oneTimePreKeys,
        }),
      );
      if (res.statusCode == 201) {
        return {'success': true, 'data': jsonDecode(res.body)};
      }
      final body = jsonDecode(res.body);
      return {'success': false, 'error': body['error'] ?? 'Помилка реєстрації'};
    } catch (e) {
      return {'success': false, 'error': 'Помилка мережі: $e'};
    }
  }

  static Future<Map<String, dynamic>> login({
    required String username,
    required String password,
    required String deviceId,
    required String deviceName,
  }) async {
    try {
      final res = await http.post(
        Uri.parse('${ApiEndpoints.baseUrl}/api/v1/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username.trim(),
          'password': password,
          'device_id': deviceId,
          'device_name': deviceName,
        }),
      );
      if (res.statusCode == 200) {
        return {'success': true, 'data': jsonDecode(res.body)};
      }
      final body = jsonDecode(res.body);
      return {'success': false, 'error': body['error'] ?? 'Невірний логін або пароль'};
    } catch (e) {
      return {'success': false, 'error': 'Помилка мережі: $e'};
    }
  }

  static Future<bool> uploadPreKeys({
    required String token,
    required String deviceId,
    required String identityKey,
    required String signedPreKey,
    required String signedPreKeySig,
    required int registrationId,
    required List<Map<String, dynamic>> oneTimePreKeys,
  }) async {
    try {
      final res = await http.post(
        Uri.parse('${ApiEndpoints.baseUrl}/api/v1/keys/prekeys'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'device_id': deviceId,
          'identity_key': identityKey,
          'signed_prekey': signedPreKey,
          'signed_prekey_sig': signedPreKeySig,
          'registration_id': registrationId,
          'prekeys': oneTimePreKeys,
        }),
      );
      return res.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  static Future<List<UserModel>> getUsers(String token) async {
    try {
      final res = await http.get(
        Uri.parse('${ApiEndpoints.baseUrl}/api/v1/users'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode == 200) {
        final List list = jsonDecode(res.body);
        return list.map((item) => UserModel.fromJson(item)).toList();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  static Future<List<Map<String, dynamic>>> getPreKeyBundles(String token, int userId) async {
    try {
      final res = await http.get(
        Uri.parse('${ApiEndpoints.baseUrl}/api/v1/keys/$userId'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode == 200) {
        final List list = jsonDecode(res.body);
        return list.map((e) => e as Map<String, dynamic>).toList();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  static Future<List<Map<String, dynamic>>> getPendingMessages(String token) async {
    try {
      final res = await http.get(
        Uri.parse('${ApiEndpoints.baseUrl}/api/v1/messages/pending'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode == 200) {
        final List list = jsonDecode(res.body);
        return list.map((e) => e as Map<String, dynamic>).toList();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  static Future<List<Map<String, dynamic>>> getConversationHistory(String token, int withUserId, {int limit = 100}) async {
    try {
      final res = await http.get(
        Uri.parse('${ApiEndpoints.baseUrl}/api/v1/messages/history?with_user=$withUserId&limit=$limit'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode == 200) {
        final List list = jsonDecode(res.body);
        return list.map((e) => e as Map<String, dynamic>).toList();
      }
      return [];
    } catch (e) {
      debugPrint('[API] getConversationHistory error: $e');
      return [];
    }
  }

  static Future<bool> ackMessages(String token, List<String> messageIds) async {
    try {
      final res = await http.post(
        Uri.parse('${ApiEndpoints.baseUrl}/api/v1/messages/ack'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'message_ids': messageIds}),
      );
      return res.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> markMessagesRead(String token, List<String> messageIds) async {
    try {
      final res = await http.post(
        Uri.parse('${ApiEndpoints.baseUrl}/api/v1/messages/read'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'message_ids': messageIds}),
      );
      return res.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> deleteMessage(String token, String messageId) async {
    try {
      final res = await http.post(
        Uri.parse('${ApiEndpoints.baseUrl}/api/v1/messages/delete'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'message_id': messageId}),
      );
      return res.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> addReaction(String token, String messageId, String emoji) async {
    try {
      final res = await http.post(
        Uri.parse('${ApiEndpoints.baseUrl}/api/v1/messages/reaction'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'message_id': messageId, 'emoji': emoji}),
      );
      return res.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  // Encrypted Media Vault
  static Future<Map<String, dynamic>?> uploadEncryptedBlob({
    required String token,
    required Uint8List ciphertext,
    String mimeType = 'application/octet-stream',
  }) async {
    try {
      final res = await http.post(
        Uri.parse('${ApiEndpoints.baseUrl}/api/v1/media/upload'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': mimeType,
        },
        body: ciphertext,
      );
      if (res.statusCode == 201) {
        return jsonDecode(res.body);
      }
      return null;
    } catch (e) {
      debugPrint('[API] uploadEncryptedBlob error: $e');
      return null;
    }
  }

  static Future<Uint8List?> downloadEncryptedBlob({
    required String token,
    required String mediaId,
  }) async {
    try {
      final res = await http.get(
        Uri.parse('${ApiEndpoints.baseUrl}/api/v1/media/$mediaId'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode == 200) {
        return res.bodyBytes;
      }
      return null;
    } catch (e) {
      debugPrint('[API] downloadEncryptedBlob error: $e');
      return null;
    }
  }
}
