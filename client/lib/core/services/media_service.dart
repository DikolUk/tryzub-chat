import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'api_service.dart';

class MediaService {
  static final _cipher = AesGcm.with256bits();
  static final Map<String, Uint8List> _decryptedMemoryCache = {};

  /// Encrypts raw binary data with an ephemeral AES-GCM-256 key
  /// Returns a record with the combined payload (nonce + mac + ciphertext) and key in Base64
  static Future<Map<String, dynamic>> encryptMedia(Uint8List cleartext) async {
    final random = Random.secure();
    final keyBytes = List<int>.generate(32, (_) => random.nextInt(256));
    final secretKey = SecretKey(keyBytes);
    final nonce = _cipher.newNonce();

    final secretBox = await _cipher.encrypt(
      cleartext,
      secretKey: secretKey,
      nonce: nonce,
    );

    // Combine: 12-byte nonce + 16-byte mac + ciphertext
    final bb = BytesBuilder();
    bb.add(secretBox.nonce);
    bb.add(secretBox.mac.bytes);
    bb.add(secretBox.cipherText);
    final fullPayload = bb.toBytes();

    return {
      'payload': fullPayload,
      'key_b64': base64Encode(keyBytes),
    };
  }

  /// Decrypts media payload (12-byte nonce + 16-byte mac + ciphertext) using keyBase64
  static Future<Uint8List?> decryptMedia(Uint8List payload, String keyBase64) async {
    try {
      if (payload.length < 28) return null; // 12 + 16 = 28 min header

      final nonce = payload.sublist(0, 12);
      final mac = payload.sublist(12, 28);
      final cipherText = payload.sublist(28);

      final keyBytes = base64Decode(keyBase64);
      final secretKey = SecretKey(keyBytes);

      final secretBox = SecretBox(
        cipherText,
        nonce: nonce,
        mac: Mac(mac),
      );

      final decrypted = await _cipher.decrypt(
        secretBox,
        secretKey: secretKey,
      );

      return Uint8List.fromList(decrypted);
    } catch (e) {
      debugPrint('[MediaService] Decryption error: $e');
      return null;
    }
  }

  /// Uploads media by encrypting it locally and storing the blob in the vault
  static Future<Map<String, dynamic>?> uploadEncryptedMedia({
    required String token,
    required Uint8List fileBytes,
    required String mediaType, // 'image', 'voice', 'video', 'document'
    String? fileName,
    int? durationSec,
  }) async {
    try {
      final enc = await encryptMedia(fileBytes);
      final payload = enc['payload'] as Uint8List;
      final keyB64 = enc['key_b64'] as String;

      final res = await ApiService.uploadEncryptedBlob(
        token: token,
        ciphertext: payload,
      );

      if (res != null && res['media_id'] != null) {
        final mediaId = res['media_id'] as String;
        // Cache decrypted cleartext locally immediately
        _decryptedMemoryCache[mediaId] = fileBytes;

        return {
          'media_id': mediaId,
          'key_b64': keyB64,
          'media_type': mediaType,
          'file_name': fileName,
          'duration_sec': durationSec,
          'size': fileBytes.length,
        };
      }
      return null;
    } catch (e) {
      debugPrint('[MediaService] uploadEncryptedMedia error: $e');
      return null;
    }
  }

  /// Downloads encrypted blob and decrypts it with the provided key
  static Future<Uint8List?> getOrFetchMedia({
    required String token,
    required String mediaId,
    required String keyB64,
  }) async {
    if (_decryptedMemoryCache.containsKey(mediaId)) {
      return _decryptedMemoryCache[mediaId];
    }

    final encryptedBytes = await ApiService.downloadEncryptedBlob(
      token: token,
      mediaId: mediaId,
    );

    if (encryptedBytes == null) return null;

    final cleartext = await decryptMedia(encryptedBytes, keyB64);
    if (cleartext != null) {
      _decryptedMemoryCache[mediaId] = cleartext;
    }
    return cleartext;
  }
}
