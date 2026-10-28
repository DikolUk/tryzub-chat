class ChatMessage {
  final String id;
  final int senderId;
  final int recipientId;
  String text;
  final String type; // 'text' | 'media'
  final String? mediaType; // 'image' | 'voice' | 'document' | 'video'
  final String? mediaId;
  final String? mediaKeyB64;
  final int? mediaDuration; // in seconds for voice/video
  final String? fileName;
  final DateTime time;
  final bool isMe;
  String status; // 'sending' | 'sent' | 'delivered' | 'read'
  String? replyToId;
  String? replyToText;
  String? reaction;
  bool isDeleted;

  ChatMessage({
    required this.id,
    required this.senderId,
    required this.recipientId,
    required this.text,
    this.type = 'text',
    this.mediaType,
    this.mediaId,
    this.mediaKeyB64,
    this.mediaDuration,
    this.fileName,
    required this.time,
    required this.isMe,
    this.status = 'sent',
    this.replyToId,
    this.replyToText,
    this.reaction,
    this.isDeleted = false,
  });

  bool get isDelivered => status == 'delivered' || status == 'read';
  bool get isRead => status == 'read';

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id']?.toString() ?? '',
      senderId: json['sender_id'] is int ? json['sender_id'] : int.tryParse(json['sender_id']?.toString() ?? '0') ?? 0,
      recipientId: json['recipient_id'] is int ? json['recipient_id'] : int.tryParse(json['recipient_id']?.toString() ?? '0') ?? 0,
      text: json['text']?.toString() ?? '',
      type: json['type']?.toString() ?? 'text',
      mediaType: json['media_type']?.toString(),
      mediaId: json['media_id']?.toString(),
      mediaKeyB64: json['media_key_b64']?.toString(),
      mediaDuration: json['media_duration'] is int ? json['media_duration'] : int.tryParse(json['media_duration']?.toString() ?? '0'),
      fileName: json['file_name']?.toString(),
      time: json['time'] != null ? DateTime.tryParse(json['time'].toString()) ?? DateTime.now() : DateTime.now(),
      isMe: json['is_me'] == true,
      status: json['status']?.toString() ?? 'sent',
      replyToId: json['reply_to_id']?.toString(),
      replyToText: json['reply_to_text']?.toString(),
      reaction: json['reaction']?.toString(),
      isDeleted: json['is_deleted'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'sender_id': senderId,
      'recipient_id': recipientId,
      'text': text,
      'type': type,
      'media_type': mediaType,
      'media_id': mediaId,
      'media_key_b64': mediaKeyB64,
      'media_duration': mediaDuration,
      'file_name': fileName,
      'time': time.toIso8601String(),
      'is_me': isMe,
      'status': status,
      'reply_to_id': replyToId,
      'reply_to_text': replyToText,
      'reaction': reaction,
      'is_deleted': isDeleted,
    };
  }
}
