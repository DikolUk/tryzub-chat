import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../core/constants/theme.dart';
import '../core/services/media_service.dart';

class ImageBubble extends StatefulWidget {
  final String mediaId;
  final String keyB64;
  final String token;
  final bool isMe;

  const ImageBubble({
    super.key,
    required this.mediaId,
    required this.keyB64,
    required this.token,
    required this.isMe,
  });

  @override
  State<ImageBubble> createState() => _ImageBubbleState();
}

class _ImageBubbleState extends State<ImageBubble> {
  Uint8List? _imageBytes;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      final bytes = await MediaService.getOrFetchMedia(
        token: widget.token,
        mediaId: widget.mediaId,
        keyB64: widget.keyB64,
      );
      if (!mounted) return;
      if (bytes != null) {
        setState(() {
          _imageBytes = bytes;
          _isLoading = false;
        });
      } else {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  void _openFullScreen() {
    if (_imageBytes == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            iconTheme: const IconThemeData(color: Colors.white),
            title: const Text('Захищене фото', style: TextStyle(color: Colors.white, fontSize: 16)),
          ),
          body: Center(
            child: InteractiveViewer(
              child: Image.memory(_imageBytes!),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        width: 220,
        height: 180,
        decoration: BoxDecoration(
          color: AppTheme.cardDark,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accentGold),
              SizedBox(height: 8),
              Text(
                'Дешифрування E2EE...',
                style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
              ),
            ],
          ),
        ),
      );
    }

    if (_hasError || _imageBytes == null) {
      return Container(
        width: 200,
        height: 120,
        decoration: BoxDecoration(
          color: AppTheme.cardDark,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.broken_image_rounded, color: Colors.redAccent, size: 30),
              SizedBox(height: 6),
              Text(
                'Помилка завантаження фото',
                style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
              ),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: _openFullScreen,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 260, maxHeight: 320),
          child: Image.memory(
            _imageBytes!,
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }
}
