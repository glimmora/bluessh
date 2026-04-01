package com.bluessh.bluessh

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EngineBridge.registerWith(flutterEngine, applicationContext)
    }
}

/**
 * Foreground service that keeps the OS from killing the app process
 * while an SSH/VNC/RDP session is active.
 *
 * CRITICAL: On Android 14+ (API 34+), startForegroundService() MUST be
 * followed by startForeground() within ~5 seconds or the system kills
 * the process with ForegroundServiceDidNotStartInTimeException.
 *
 * Therefore startForeground() is called IMMEDIATELY in onCreate()
 * BEFORE any other work.  No try/catch around it — if it fails the
 * process dies anyway, and catching it only delays the inevitable.
 */
class SessionForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "bluessh_session"
        private const val NOTIFICATION_ID = 1001
        private const val TAG = "SessionFGS"

        /** Start the foreground service from Dart via MethodChannel. */
        fun start(context: Context) {
            val intent = Intent(context, SessionForegroundService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start foreground service: ${e.message}", e)
            }
        }

        /** Stop the foreground service from Dart via MethodChannel. */
        fun stop(context: Context) {
            context.stopService(Intent(context, SessionForegroundService::class.java))
        }
    }

    override fun onCreate() {
        super.onCreate()

        // ── CRITICAL: call startForeground() FIRST, before anything else ──
        // The OS gives us ~5 seconds.  Channel must exist before the
        // notification can be posted, so create it immediately.
        createNotificationChannel()
        val notification = buildNotification()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        Log.d(TAG, "Foreground service started successfully")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        Log.d(TAG, "Foreground service destroyed")
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Active Sessions",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shown while a remote session is active"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("BlueSSH")
            .setContentText("Remote session active")
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }
}
