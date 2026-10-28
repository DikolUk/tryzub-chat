package com.tryzub.chat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.Uri

object Notifications {
    const val NOTIFICATION_ID_BACKGROUND_SERVICE = 1

    private const val CHANNEL_ID_BACKGROUND_SERVICE = "background_service"
    private const val CHANNEL_ID_INCOMING_CALLS = "incoming_calls"
    private const val CHANNEL_ID_MESSAGES = "messages"

    fun createNotificationChannels(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            
            // Delete existing channel first to ensure recreation with correct settings
            notificationManager.deleteNotificationChannel(CHANNEL_ID_INCOMING_CALLS)

            // Use default system ringtone for call notifications
            val callSoundUri: Uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)

            val audioAttributes = AudioAttributes.Builder()
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .build()

            // Incoming calls channel with custom sound
            val callChannel = NotificationChannel(
                CHANNEL_ID_INCOMING_CALLS,
                "Incoming Calls",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Notifications for incoming voice and video calls"
                setSound(callSoundUri, audioAttributes)
                enableVibration(true)
                enableLights(true)
                lightColor = android.graphics.Color.GREEN
                setShowBadge(true)
            }

            // Background service channel
            val backgroundChannel = NotificationChannel(
                CHANNEL_ID_BACKGROUND_SERVICE,
                "Background Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps app process on foreground"
                setSound(null, null) // No sound for background service
                enableVibration(false)
                enableLights(false)
            }

            // Messages channel with default sound
            val messageChannel = NotificationChannel(
                CHANNEL_ID_MESSAGES,
                "Messages",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "New message notifications"
                enableVibration(true)
                enableLights(true)
                setShowBadge(true)
            }

            // Create all channels
            notificationManager.createNotificationChannel(callChannel)
            notificationManager.createNotificationChannel(backgroundChannel)
            notificationManager.createNotificationChannel(messageChannel)
            
            // Log channel creation for debugging
            android.util.Log.d("Notifications", "Created channel: ${callChannel.id} with sound: ${callChannel.sound}")
        }
    }

    fun buildForegroundNotification(context: Context): Notification {
        return NotificationCompat
            .Builder(context, CHANNEL_ID_BACKGROUND_SERVICE)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Background Service")
            .setContentText("Keeps app process on foreground.")
            .build()
    }
}