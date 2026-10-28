import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/constants/theme.dart';
import '../core/crypto/varta_crypto.dart';
import '../core/services/api_service.dart';
import '../core/services/auth_provider.dart';
import 'chat_list_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Register Form
  final _inviteCtrl = TextEditingController();
  final _regUsernameCtrl = TextEditingController();
  final _regDisplayNameCtrl = TextEditingController();
  final _regPasswordCtrl = TextEditingController();
  bool _isCheckingInvite = false;
  String? _inviteRole;

  // Login Form
  final _loginUsernameCtrl = TextEditingController();
  final _loginPasswordCtrl = TextEditingController();

  // Recovery Form
  final _recUsernameCtrl = TextEditingController();
  final _recPasswordCtrl = TextEditingController();
  final _recKeyCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _inviteCtrl.dispose();
    _regUsernameCtrl.dispose();
    _regDisplayNameCtrl.dispose();
    _regPasswordCtrl.dispose();
    _loginUsernameCtrl.dispose();
    _loginPasswordCtrl.dispose();
    _recUsernameCtrl.dispose();
    _recPasswordCtrl.dispose();
    _recKeyCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkInvite() async {
    final token = _inviteCtrl.text.trim();
    if (token.isEmpty) return;

    setState(() => _isCheckingInvite = true);
    final res = await ApiService.checkInvite(token);
    setState(() => _isCheckingInvite = false);

    if (res['valid'] == true) {
      setState(() => _inviteRole = res['role']);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppTheme.onlineGreen,
            content: Text('✓ Запрошення дійсне! Роль: ${res['role']}'),
          ),
        );
      }
    } else {
      setState(() => _inviteRole = null);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppTheme.errorRed,
            content: Text('✕ ${res['error'] ?? 'Недійсне запрошення'}'),
          ),
        );
      }
    }
  }

  Future<void> _submitRegister() async {
    final token = _inviteCtrl.text.trim();
    final username = _regUsernameCtrl.text.trim();
    final displayName = _regDisplayNameCtrl.text.trim();
    final password = _regPasswordCtrl.text;

    if (token.isEmpty || username.isEmpty || password.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: AppTheme.errorRed,
          content: Text('Заповніть усі поля. Пароль має містити щонайменше 8 символів.'),
        ),
      );
      return;
    }

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final res = await auth.registerWithInvite(
      inviteToken: token,
      username: username,
      displayName: displayName.isNotEmpty ? displayName : username,
      password: password,
    );

    if (res['success'] == true && mounted) {
      final recoveryKey = res['recovery_key'] as String?;
      if (recoveryKey != null) {
        await _showRecoveryKeyModal(recoveryKey);
      }
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const ChatListScreen()),
        );
      }
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppTheme.errorRed,
          content: Text('Помилка: ${res['error'] ?? 'Невідома помилка'}'),
        ),
      );
    }
  }

  Future<void> _submitLogin() async {
    final username = _loginUsernameCtrl.text.trim();
    final password = _loginPasswordCtrl.text;

    if (username.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: AppTheme.errorRed,
          content: Text('Введіть логін та пароль.'),
        ),
      );
      return;
    }

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final res = await auth.login(
      username: username,
      password: password,
    );

    if (res['success'] == true && mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const ChatListScreen()),
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppTheme.errorRed,
          content: Text('Помилка: ${res['error'] ?? 'Невірні дані'}'),
        ),
      );
    }
  }

  Future<void> _submitRecovery() async {
    final username = _recUsernameCtrl.text.trim();
    final password = _recPasswordCtrl.text;
    final recoveryKey = _recKeyCtrl.text.trim();

    if (username.isEmpty || password.isEmpty || recoveryKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: AppTheme.errorRed,
          content: Text('Заповніть усі поля форми відновлення.'),
        ),
      );
      return;
    }

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final res = await auth.recoverWithKey(
      username: username,
      password: password,
      recoveryKeyInput: recoveryKey,
    );

    if (res['success'] == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: AppTheme.onlineGreen,
          content: Text('✓ Акаунт та ключі E2EE успішно відновлено!'),
        ),
      );
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const ChatListScreen()),
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppTheme.errorRed,
          content: Text('Помилка: ${res['error'] ?? 'Не вдалося відновити акаунт'}'),
        ),
      );
    }
  }

  Future<void> _showRecoveryKeyModal(String key) async {
    bool hasSavedKey = false;
    final formattedKey = VartaCrypto.formatRecoveryKey(key);

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              backgroundColor: AppTheme.surfaceDark,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: AppTheme.accentGold, width: 1.5),
              ),
              title: const Row(
                children: [
                  Text('🔐', style: TextStyle(fontSize: 24)),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'КЛЮЧ ВІДНОВЛЕННЯ',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                        color: AppTheme.accentGold,
                      ),
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Обов\'язково збережіть цей 64-значний ключ у безпечному місці. Це єдиний спосіб відновити доступ до ваших чатів та шифрування у разі втрати або зміни пристрою!',
                      style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.4),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppTheme.bgDark,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppTheme.dividerDark),
                      ),
                      child: SelectableText(
                        formattedKey,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.accentGold,
                          letterSpacing: 1.1,
                          height: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.cardDark,
                        foregroundColor: AppTheme.textPrimary,
                        side: const BorderSide(color: AppTheme.dividerDark),
                      ),
                      icon: const Icon(Icons.copy, size: 16, color: AppTheme.accentGold),
                      label: const Text('Скопіювати 64-значний ключ', style: TextStyle(fontSize: 13)),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: key));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            backgroundColor: AppTheme.onlineGreen,
                            content: Text('✓ Ключ скопійовано в буфер обміну!'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: hasSavedKey,
                      activeColor: AppTheme.accentGold,
                      checkColor: Colors.black,
                      title: const Text(
                        'Я надійно зберіг(-ла) мій 64-значний ключ',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
                      ),
                      onChanged: (val) {
                        setModalState(() => hasSavedKey = val ?? false);
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: hasSavedKey ? AppTheme.accentGold : Colors.grey.shade800,
                    foregroundColor: Colors.black,
                  ),
                  onPressed: hasSavedKey
                      ? () => Navigator.of(ctx).pop()
                      : null,
                  child: const Text('УВІЙТИ В МЕСЕНДЖЕР', style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);

    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Brand Header
                Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [AppTheme.accentGold, AppTheme.primaryBlue],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.accentGold.withValues(alpha: 0.25),
                        blurRadius: 20,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: const Center(
                    child: Text('🛡️', style: TextStyle(fontSize: 32)),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'VARTA',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'НАКРІЗНЕ ШИФРУВАННЯ ДЛЯ ЗАКРИТИХ СПІЛЬНОТ',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                    color: AppTheme.accentGold,
                  ),
                ),
                const SizedBox(height: 24),

                // Tabs Container
                Container(
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceDark,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.dividerDark),
                  ),
                  child: TabBar(
                    controller: _tabController,
                    indicatorColor: AppTheme.accentGold,
                    indicatorWeight: 3,
                    labelColor: AppTheme.accentGold,
                    unselectedLabelColor: AppTheme.textMuted,
                    labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                    tabs: const [
                      Tab(text: 'Вхід'),
                      Tab(text: 'Реєстрація'),
                      Tab(text: 'Відновлення'),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Tab Views
                SizedBox(
                  height: 400,
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      // 1. Login View
                      _buildLoginView(auth.isLoading),

                      // 2. Register View
                      _buildRegisterView(auth.isLoading),

                      // 3. Recovery View
                      _buildRecoveryView(auth.isLoading),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoginView(bool isLoading) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _loginUsernameCtrl,
          decoration: const InputDecoration(
            labelText: 'Логін користувача',
            prefixIcon: Icon(Icons.person_outline, color: AppTheme.textMuted),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _loginPasswordCtrl,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Пароль',
            prefixIcon: Icon(Icons.lock_outline, color: AppTheme.textMuted),
          ),
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: isLoading ? null : _submitLogin,
          child: isLoading
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2),
                )
              : const Text('УВІЙТИ В МЕРЕЖУ VARTA'),
        ),
        const SizedBox(height: 12),
        const Text(
          '🔒 Сесія захищена локальним криптографічним ключем пристрою',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
        ),
      ],
    );
  }

  Widget _buildRegisterView(bool isLoading) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _inviteCtrl,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    labelText: 'Токен одноразового інвайту',
                    hintText: 'VARTA-XXXX-XXXX',
                    prefixIcon: const Icon(Icons.vpn_key_outlined, color: AppTheme.accentGold),
                    suffixIcon: _inviteRole != null
                        ? const Icon(Icons.check_circle, color: AppTheme.onlineGreen)
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: _isCheckingInvite
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.verified, color: AppTheme.accentGold),
                tooltip: 'Перевірити дійсність',
                onPressed: _isCheckingInvite ? null : _checkInvite,
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _regUsernameCtrl,
            decoration: const InputDecoration(
              labelText: 'Бажаний логін (латиниця)',
              prefixIcon: Icon(Icons.account_circle_outlined, color: AppTheme.textMuted),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _regDisplayNameCtrl,
            decoration: const InputDecoration(
              labelText: 'Позивний / Ім\'я',
              prefixIcon: Icon(Icons.badge_outlined, color: AppTheme.textMuted),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _regPasswordCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Пароль (від 8 символів)',
              prefixIcon: Icon(Icons.lock_outline, color: AppTheme.textMuted),
            ),
          ),
          const SizedBox(height: 18),
          ElevatedButton(
            onPressed: isLoading ? null : _submitRegister,
            child: isLoading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2),
                  )
                : const Text('ЗГЕНЕРУВАТИ КЛЮЧІ ТА ЗАРЕЄСТРУВАТИСЬ'),
          ),
        ],
      ),
    );
  }

  Widget _buildRecoveryView(bool isLoading) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _recUsernameCtrl,
            decoration: const InputDecoration(
              labelText: 'Логін користувача',
              prefixIcon: Icon(Icons.person_outline, color: AppTheme.textMuted),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _recPasswordCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Пароль',
              prefixIcon: Icon(Icons.lock_outline, color: AppTheme.textMuted),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _recKeyCtrl,
            maxLines: 2,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
              labelText: '64-значний ключ відновлення',
              hintText: 'A8F4-1C9D-E342-... (або 64 hex символи)',
              prefixIcon: Icon(Icons.vpn_key, color: AppTheme.accentGold),
            ),
          ),
          const SizedBox(height: 18),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentGold,
              foregroundColor: Colors.black,
            ),
            onPressed: isLoading ? null : _submitRecovery,
            child: isLoading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2),
                  )
                : const Text('🔓 ВІДНОВИТИ АКАУНТ ТА КЛЮЧІ', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
          const SizedBox(height: 10),
          const Text(
            '🔑 Відновлює ваші E2EE ключі шифрування на цьому пристрої за 64-значним майстер-кодом',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
          ),
        ],
      ),
    );
  }
}
