package com.tryzub.chat

import android.content.Intent
import android.provider.ContactsContract
import android.media.AudioManager
import android.content.Context
import android.os.Vibrator
import android.os.VibrationEffect
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CONTACTS_CHANNEL = "com.tryzub.chat/contacts"
    private val AUDIO_CHANNEL = "primocys.call.audio"
    private val NOTIFICATION_CHANNEL = "primocys.call.notification"
    private val DEVICE_PROFILE_CHANNEL = "primocys.device.profile"
    
    private lateinit var callAudioManager: CallAudioManager
    private lateinit var callAudioHandler: CallAudioHandler

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Notifications.createNotificationChannels(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Initialize CallAudioManager and CallAudioHandler
        val audioChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL)
        callAudioManager = CallAudioManager(this, audioChannel)
        callAudioHandler = CallAudioHandler(this)
        
        // Contacts channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CONTACTS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "addContact" -> {
                    val name = call.argument<String>("name")
                    val phone = call.argument<String>("phone")
                    
                    if (name != null && phone != null) {
                        addContactToDevice(name, phone)
                        result.success("Contact app opened")
                    } else {
                        result.error("INVALID_ARGUMENTS", "Name and phone are required", null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
        
        // Notification channel for ringer mode detection and vibration
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIFICATION_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getRingerMode" -> {
                    val ringerMode = getRingerMode()
                    result.success(ringerMode)
                }
                "startVibration" -> {
                    startVibration()
                    result.success(null)
                }
                "stopVibration" -> {
                    stopVibration()
                    result.success(null)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
        
        // Device profile channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_PROFILE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getRingerMode" -> {
                    val ringerMode = getRingerMode()
                    result.success(ringerMode)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
        
        // Audio channel
        audioChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "configureAudioForRingtone" -> {
                    callAudioManager.configureAudioForRingtone()
                    result.success(null)
                }
                "configureAudioForEarpiece" -> {
                    callAudioManager.configureAudioForEarpiece()
                    result.success(null)
                }
                "configureAudioForCall" -> {
                    val useSpeaker = call.argument<Boolean>("useSpeaker") ?: false
                    callAudioManager.configureAudioForCall(useSpeaker)
                    result.success(null)
                }
                "requestAudioFocus" -> {
                    val success = callAudioManager.requestAudioFocus()
                    result.success(success)
                }
                "releaseAudioFocus" -> {
                    callAudioManager.releaseAudioFocus()
                    result.success(null)
                }
                "playSystemRingtone" -> {
                    callAudioManager.playSystemRingtone()
                    result.success(null)
                }
                "stopSystemRingtone" -> {
                    callAudioManager.stopSystemRingtone()
                    result.success(null)
                }
                "playCustomCallRingtone" -> {
                    callAudioManager.playCustomCallRingtone()
                    result.success(null)
                }
                "stopCustomCallRingtone" -> {
                    callAudioManager.stopCustomCallRingtone()
                    result.success(null)
                }
                "setSpeakerphone" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    callAudioManager.setSpeakerphone(enabled)
                    result.success(null)
                }
                "restoreNormalAudio" -> {
                    callAudioManager.restoreNormalAudio()
                    result.success(null)
                }
                // SENIOR DEV: WebRTC Audio Session Management
                "releaseAudioSession" -> {
                    val success = callAudioHandler.releaseAudioSession()
                    result.success(success)
                }
                "reclaimAudioSession" -> {
                    val success = callAudioHandler.reclaimAudioSession()
                    result.success(success)
                }
                "playNativeRingtone" -> {
                    val assetPath = call.argument<String>("assetPath") ?: ""
                    val isVideoCall = call.argument<Boolean>("isVideoCall") ?: false
                    val looping = call.argument<Boolean>("looping") ?: true
                    val volume = call.argument<Double>("volume") ?: 0.8
                    
                    val success = callAudioHandler.playNativeRingtone(assetPath, isVideoCall, looping, volume)
                    result.success(success)
                }
                "stopNativeRingtone" -> {
                    val success = callAudioHandler.stopNativeRingtone()
                    result.success(success)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun addContactToDevice(name: String, phone: String) {
        val intent = Intent(Intent.ACTION_INSERT).apply {
            type = ContactsContract.Contacts.CONTENT_TYPE
            putExtra(ContactsContract.Intents.Insert.NAME, name)
            putExtra(ContactsContract.Intents.Insert.PHONE, phone)
            putExtra(ContactsContract.Intents.Insert.PHONE_TYPE, ContactsContract.CommonDataKinds.Phone.TYPE_MOBILE)
        }
        
        if (intent.resolveActivity(packageManager) != null) {
            startActivity(intent)
        }
    }

    private fun getRingerMode(): String {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        return when (audioManager.ringerMode) {
            AudioManager.RINGER_MODE_SILENT -> "silent"
            AudioManager.RINGER_MODE_VIBRATE -> "vibrate"
            AudioManager.RINGER_MODE_NORMAL -> "general"
            else -> "general"
        }
    }
    
    private fun startVibration() {
        val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // For API 26+, use VibrationEffect
            val vibrationPattern = longArrayOf(0, 500, 500, 500, 500, 500) // Pattern: wait, vibrate, wait, vibrate...
            val vibrationEffect = VibrationEffect.createWaveform(vibrationPattern, 1) // Repeat from index 1
            vibrator.vibrate(vibrationEffect)
        } else {
            // For older APIs, use deprecated method
            @Suppress("DEPRECATION")
            val vibrationPattern = longArrayOf(0, 500, 500, 500, 500, 500)
            vibrator.vibrate(vibrationPattern, 1) // Repeat from index 1
        }
    }
    
    private fun stopVibration() {
        val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        vibrator.cancel()
    }
}
