package app.ncloud.ncloud

import android.Manifest
import android.content.ContentUris
import android.content.pm.PackageManager
import android.os.Build
import android.provider.MediaStore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

internal class PhotoBackupBridge(
    private val activity: MainActivity,
    private val stage: () -> File
) {
    private val worker = Executors.newSingleThreadExecutor()
    private var permissionResult: MethodChannel.Result? = null
    val requestCode = 9143
    private val collection = MediaStore.Files.getContentUri("external")

    private fun granted(permission: String) =
        activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun permission(): String {
        if (Build.VERSION.SDK_INT < 33) {
            return if (granted(Manifest.permission.READ_EXTERNAL_STORAGE)) "full" else "denied"
        }
        if (granted(Manifest.permission.READ_MEDIA_IMAGES) &&
            granted(Manifest.permission.READ_MEDIA_VIDEO)) return "full"
        if (granted(Manifest.permission.READ_MEDIA_IMAGES) ||
            granted(Manifest.permission.READ_MEDIA_VIDEO) ||
            (Build.VERSION.SDK_INT >= 34 &&
                granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED))) return "limited"
        return "denied"
    }

    fun onPermissionsResult(code: Int): Boolean {
        if (code != requestCode) return false
        permissionResult?.success(permission())
        permissionResult = null
        return true
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "photos.settings") {
            try {
                activity.startActivity(android.content.Intent(
                    android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    android.net.Uri.parse("package:" + activity.packageName)))
                result.success(true)
            } catch (error: android.content.ActivityNotFoundException) {
                result.error("photo_permission", "Open ncloud permissions in device Settings.", null)
            }
            return
        }
        if (call.method == "photos.permission") {
            if (call.argument<Boolean>("request") != true || permission() == "full") {
                result.success(permission())
            } else if (permissionResult != null) {
                result.error("photo_permission", "A permission request is already open.", null)
            } else {
                permissionResult = result
                val permissions = if (Build.VERSION.SDK_INT >= 34) {
                    arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO,
                        Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
                } else if (Build.VERSION.SDK_INT >= 33) {
                    arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
                } else arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
                try {
                    activity.requestPermissions(permissions, requestCode)
                } catch (error: Exception) {
                    permissionResult = null
                    result.error("photo_permission", "Could not request Photos access. Open ncloud permissions in Settings.", null)
                }
            }
            return
        }
        if (call.method !in listOf("photos.scan", "photos.resources", "photos.export")) {
            result.notImplemented()
            return
        }
        worker.execute {
            try {
                if (permission() == "denied") throw SecurityException("Photo permission is required.")
                val output: Any = when (call.method) {
                    "photos.scan" -> {
                        val offset = call.argument<Int>("offset") ?: 0
                        val limit = call.argument<Int>("limit") ?: 500
                        check(offset >= 0 && limit in 1..500)
                        val rows = mutableListOf<Map<String, Any>>()
                        query(null).use { cursor ->
                            checkNotNull(cursor) { "Media listing unavailable." }
                            if (cursor.moveToPosition(offset)) {
                                do {
                                    rows.add(mapOf(
                                        "id" to cursor.getLong(0).toString(),
                                        "modified" to cursor.getLong(3) * 1000))
                                } while (rows.size < limit && cursor.moveToNext())
                            }
                        }
                        rows
                    }
                    "photos.resources" -> listOf(resource(call.argument<String>("id")!!))
                    else -> {
                        val id = call.argument<String>("id")!!
                        val before = resource(id)
                        check(before["name"] == call.argument<String>("name") &&
                            before["size"] == call.argument<Number>("size")!!.toLong() &&
                            before["modified"] == call.argument<Number>("modified")!!.toLong()) {
                            "Photo changed while preparing backup."
                        }
                        val file = stage()
                        try {
                            activity.contentResolver.openInputStream(
                                ContentUris.withAppendedId(collection, id.toLong())).use { input ->
                                checkNotNull(input)
                                file.outputStream().use { input.copyTo(it) }
                            }
                            check(resource(id) == before && file.length() == before["size"]) {
                                "Photo changed during export."
                            }
                            file.path
                        } catch (error: Exception) {
                            file.delete()
                            throw error
                        }
                    }
                }
                activity.runOnUiThread { result.success(output) }
            } catch (error: Exception) {
                activity.runOnUiThread {
                    result.error(
                        if (error is SecurityException) "photo_permission" else "photo_export",
                        "Could not read the selected media. Check Photos permission and free device space.", null)
                }
            }
        }
    }

    private fun query(id: String?): android.database.Cursor? {
        val locationColumn = if (Build.VERSION.SDK_INT >= 29) MediaStore.MediaColumns.RELATIVE_PATH
            else MediaStore.MediaColumns.DATA
        val prefix = if (Build.VERSION.SDK_INT >= 29) "" else
            android.os.Environment.getExternalStorageDirectory().path + "/"
        var selection = "(${MediaStore.Files.FileColumns.MEDIA_TYPE}=? OR " +
            "${MediaStore.Files.FileColumns.MEDIA_TYPE}=?) AND " +
            "($locationColumn LIKE ? OR $locationColumn LIKE ?)"
        val args = mutableListOf(
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString(),
            "${prefix}DCIM/%", "${prefix}Pictures/%")
        if (id != null) {
            check(id.toLongOrNull() != null)
            selection += " AND ${MediaStore.MediaColumns._ID}=?"
            args.add(id)
        }
        return activity.contentResolver.query(collection, arrayOf(
            MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.DATE_MODIFIED, locationColumn),
            selection, args.toTypedArray(), "${MediaStore.MediaColumns._ID} ASC")
    }

    private fun resource(id: String): Map<String, Any> {
        query(id).use { cursor ->
            check(cursor != null && cursor.moveToFirst()) { "Photo no longer accessible." }
            val name = cursor.getString(1)
            val location = cursor.getString(4)
            val relative = photoBackupPath(location, name,
                if (Build.VERSION.SDK_INT >= 29) null else
                    android.os.Environment.getExternalStorageDirectory().path)
            return mapOf("name" to name, "size" to cursor.getLong(2),
                "modified" to cursor.getLong(3) * 1000,
                "relative" to relative)
        }
    }
}
