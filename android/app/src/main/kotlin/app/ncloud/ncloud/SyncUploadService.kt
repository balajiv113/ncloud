package app.ncloud.ncloud

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class SyncUploadService : Service() {
    companion object {
        var engine: FlutterEngine? = null
        var hostAttached = false
        var running = false
            private set
        var ready: ((String?) -> Unit)? = null
        var finishing = false
        const val channelId = "ncloud_folder_uploads"
        private const val notificationId = 9145
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private val handler = Handler(Looper.getMainLooper())
    private val limit = Runnable {
        finishing = true
        pause("The background run reached its time limit. Open ncloud and resume.")
        stopSelf()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun pause(reason: String? = null) {
        engine?.let {
            MethodChannel(it.dartExecutor.binaryMessenger, "app.ncloud/sync_background")
                .invokeMethod("pause", reason)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "pause") {
            if (running) pause() else stopSelf()
            return START_NOT_STICKY
        }
        try {
            checkNotNull(engine) { "Open ncloud to start a backup." }
            val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= 26) {
                manager.createNotificationChannel(NotificationChannel(
                    channelId, "Folder uploads", NotificationManager.IMPORTANCE_LOW))
            }
            val open = PendingIntent.getActivity(this, 0,
                Intent(this, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val stop = PendingIntent.getService(this, 1,
                Intent(this, SyncUploadService::class.java).setAction("pause"),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, channelId)
                else Notification.Builder(this)
            if (Build.VERSION.SDK_INT >= 31) {
                builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            }
            val notification = builder
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setContentTitle("ncloud folder sync")
                .setContentText("Transfers continue in the background. Pause to stop after current files.")
                .setContentIntent(open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .addAction(Notification.Action.Builder(android.R.drawable.ic_media_pause, "Pause", stop).build())
                .build()
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(notificationId, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(notificationId, notification)
            }
            if (wakeLock == null) {
                wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ncloud:folder-upload")
                    .apply { acquire(6 * 60 * 60 * 1000L) }
                handler.postDelayed(limit, 6 * 60 * 60 * 1000L)
            }
            running = true
            finishing = false
            ready?.invoke(null)
            ready = null
        } catch (error: Exception) {
            ready?.invoke("Android could not start the upload service.")
            ready = null
            stopSelf()
        }
        // Checkpointed files survive process death; a killed process is not
        // silently restarted with a new engine or duplicate transfer workers.
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        finishing = true
        pause("Android reached its background transfer time limit. Open ncloud and resume.")
        stopSelf()
    }

    override fun onDestroy() {
        handler.removeCallbacks(limit)
        if (running && !finishing) pause("Android stopped background uploads. Open ncloud and resume.")
        running = false
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        ready?.invoke("The upload service stopped before it was ready.")
        ready = null
        val retained = engine
        if (!hostAttached) {
            // Let the stop method reply before releasing an off-screen engine.
            handler.postDelayed({
                if (engine !== retained || (!hostAttached && !running)) {
                    retained?.destroy()
                    if (engine === retained) engine = null
                }
            }, 1000)
        }
        super.onDestroy()
    }
}
