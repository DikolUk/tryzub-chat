import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../crypto/varta_crypto.dart';
import '../models/user.dart';
import 'api_service.dart';

class AuthProvider extends ChangeNotifier {
  UserModel? _currentUser;
  String? _token;
  String? _deviceId;
  bool _isLoading = false;

  UserModel? get currentUser => _currentUser;
  String? get token => _token;
  String? get deviceId => _deviceId;
  bool get isLoading => _isLoading;
  bool get isAuthenticated => _token != null && _currentUser != null;

  static const String _prefToken = 'varta_auth_token';
  static const String _prefUser = 'varta_auth_user';

  Future<void> tryAutoLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final savedToken = prefs.getString(_prefToken);
    final savedUser = prefs.getString(_prefUser);
    _deviceId = await VartaCrypto.getOrGenerateDeviceId();

    if (savedToken != null && savedUser != null) {
      try {
        _token = savedToken;
        _currentUser = UserModel.fromJson(jsonDecode(savedUser));
        notifyListeners();
      } catch (e) {
        await logout();
      }
    }
  }

  Future<Map<String, dynamic>> registerWithInvite({
    required String inviteToken,
    required String username,
    required String displayName,
    required String password,
  }) async {
    _isLoading = true;
    notifyListeners();

    try {
      final devId = await VartaCrypto.getOrGenerateDeviceId();
      final keyBundle = await VartaCrypto.generateInitialKeyBundle();

      final res = await ApiService.register(
        inviteToken: inviteToken,
        username: username,
        displayName: displayName,
        password: password,
        deviceId: devId,
        deviceName: 'Мобільний термінал',
        identityKey: keyBundle['identity_key'],
        signedPreKey: keyBundle['signed_prekey'],
        signedPreKeySig: keyBundle['signed_prekey_sig'],
        registrationId: keyBundle['registration_id'],
        oneTimePreKeys: (keyBundle['one_time_prekeys'] as List).cast<Map<String, dynamic>>(),
      );

      _isLoading = false;

      if (res['success'] == true) {
        final data = res['data'];
        _token = data['token'];
        _currentUser = UserModel.fromJson(data['user']);
        _deviceId = devId;

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefToken, _token!);
        await prefs.setString(_prefUser, jsonEncode(_currentUser!.toJson()));

        notifyListeners();
        return {'success': true};
      } else {
        notifyListeners();
        return {'success': false, 'error': res['error']};
      }
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      return {'success': false, 'error': 'Помилка генерації криптоключів: $e'};
    }
  }

  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async {
    _isLoading = true;
    notifyListeners();

    try {
      final devId = await VartaCrypto.getOrGenerateDeviceId();
      final res = await ApiService.login(
        username: username,
        password: password,
        deviceId: devId,
        deviceName: 'Мобільний термінал',
      );

      _isLoading = false;

      if (res['success'] == true) {
        final data = res['data'];
        _token = data['token'];
        _currentUser = UserModel.fromJson(data['user']);
        _deviceId = devId;

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefToken, _token!);
        await prefs.setString(_prefUser, jsonEncode(_currentUser!.toJson()));

        notifyListeners();
        return {'success': true};
      } else {
        notifyListeners();
        return {'success': false, 'error': res['error']};
      }
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      return {'success': false, 'error': 'Помилка авторизації: $e'};
    }
  }

  Future<void> logout() async {
    _currentUser = null;
    _token = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefToken);
    await prefs.remove(_prefUser);
    notifyListeners();
  }
}
