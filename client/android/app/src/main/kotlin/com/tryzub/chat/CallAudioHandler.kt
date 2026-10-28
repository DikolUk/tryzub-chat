package com.tryzub.chat

import android.content.Context
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.AudioAttributes
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.IOException

/**
 * Senior Dev Solution: WebRTC-Compatible Audio Handler
 * Handles ringtone playback that works alongside WebRTC audio sessions
 */
class CallAudioHandler(private val context: Context) {
    
    companion object {
        private const val TAG = "CallAudioHandler"
    }
    
    private var mediaPlayer: MediaPlayer? = null
    private var audioManager: AudioManager? = null
    private var originalAudioMode: Int = AudioManager.MODE_NORMAL
    private var originalSpeakerphoneState: Boolean = false
    
    init {
        audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }
    
    /**
     * Release WebRTC audio session temporarily
     */
    fun releaseAudioSession(): Boolean {
        return try {
            Log.d(TAG, "Releasing WebRTC audio session temporarily...")
            
            // Store current audio state
            audioManager?.let { am ->
                originalAudioMode = am.mode
                originalSpeakerphoneState = am.isSpeakerphoneOn
                
                // Temporarily restore normal audio mode for ringtone
                am.mode = AudioManager.MODE_NORMAL
                Log.d(TAG, "Audio session temporarily released")
            }
            true
        } catch (e: Exception) {
            Log.w(TAG, "Failed to release audio session: ${e.message}")
            false
        }
    }
    
    /**
     * Reclaim WebRTC audio session after ringtone
     */
    fun reclaimAudioSession(): Boolean {
        return try {
            Log.d(TAG, "Reclaiming WebRTC audio session...")
            
            // Restore original WebRTC audio state
            audioManager?.let { am ->
                am.mode = originalAudioMode
                am.isSpeakerphoneOn = originalSpeakerphoneState
                Log.d(TAG, "Audio session reclaimed successfully")
            }
            true
        } catch (e: Exception) {
            Log.w(TAG, "Failed to reclaim audio session: ${e.message}")
            false
        }
    }
    
    /**
     * Play native ringtone that works with WebRTC
     */
    fun playNativeRingtone(assetPath: String, isVideoCall: Boolean, looping: Boolean, volume: Double): Boolean {
        return try {
            Log.d(TAG, "Starting native ringtone: $assetPath")
            
            // Stop any existing playback
            stopNativeRingtone()
            
            // Create new MediaPlayer
            mediaPlayer = MediaPlayer().apply {
                // Configure audio attributes for call compatibility
                val audioAttributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
                    
                setAudioAttributes(audioAttributes)
                
                // Load asset
                val assetManager = context.assets
                val afd = assetManager.openFd(assetPath.removePrefix("assets/"))
                setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
                afd.close()
                
                // Configure playback
                isLooping = looping
                setVolume(volume.toFloat(), volume.toFloat())
                
                // Prepare and start
                prepare()
                start()
                
                Log.d(TAG, "Native ringtone started successfully")
            }
            
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start native ringtone: ${e.message}")
            stopNativeRingtone()
            false
        }
    }
    
    /**
     * Stop native ringtone
     */
    fun stopNativeRingtone(): Boolean {
        return try {
            mediaPlayer?.let { mp ->
                if (mp.isPlaying) {
                    mp.stop()
                    Log.d(TAG, "Native ringtone stopped")
                }
                mp.release()
                mediaPlayer = null
            }
            true
        } catch (e: Exception) {
            Log.w(TAG, "Failed to stop native ringtone: ${e.message}")
            mediaPlayer?.release()
            mediaPlayer = null
            false
        }
    }
    
    /**
     * Cleanup resources
     */
    fun cleanup() {
        stopNativeRingtone()
        reclaimAudioSession()
    }
}