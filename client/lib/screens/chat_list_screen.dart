import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/constants/theme.dart';
import '../core/models/user.dart';
import '../core/services/api_service.dart';
import '../core/services/auth_provider.dart';
import '../core/services/socket_service.dart';
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
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.shield_outlined, size: 48, color: AppTheme.dividerDark),
                            const SizedBox(height: 12),
                            const Text(
                              'У закритій спільноті поки немає інших учасників',
                              style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
                            ),
                            const SizedBox(height: 8),
                            const Text(
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
