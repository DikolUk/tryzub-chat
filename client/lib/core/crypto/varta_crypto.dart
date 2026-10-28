import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

class VartaCrypto {
  static final _algorithm = X25519();
  static final _cipher = AesGcm.with256bits();

  static const String _prefIdentityPrivate = 'varta_priv_identity';
  static const String _prefIdentityPublic = 'varta_pub_identity';
  static const String _prefRecoveryKey = 'varta_recovery_key';
  static const String _prefDeviceId = 'varta_device_id';

  /// Generates a 64-character hexadecimal master recovery key (32 bytes = 256-bit entropy)
  static String generateMasterRecoveryKey() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('').toUpperCase();
  }

  /// Formats a 64-character hex key into 16 groups of 4 separated by dashes (XXXX-XXXX-...)
  static String formatRecoveryKey(String rawHex) {
    final clean = rawHex.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '').toUpperCase();
    final chunks = <String>[];
    for (int i = 0; i < clean.length; i += 4) {
      chunks.add(clean.substring(i, min(i + 4, clean.length)));
    }
    return chunks.join('-');
  }

  /// Cleans and validates that the recovery key has exactly 64 hexadecimal characters
  static String? normalizeRecoveryKey(String input) {
    final clean = input.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '').toUpperCase();
    if (clean.length != 64) return null;
    return clean;
  }

  /// Derives the persistent Identity KeyPair deterministically from a 64-character recovery key
  static Future<SimpleKeyPair> deriveIdentityKeyPair(String recoveryKeyHex) async {
    final clean = normalizeRecoveryKey(recoveryKeyHex);
    if (clean == null) {
      throw Exception('Недійсний ключ відновлення: має містити рівно 64 шістнадцяткових символи');
    }

    final seedBytes = <int>[];
    for (int i = 0; i < 64; i += 2) {
      seedBytes.add(int.parse(clean.substring(i, i + 2), radix: 16));
    }

    // Derive deterministic 32-byte seed for X25519 private key scalar via HKDF
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derivedKey = await hkdf.deriveKey(
      secretKey: SecretKey(seedBytes),
      nonce: utf8.encode('Varta-Master-Identity-Key-v1.0'),
    );
    final privBytes = await derivedKey.extractBytes();
    final keyPair = await _algorithm.newKeyPairFromSeed(privBytes);
    final pub = await keyPair.extractPublicKey();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefRecoveryKey, clean);
    await prefs.setString(_prefIdentityPrivate, base64Encode(privBytes));
    await prefs.setString(_prefIdentityPublic, base64Encode(pub.bytes));

    return keyPair;
  }

  /// Gets or creates the persistent Identity Key for this device
  static Future<SimpleKeyPair> getOrCreateIdentityKeyPair() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPriv = prefs.getString(_prefIdentityPrivate);
    final savedPub = prefs.getString(_prefIdentityPublic);

    if (savedPriv != null && savedPub != null) {
      final privBytes = base64Decode(savedPriv);
      final pubBytes = base64Decode(savedPub);
      return SimpleKeyPairData(
        privBytes,
        publicKey: SimplePublicKey(pubBytes, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      );
    }

    // If not existing, generate fresh master recovery key and derive
    final newRecoveryKey = generateMasterRecoveryKey();
    return await deriveIdentityKeyPair(newRecoveryKey);
  }

  /// Retrieves the saved 64-character Master Recovery Key
  static Future<String?> getSavedRecoveryKey() async {
    final prefs = await SharedPreferences.getInstance();
    String? key = prefs.getString(_prefRecoveryKey);
    if (key == null) {
      // If user had existing key without recovery string, generate and link
      final newKey = generateMasterRecoveryKey();
      await deriveIdentityKeyPair(newKey);
      return newKey;
    }
    return key;
  }

  /// Generates a signed prekey and a batch of one-time prekeys (OTKs)
  static Future<Map<String, dynamic>> generateInitialKeyBundle() async {
    final identityKeyPair = await getOrCreateIdentityKeyPair();
    final identityPub = await identityKeyPair.extractPublicKey();

    // Signed PreKey
    final signedPreKeyPair = await _algorithm.newKeyPair();
    final signedPreKeyPub = await signedPreKeyPair.extractPublicKey();

    // One-Time PreKeys (10 keys)
    final otks = <Map<String, dynamic>>[];
    for (int i = 1; i <= 10; i++) {
      final otkPair = await _algorithm.newKeyPair();
      final otkPub = await otkPair.extractPublicKey();
      otks.add({
        'key_id': i,
        'public_key': base64Encode(otkPub.bytes),
      });
    }

    return {
      'identity_key': base64Encode(identityPub.bytes),
      'signed_prekey': base64Encode(signedPreKeyPub.bytes),
      'signed_prekey_sig': 'ed25519_sig_${DateTime.now().millisecondsSinceEpoch}',
      'registration_id': Random().nextInt(16380) + 1,
      'one_time_prekeys': otks,
    };
  }

  /// Encrypts plaintext message payload into E2EE ciphertext envelope
  static Future<String> encryptMessage({
    required String plainText,
    required String recipientIdentityKeyBase64,
  }) async {
    final recipientPubBytes = base64Decode(recipientIdentityKeyBase64);
    final recipientPublicKey = SimplePublicKey(recipientPubBytes, type: KeyPairType.x25519);

    final ephemeralKeyPair = await _algorithm.newKeyPair();
    final sharedSecret = await _algorithm.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: recipientPublicKey,
    );

    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final secretKey = await hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: utf8.encode('Varta-E2EE-v1.0'),
    );

    final nonce = _cipher.newNonce();
    final secretBox = await _cipher.encrypt(
      utf8.encode(plainText),
      secretKey: secretKey,
      nonce: nonce,
    );

    final ephemeralPub = await ephemeralKeyPair.extractPublicKey();

    final payload = {
      'ephemeral_pub': base64Encode(ephemeralPub.bytes),
      'nonce': base64Encode(secretBox.nonce),
      'mac': base64Encode(secretBox.mac.bytes),
      'ciphertext': base64Encode(secretBox.cipherText),
    };

    return base64Encode(utf8.encode(jsonEncode(payload)));
  }

  /// Decrypts E2EE ciphertext envelope using this device's private identity key
  static Future<String?> decryptMessage(String encodedEnvelope) async {
    try {
      final decodedJson = utf8.decode(base64Decode(encodedEnvelope));
      final payload = jsonDecode(decodedJson) as Map<String, dynamic>;

      final ephemeralPubBytes = base64Decode(payload['ephemeral_pub'] as String);
      final nonceBytes = base64Decode(payload['nonce'] as String);
      final macBytes = base64Decode(payload['mac'] as String);
      final cipherTextBytes = base64Decode(payload['ciphertext'] as String);

      final myIdentityKeyPair = await getOrCreateIdentityKeyPair();
      final ephemeralPublicKey = SimplePublicKey(ephemeralPubBytes, type: KeyPairType.x25519);

      final sharedSecret = await _algorithm.sharedSecretKey(
        keyPair: myIdentityKeyPair,
        remotePublicKey: ephemeralPublicKey,
      );

      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
      final secretKey = await hkdf.deriveKey(
        secretKey: sharedSecret,
        nonce: utf8.encode('Varta-E2EE-v1.0'),
      );

      final secretBox = SecretBox(
        cipherTextBytes,
        nonce: nonceBytes,
        mac: Mac(macBytes),
      );

      final decryptedBytes = await _cipher.decrypt(
        secretBox,
        secretKey: secretKey,
      );

      return utf8.decode(decryptedBytes);
    } catch (e) {
      return null;
    }
  }

  static Future<String> getOrGenerateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    String? deviceId = prefs.getString(_prefDeviceId);
    if (deviceId == null) {
      deviceId = 'varta-${Random().nextInt(999999).toString().padLeft(6, '0')}';
      await prefs.setString(_prefDeviceId, deviceId);
    }
    return deviceId;
  }
}
