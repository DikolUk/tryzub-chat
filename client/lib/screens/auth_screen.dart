import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/constants/theme.dart';
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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
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
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const ChatListScreen()),
      );
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
                        color: AppTheme.accentGold.withOpacity(0.3),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: const Center(
                    child: Text('🛡️', style: TextStyle(fontSize: 34)),
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
                const SizedBox(height: 28),

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
                    labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                    tabs: const [
                      Tab(text: 'Вхід за паролем'),
                      Tab(text: 'Реєстрація за інвайтом'),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Tab Views
                SizedBox(
                  height: 380,
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      // 1. Login View
                      _buildLoginView(auth.isLoading),

                      // 2. Register View
                      _buildRegisterView(auth.isLoading),
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
              labelText: 'Бажаний логін (тільки латиниця)',
              prefixIcon: Icon(Icons.account_circle_outlined, color: AppTheme.textMuted),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _regDisplayNameCtrl,
            decoration: const InputDecoration(
              labelText: 'Позивний / Відображуване ім\'я',
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
}
