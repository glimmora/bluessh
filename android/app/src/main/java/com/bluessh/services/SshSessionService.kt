package com.bluessh.services

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.bluessh.R
import com.bluessh.core.SshSession
import com.bluessh.ui.MainActivity
import kotlinx.coroutines.*

/**
 * Foreground service to keep SSH sessions alive
 * Shows persistent notification during active sessions
 */
class SshSessionService : Service() {
    
    private val binder = LocalBinder()
    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val activeSessions = mutableMapOf<String, SshSession>()
    
    companion object {
        const val CHANNEL_ID = "bluessh_session"
        const val NOTIFICATION_ID = 1
        const val ACTION_ADD_SESSION = "com.bluessh.ADD_SESSION"
        const val ACTION_REMOVE_SESSION = "com.bluessh.REMOVE_SESSION"
        const val EXTRA_SESSION_ID = "session_id"
        const val EXTRA_SESSION_HOST = "session_host"
    }
    
    inner class LocalBinder : Binder() {
        fun getService(): SshSessionService = this@SshSessionService
    }
    
    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_ADD_SESSION -> {
                val sessionId = intent.getStringExtra(EXTRA_SESSION_ID) ?: return START_STICKY
                val host = intent.getStringExtra(EXTRA_SESSION_HOST) ?: "unknown"
                addSession(sessionId, host)
            }
            ACTION_REMOVE_SESSION -> {
                val sessionId = intent.getStringExtra(EXTRA_SESSION_ID) ?: return START_STICKY
                removeSession(sessionId)
            }
        }
        
        return START_STICKY
    }
    
    override fun onBind(intent: Intent?): IBinder {
        return binder
    }
    
    override fun onDestroy() {
        serviceScope.cancel()
        activeSessions.clear()
        super.onDestroy()
    }
    
    /**
     * Add a session to the service
     */
    fun addSession(sessionId: String, host: String) {
        activeSessions[sessionId] = SshSession(
            id = sessionId,
            sshSession = null as org.apache.sshd.client.session.ClientSession, // Placeholder
            config = com.bluessh.core.ConnectionConfig()
        )
        updateNotification()
    }
    
    /**
     * Remove a session from the service
     */
    fun removeSession(sessionId: String) {
        activeSessions.remove(sessionId)
        
        if (activeSessions.isEmpty()) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        } else {
            updateNotification()
        }
    }
    
    /**
     * Get active session count
     */
    fun getActiveSessionCount(): Int = activeSessions.size
    
    /**
     * Create notification channel
     */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "SSH Sessions",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Active SSH session notifications"
                setShowBadge(false)
            }
            
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.createNotificationChannel(channel)
        }
    }
    
    /**
     * Update foreground notification
     */
    private fun updateNotification() {
        val intent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        
        val sessionCount = activeSessions.size
        val contentText = if (sessionCount == 1) {
            "1 active SSH session"
        } else {
            "$sessionCount active SSH sessions"
        }
        
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("BlueSSH")
            .setContentText(contentText)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        
        startForeground(NOTIFICATION_ID, notification)
    }
}

/**
 * Boot receiver to restart sessions after device reboot
 */
class BootReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(context: android.content.Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            // Start the session service
            val serviceIntent = Intent(context, SshSessionService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        }
    }
}
