// =============================================================================
// Native Android Audio Manager for Call Experience
// Handles audio routing, focus management, and ringtone playback
// =============================================================================

package com.tryzub.chat

import android.content.Context
import android.media.AudioManager
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.io.IOException

class CallAudioManager(private val context: Context, private val channel: MethodChannel?) {
    
    companion object {
        private const val TAG = "CallAudioManager"
        
        // Audio focus types
        private const val AUDIOFOCUS_GAIN = 1
        private const val AUDIOFOCUS_LOSS = -1
        private const val AUDIOFOCUS_LOSS_TRANSIENT = -2
        private const val AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK = -3
    }
    
    private val audioManager: AudioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var systemRingtonePlayer: MediaPlayer? = null
    private var customRingtonePlayer: MediaPlayer? = null
    private var originalAudioMode: Int = AudioManager.MODE_NORMAL
    private var originalSpeakerState: Boolean = false
    
    // Audio focus listener
    private val afChangeListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        Log.d(TAG, "Audio focus changed: $focusChange")
        
        // Notify Flutter side about focus change (if channel is available)
        channel?.invokeMethod("onAudioFocusChange", focusChange)
        
        when (focusChange) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                // Permanent loss - stop all audio and clear communication device (PR #1410 fix)
                Log.d(TAG, "Audio focus lost - stopping audio and clearing communication device")
                stopSystemRingtone()
                stopCustomCallRingtone()
                clearCommunicationDevice()
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                // Temporary loss - pause audio
                pauseSystemRingtone()
                pauseCustomCallRingtone()
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                // Can duck - lower volume or pause
                pauseSystemRingtone()
                pauseCustomCallRingtone()
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                // Regained focus - resume if needed
                resumeSystemRingtone()
                resumeCustomCallRingtone()
            }
        }
    }
    
    /**
     * Configure audio for ringtone playback (loudspeaker)
     */
    fun configureAudioForRingtone() {
        try {
            Log.d(TAG, "Configuring audio for ringtone...")
            
            // Save current state
            originalAudioMode = audioManager.mode
            originalSpeakerState = audioManager.isSpeakerphoneOn
            
            // Set ringtone mode
            audioManager.mode = AudioManager.MODE_RINGTONE
            audioManager.isSpeakerphoneOn = true
            
            // Increase ringtone volume
            val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_RING)
            val currentVolume = audioManager.getStreamVolume(AudioManager.STREAM_RING)
            
            if (currentVolume < maxVolume * 0.8) {
                audioManager.setStreamVolume(
                    AudioManager.STREAM_RING,
                    (maxVolume * 0.8).toInt(),
                    0
                )
            }
            
            Log.d(TAG, "Audio configured for ringtone")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to configure audio for ringtone", e)
        }
    }
    
    /**
     * Configure audio for earpiece (caller side)
     */
    fun configureAudioForEarpiece() {
        try {
            Log.d(TAG, "Configuring audio for earpiece...")
            
            // Save current state
            originalAudioMode = audioManager.mode
            originalSpeakerState = audioManager.isSpeakerphoneOn
            
            // Set call mode for earpiece
            audioManager.mode = AudioManager.MODE_IN_CALL
            audioManager.isSpeakerphoneOn = false
            
            // Route audio to earpiece
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioManager.setMode(AudioManager.MODE_IN_COMMUNICATION)
            }
            
            Log.d(TAG, "Audio configured for earpiece")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to configure audio for earpiece", e)
        }
    }
    
    /**
     * Configure audio for in-call
     */
    fun configureAudioForCall(useSpeaker: Boolean) {
        try {
            Log.d(TAG, "Configuring audio for call (speaker: $useSpeaker)...")
            
            // Set call mode
            audioManager.mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                AudioManager.MODE_IN_COMMUNICATION
            } else {
                AudioManager.MODE_IN_CALL
            }
            
            // Set speaker state
            audioManager.isSpeakerphoneOn = useSpeaker
            
            Log.d(TAG, "Audio configured for call")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to configure audio for call", e)
        }
    }
    
    /**
     * Request audio focus
     */
    fun requestAudioFocus(): Boolean {
        return try {
            @Suppress("DEPRECATION")
            val result = audioManager.requestAudioFocus(
                afChangeListener,
                AudioManager.STREAM_VOICE_CALL,
                AudioManager.AUDIOFOCUS_GAIN
            )
            
            val success = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            Log.d(TAG, "Audio focus request result: $success")
            success
        } catch (e: Exception) {
            Log.e(TAG, "Failed to request audio focus", e)
            false
        }
    }
    
    /**
     * Release audio focus
     */
    fun releaseAudioFocus() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                // For API 26+, we would need to store the focus request object
                // For now, use the deprecated method
                @Suppress("DEPRECATION")
                audioManager.abandonAudioFocus(afChangeListener)
            } else {
                @Suppress("DEPRECATION")
                audioManager.abandonAudioFocus(afChangeListener)
            }
            
            Log.d(TAG, "Audio focus released")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to release audio focus", e)
        }
    }
    
    /**
     * Play system ringtone
     */
    fun playSystemRingtone() {
        try {
            stopSystemRingtone() // Stop any existing ringtone
            
            val ringtoneUri: Uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
                ?: return
            
            systemRingtonePlayer = MediaPlayer().apply {
                setDataSource(context, ringtoneUri)
                
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build()
                    )
                } else {
                    @Suppress("DEPRECATION")
                    setAudioStreamType(AudioManager.STREAM_RING)
                }
                
                isLooping = true
                prepare()
                start()
            }
            
            Log.d(TAG, "System ringtone started")
        } catch (e: IOException) {
            Log.e(TAG, "Failed to play system ringtone", e)
        }
    }
    
    /**
     * Stop system ringtone
     */
    fun stopSystemRingtone() {
        try {
            systemRingtonePlayer?.let { player ->
                if (player.isPlaying) {
                    player.stop()
                }
                player.release()
                systemRingtonePlayer = null
            }
            
            Log.d(TAG, "System ringtone stopped")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to stop system ringtone", e)
        }
    }
    
    /**
     * Play device default ringtone (no custom ringtone)
     */
    fun playCustomCallRingtone() {
        try {
            Log.d(TAG, "Playing device default ringtone for call...")
            // Always use device default ringtone instead of custom file
            playSystemRingtone()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to play default ringtone", e)
            // Fallback to system ringtone
            playSystemRingtone()
        }
    }
    
    /**
     * Stop default ringtone (now delegates to system ringtone)
     */
    fun stopCustomCallRingtone() {
        try {
            // Since we now use system ringtone, delegate to system ringtone stop
            stopSystemRingtone()
            Log.d(TAG, "Default ringtone stopped")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to stop default ringtone", e)
        }
    }
    
    /**
     * Pause system ringtone
     */
    private fun pauseSystemRingtone() {
        try {
            systemRingtonePlayer?.let { player ->
                if (player.isPlaying) {
                    player.pause()
                    Log.d(TAG, "System ringtone paused")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to pause system ringtone", e)
        }
    }
    
    /**
     * Resume system ringtone
     */
    private fun resumeSystemRingtone() {
        try {
            systemRingtonePlayer?.let { player ->
                if (!player.isPlaying) {
                    player.start()
                    Log.d(TAG, "System ringtone resumed")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to resume system ringtone", e)
        }
    }
    
    /**
     * Pause custom call ringtone
     */
    private fun pauseCustomCallRingtone() {
        try {
            customRingtonePlayer?.let { player ->
                if (player.isPlaying) {
                    player.pause()
                    Log.d(TAG, "Custom call ringtone paused")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to pause custom call ringtone", e)
        }
    }
    
    /**
     * Resume custom call ringtone
     */
    private fun resumeCustomCallRingtone() {
        try {
            customRingtonePlayer?.let { player ->
                if (!player.isPlaying) {
                    player.start()
                    Log.d(TAG, "Custom call ringtone resumed")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to resume custom call ringtone", e)
        }
    }
    
    /**
     * Set speakerphone state
     */
    fun setSpeakerphone(enabled: Boolean) {
        try {
            audioManager.isSpeakerphoneOn = enabled
            Log.d(TAG, "Speakerphone set to: $enabled")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to set speakerphone", e)
        }
    }
    
    /**
     * Restore normal audio settings
     */
    fun restoreNormalAudio() {
        try {
            Log.d(TAG, "Restoring normal audio...")
            
            // Stop any playing ringtone
            stopSystemRingtone()
            stopCustomCallRingtone()
            
            // CRITICAL: Clear communication device first (flutter-webrtc PR #1410 fix)
            clearCommunicationDevice()
            
            // FIXED: Force audio mode to NORMAL and speaker to OFF for complete cleanup
            audioManager.mode = AudioManager.MODE_NORMAL
            audioManager.isSpeakerphoneOn = false
            
            // Small delay to ensure mode change is processed
            Thread.sleep(150)
            
            // CRITICAL: For call cleanup, NEVER restore speaker state to avoid audio continuation
            // Always keep speaker OFF and mode NORMAL after call cleanup
            Log.d(TAG, "Audio forced to NORMAL mode with speaker OFF for complete cleanup")
            Log.d(TAG, "Skipping original state restoration to prevent audio continuation issues")
            
            // Release audio focus
            releaseAudioFocus()
            
            Log.d(TAG, "Normal audio restored")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to restore normal audio", e)
        }
    }
    
    /**
     * Clear the active communication device (flutter-webrtc PR #1410 fix)
     * This helps return to original audio stream after WebRTC session completes
     */
    private fun clearCommunicationDevice() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // For API 31+, clear the communication device
                audioManager.clearCommunicationDevice()
                Log.d(TAG, "Communication device cleared (API 31+)")
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                // For API 23-30, reset audio routing by setting mode back to normal
                // This helps clear any active communication routing
                val currentMode = audioManager.mode
                audioManager.mode = AudioManager.MODE_NORMAL
                
                // FIXED: Use Handler.postDelayed instead of Thread.sleep to prevent blocking
                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                    try {
                        // Only restore mode if it's still different from normal
                        if (audioManager.mode == AudioManager.MODE_NORMAL && currentMode != AudioManager.MODE_NORMAL) {
                            // Keep in normal mode for complete cleanup
                            Log.d(TAG, "Keeping audio in normal mode for complete cleanup")
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "Error in delayed audio mode cleanup: $e")
                    }
                }, 100) // Increased delay for better processing
                
                Log.d(TAG, "Audio routing reset (API 23-30)")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to clear communication device: $e")
            // Continue with normal cleanup even if this fails
        }
    }
}