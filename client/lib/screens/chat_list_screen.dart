import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/constants/theme.dart';
import '../core/crypto/varta_crypto.dart';
import '../core/models/user.dart';
import '../core/services/api_service.dart';
import '../core/services/auth_provider.dart';
import '../core/services/socket_service.dart';
import '../core/utils/file_helper.dart';
import 'auth_screen.dart';
import 'chat_room_screen.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  List<UserModel> _users = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initConnection();
    _loadUsers();
  }

  void _initConnection() {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    if (auth.token != null) {
      final socket = Provider.of<SocketService>(context, listen: false);
      socket.connect(auth.token!);
    }
  }

  Future<void> _loadUsers() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    if (auth.token == null) return;

    setState(() => _isLoading = true);
    final users = await ApiService.getUsers(auth.token!);
    if (mounted) {
      setState(() {
        _users = users;
        _isLoading = false;
      });
    }
  }

  Future<void> _showMyRecoveryKey() async {
    final key = await VartaCrypto.getSavedRecoveryKey();
    if (key == null || !mounted) return;
    final formattedKey = VartaCrypto.formatRecoveryKey(key);

    void copyToClipboard(BuildContext ctx) {
      Clipboard.setData(ClipboardData(text: key));
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(
          backgroundColor: AppTheme.onlineGreen,
          content: Text('✓ 64-значний ключ скопійовано в буфер обміну!'),
          duration: Duration(seconds: 2),
        ),
      );
    }

    Future<void> saveToFile(BuildContext ctx) async {
      final auth = Provider.of<AuthProvider>(context, listen: false);
      final uname = auth.currentUser?.username ?? 'user';
      final content = "============================================================\n"
          "VARTA SECURE MESSENGER — 64-CHARACTER MASTER RECOVERY KEY\n"
          "============================================================\n\n"
          "USER: $uname\n"
          "SAVED: ${DateTime.now().toUtc().toIso8601String()}\n\n"
          "RAW KEY (64 HEX):\n$key\n\n"
          "FORMATTED:\n$formattedKey\n\n"
          "Keep this key secure and offline.\n"
          "============================================================\n";

      try {
        await downloadTextFile(filename: 'varta-recovery-key-$uname.txt', content: content);
        if (ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(
            const SnackBar(
              backgroundColor: AppTheme.onlineGreen,
              content: Text('✓ Файл ключа успішно завантажено!'),
            ),
          );
        }
      } catch (e) {
        if (ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(
            SnackBar(
              backgroundColor: AppTheme.errorRed,
              content: Text('Помилка збереження файлу: $e'),
            ),
          );
        }
      }
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.accentGold, width: 1.5),
        ),
        title: const Row(
          children: [
            Text('🔐', style: TextStyle(fontSize: 22)),
            SizedBox(width: 8),
            Text(
              'МІЙ КЛЮЧ ВІДНОВЛЕННЯ',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.1,
                color: AppTheme.accentGold,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'За допомогою цього 64-значного коду ви можете відновити доступ до ваших E2EE чатів на будь-якому новому пристрої:',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 14),

            // Tap-to-copy Key Container
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => copyToClipboard(context),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.bgDark,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.accentGold.withValues(alpha: 0.6)),
                ),
                child: Column(
                  children: [
                    SelectableText(
                      formattedKey,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.accentGold,
                        letterSpacing: 1.1,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.touch_app, size: 14, color: AppTheme.textMuted),
                        SizedBox(width: 4),
                        Text(
                          'Натисніть на ключ, щоб скопіювати',
                          style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),

            // Action Buttons (Copy & Download)
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.cardDark,
                      foregroundColor: AppTheme.textPrimary,
                      side: const BorderSide(color: AppTheme.dividerDark),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    icon: const Icon(Icons.copy, size: 16, color: AppTheme.accentGold),
                    label: const Text('Скопіювати', style: TextStyle(fontSize: 12)),
                    onPressed: () => copyToClipboard(context),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.cardDark,
                      foregroundColor: AppTheme.textPrimary,
                      side: const BorderSide(color: AppTheme.dividerDark),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    icon: const Icon(Icons.download, size: 16, color: AppTheme.accentGold),
                    label: const Text('Скачати файл', style: TextStyle(fontSize: 12)),
                    onPressed: () => saveToFile(context),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('ЗАКРИТИ', style: TextStyle(color: AppTheme.accentGold, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);
    final socket = Provider.of<SocketService>(context);
    final currentUser = auth.currentUser;

    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      appBar: AppBar(
        title: Row(
          children: [
            const Text('🛡️ VARTA'),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: socket.isConnected
                    ? AppTheme.onlineGreen.withValues(alpha: 0.18)
                    : AppTheme.errorRed.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: socket.isConnected ? AppTheme.onlineGreen : AppTheme.errorRed,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: socket.isConnected ? AppTheme.onlineGreen : AppTheme.errorRed,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    socket.isConnected ? 'ONLINE' : 'CONNECTING',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: socket.isConnected ? AppTheme.onlineGreen : AppTheme.errorRed,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.vpn_key_outlined, color: AppTheme.accentGold),
            onPressed: _showMyRecoveryKey,
            tooltip: 'Мій 64-значний ключ відновлення',
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: AppTheme.textMuted),
            onPressed: _loadUsers,
            tooltip: 'Оновити список',
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: AppTheme.errorRed),
            onPressed: () async {
              socket.disconnect();
              await auth.logout();
              if (context.mounted) {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (_) => const AuthScreen()),
                );
              }
            },
            tooltip: 'Вийти з мережі',
          ),
        ],
      ),
      body: Column(
        children: [
          // Security Status Banner
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: AppTheme.surfaceDark,
            child: Row(
              children: [
                const Icon(Icons.lock_rounded, color: AppTheme.accentGold, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'НАКРІЗНЕ ШИФРУВАННЯ E2EE АКТИВНЕ',
                        style: TextStyle(
                          color: AppTheme.accentGold,
                          fontWeight: FontWeight.w800,
                          fontSize: 11,
                          letterSpacing: 0.5,
                        ),
                      ),
                      Text(
                        'Ви: ${currentUser?.displayName ?? ''} (@${currentUser?.username ?? ''}) [${currentUser?.role.toUpperCase()}]',
                        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppTheme.dividerDark),

          // User / Dialog List
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: AppTheme.accentGold))
                : _users.isEmpty
                    ? const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.shield_outlined, size: 48, color: AppTheme.dividerDark),
                            SizedBox(height: 12),
                            Text(
                              'У закритій спільноті поки немає інших учасників',
                              style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
                            ),
                            SizedBox(height: 8),
                            Text(
                              'Згенеруйте інвайт в CMS-панелі для нових бійців',
                              style: TextStyle(color: AppTheme.accentGold, fontSize: 12),
                            ),
                          ],
                        ),
                      )
                    : ListView.separated(
                        itemCount: _users.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.dividerDark),
                        itemBuilder: (ctx, i) {
                          final user = _users[i];
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            leading: CircleAvatar(
                              radius: 22,
                              backgroundColor: AppTheme.cardDark,
                              child: Text(
                                user.displayName.isNotEmpty ? user.displayName[0].toUpperCase() : '?',
                                style: const TextStyle(
                                  color: AppTheme.accentGold,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            title: Row(
                              children: [
                                Text(
                                  user.displayName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                    color: AppTheme.textPrimary,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: AppTheme.cardDark,
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: AppTheme.dividerDark),
                                  ),
                                  child: Text(
                                    user.role,
                                    style: const TextStyle(
                                      color: AppTheme.accentGold,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            subtitle: Text(
                              '@${user.username} • 🔒 Захищений зв\'язок',
                              style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
                            ),
                            trailing: const Icon(Icons.chevron_right, color: AppTheme.textMuted),
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ChatRoomScreen(peerUser: user),
                                ),
                              );
                            },
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
