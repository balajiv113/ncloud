package app.ncloud.ncloud

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var notificationPermission: MethodChannel.Result? = null
    private val notificationCode = 9144

    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        SyncUploadService.engine?.takeIf { SyncUploadService.running }

    override fun shouldDestroyEngineWithHost(): Boolean = !SyncUploadService.running

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        SyncUploadService.engine = flutterEngine
        SyncUploadService.hostAttached = true
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.ncloud/sync_background")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "permission" -> {
                        val allowed = uploadNotificationsAllowed()
                        val postGranted = Build.VERSION.SDK_INT < 33 ||
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
                        if (allowed || postGranted || call.argument<Boolean>("request") != true) {
                            result.success(allowed)
                        } else if (notificationPermission != null) {
                            result.error("background_permission", "A notification permission request is already open.", null)
                        } else {
                            notificationPermission = result
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), notificationCode)
                        }
                    }
                    "settings" -> {
                        try {
                            startActivity(Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:$packageName")))
                            result.success(null)
                        } catch (error: android.content.ActivityNotFoundException) {
                            result.error("background_permission", "Open ncloud notification settings on your device.", null)
                        }
                    }
                    "start" -> {
                        if (!uploadNotificationsAllowed()) {
                            result.error("background_permission", "Allow notifications before starting background uploads.", null)
                        } else if (SyncUploadService.running || SyncUploadService.ready != null) {
                            result.error("background_start", "An upload service is already running.", null)
                        } else {
                            SyncUploadService.ready = { error ->
                                if (error == null) result.success(null)
                                else result.error("background_start", error, null)
                            }
                            try {
                                val intent = Intent(this, SyncUploadService::class.java)
                                if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent)
                                else startService(intent)
                            } catch (error: Exception) {
                                SyncUploadService.ready = null
                                result.error("background_start", "Open ncloud and retry starting background uploads.", null)
                            }
                        }
                    }
                    "stop" -> {
                        SyncUploadService.finishing = true
                        stopService(Intent(this, SyncUploadService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun uploadNotificationsAllowed(): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 24 && !manager.areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= 26 &&
            manager.getNotificationChannel(SyncUploadService.channelId)?.importance == NotificationManager.IMPORTANCE_NONE) return false
        return true
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == notificationCode) {
            notificationPermission?.success(uploadNotificationsAllowed())
            notificationPermission = null
        }
    }

    override fun onDestroy() {
        SyncUploadService.hostAttached = false
        if (!SyncUploadService.running) SyncUploadService.engine = null
        super.onDestroy()
    }
}
