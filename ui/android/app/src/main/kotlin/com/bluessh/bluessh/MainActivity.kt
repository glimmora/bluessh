package com.bluessh.bluessh

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EngineBridge.registerWith(flutterEngine, applicationContext)

        // Register a separate channel for permission operations
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.bluessh/permissions"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkNotificationPermission" -> {
                    result.success(hasNotificationPermission())
                }
                "requestNotificationPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        requestPermissions(
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                            REQUEST_CODE_NOTIFICATIONS
                        )
                        // Return current state; the Dart side re-checks via permission_handler
                        result.success(hasNotificationPermission())
                    } else {
                        result.success(true)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasNotificationPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    companion object {
        private const val REQUEST_CODE_NOTIFICATIONS = 1001
    }
}

/**
 * Foreground service that keeps the OS from killing the app process
 * while an SSH/VNC/RDP session is active.
 *
 * Lifecycle:
 *   Flutter calls startService() when a session connects.
 *   Flutter calls stopService()  when all sessions disconnect.
 *
 * The service shows a persistent notification so the user knows
 * the app is maintaining a remote connection in the background.
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
        createNotificationChannel()
        val notification = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start foreground: ${e.message}", e)
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
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
