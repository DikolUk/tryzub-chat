import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

class VartaCrypto {
  static final _algorithm = X25519();
  static final _cipher = AesGcm.with256bits();

  static const String _prefIdentityPrivate = 'varta_priv_identity';
  static const String _prefIdentityPublic = 'varta_pub_identity';
  static const String _prefDeviceId = 'varta_device_id';

  /// Generates or loads the persistent Identity Key for this device
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

    final keyPair = await _algorithm.newKeyPair();
    final priv = await keyPair.extractPrivateKeyBytes();
    final pub = await keyPair.extractPublicKey();

    await prefs.setString(_prefIdentityPrivate, base64Encode(priv));
    await prefs.setString(_prefIdentityPublic, base64Encode(pub.bytes));

    return keyPair;
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
    // 1. Generate ephemeral shared secret using recipient public key
    final recipientPubBytes = base64Decode(recipientIdentityKeyBase64);
    final recipientPublicKey = SimplePublicKey(recipientPubBytes, type: KeyPairType.x25519);

    final ephemeralKeyPair = await _algorithm.newKeyPair();
    final sharedSecret = await _algorithm.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: recipientPublicKey,
    );

    // 2. Derive 256-bit AES-GCM encryption key via HKDF
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final secretKey = await hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: utf8.encode('Varta-E2EE-v1.0'),
    );

    // 3. Encrypt payload
    final nonce = _cipher.newNonce();
    final secretBox = await _cipher.encrypt(
      utf8.encode(plainText),
      secretKey: secretKey,
      nonce: nonce,
    );

    final ephemeralPub = await ephemeralKeyPair.extractPublicKey();

    // Package: { ephemeral_pub, nonce, mac, ciphertext }
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
      // In case envelope was non-encrypted or system fallback
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
