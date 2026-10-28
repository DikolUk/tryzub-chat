import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import '../core/constants/theme.dart';
import '../core/services/media_service.dart';

class VoiceBubble extends StatefulWidget {
  final String mediaId;
  final String keyB64;
  final int durationSec;
  final String token;
  final bool isMe;

  const VoiceBubble({
    super.key,
    required this.mediaId,
    required this.keyB64,
    required this.durationSec,
    required this.token,
    required this.isMe,
  });

  @override
  State<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<VoiceBubble> {
  final AudioPlayer _player = AudioPlayer();
  bool _isPlaying = false;
  bool _isLoading = false;
  Uint8List? _audioBytes;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _duration = Duration(seconds: widget.durationSec > 0 ? widget.durationSec : 0);

    _player.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state == PlayerState.playing;
        });
      }
    });

    _player.onPositionChanged.listen((p) {
      if (mounted) {
        setState(() {
          _position = p;
        });
      }
    });

    _player.onDurationChanged.listen((d) {
      if (mounted && d.inSeconds > 0) {
        setState(() {
          _duration = d;
        });
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    if (_isPlaying) {
      await _player.pause();
      return;
    }

    if (_audioBytes == null) {
      setState(() => _isLoading = true);
      final bytes = await MediaService.getOrFetchMedia(
        token: widget.token,
        mediaId: widget.mediaId,
        keyB64: widget.keyB64,
      );
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _audioBytes = bytes;
      });
      if (bytes == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не вдалося завантажити аудіо')),
        );
        return;
      }
    }

    try {
      await _player.play(BytesSource(_audioBytes!));
    } catch (e) {
      debugPrint('[VoiceBubble] Play error: $e');
    }
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final progress = _duration.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      constraints: const BoxConstraints(minWidth: 210, maxWidth: 280),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Play / Pause button
          InkWell(
            onTap: _isLoading ? null : _togglePlay,
            borderRadius: BorderRadius.circular(20),
            child: CircleAvatar(
              radius: 19,
              backgroundColor: widget.isMe ? AppTheme.accentGold : AppTheme.primaryBlue,
              child: _isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                    )
                  : Icon(
                      _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: widget.isMe ? Colors.black : Colors.white,
                      size: 22,
                    ),
            ),
          ),
          const SizedBox(width: 10),
          // Waveform / Progress Slider
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 4,
                    backgroundColor: Colors.white24,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      widget.isMe ? AppTheme.accentGold : AppTheme.primaryBlue,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatDuration(_position),
                      style: const TextStyle(fontSize: 10, color: AppTheme.textMuted),
                    ),
                    Text(
                      _formatDuration(_duration),
                      style: const TextStyle(fontSize: 10, color: AppTheme.textMuted),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
