class UserModel {
  final int id;
  final String username;
  final String displayName;
  final String role;
  final String avatarUrl;
  final bool isActive;
  final DateTime createdAt;

  UserModel({
    required this.id,
    required this.username,
    required this.displayName,
    this.role = 'member',
    this.avatarUrl = '',
    this.isActive = true,
    required this.createdAt,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      id: json['id'] is int ? json['id'] : int.tryParse(json['id']?.toString() ?? '0') ?? 0,
      username: json['username']?.toString() ?? '',
      displayName: json['display_name']?.toString() ?? (json['username']?.toString() ?? ''),
      role: json['role']?.toString() ?? 'member',
      avatarUrl: json['avatar_url']?.toString() ?? '',
      isActive: json['is_active'] == true || json['is_active'] == null,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'display_name': displayName,
      'role': role,
      'avatar_url': avatarUrl,
      'is_active': isActive,
      'created_at': createdAt.toIso8601String(),
    };
  }
}
