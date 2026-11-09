package app.ncloud.folders

import android.app.Activity
import android.app.NotificationManager
import android.Manifest
import android.content.pm.PackageManager
import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.BatteryManager
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.Build
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.channels.FileLock
import java.nio.channels.OverlappingFileLockException
import java.security.MessageDigest
import java.util.concurrent.Executors

/** GeneratedPluginRegistrant installs this in every engine, including Workmanager. */
class FolderAccessPlugin : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var activity: Activity? = null
    private var binding: ActivityPluginBinding? = null
    private var picker: MethodChannel.Result? = null
    private var mediaRequest: MethodChannel.Result? = null
    private var trashRequest: MethodChannel.Result? = null
    private var trashIds: List<String> = emptyList()
    private val locks = mutableMapOf<String, Pair<RandomAccessFile, FileLock>>()
    private val stageRoot get() = File(context.cacheDir, "ncloud-sync-staging").apply { mkdirs() }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "app.ncloud/folder_sync")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
            when (folderRoute(call.method, activity != null)) {
                "pick" -> {
                    if (picker != null) {
                        result.error("busy", "A folder picker is already open.", null)
                    } else {
                        picker = result
                        try {
                            activity!!.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                            }, 9142)
                        } catch (error: android.content.ActivityNotFoundException) {
                            picker = null
                            result.error("folder_access", "Could not open the system folder picker.", null)
                        }
                    }
                }
                "headless_picker" -> result.error("foreground_required", "Choose folders in the app, not in a worker.", null)
                "mediaAccess" -> result.success(mapOf("status" to mediaStatus()))
                "mediaRequest" -> {
                    if (mediaRequest != null) {
                        result.error("busy", "A permission request is already open.", null)
                    } else if (mediaStatus() == "granted") {
                        result.success(mapOf("status" to "granted"))
                    } else {
                        mediaRequest = result
                        activity!!.requestPermissions(mediaPermissions(), 9143)
                    }
                }
                "mediaTrash" -> {
                    val ids = call.argument<List<String>>("ids")
                    if (Build.VERSION.SDK_INT < 30) {
                        result.error("unsupported", "Removing photos needs Android 11 or later.", null)
                    } else if (ids.isNullOrEmpty()) {
                        result.success(emptyList<String>())
                    } else if (trashRequest != null) {
                        result.error("busy", "A removal request is already open.", null)
                    } else {
                        try {
                            val pending = MediaStore.createTrashRequest(
                                context.contentResolver, ids.map { mediaUri(it) }, true)
                            trashRequest = result
                            trashIds = ids
                            activity!!.startIntentSenderForResult(pending.intentSender, 9144, null, 0, 0, 0)
                        } catch (error: Exception) {
                            trashRequest = null
                            trashIds = emptyList()
                            result.error("media_trash", "Could not ask to remove the photos.", null)
                        }
                    }
                }
                "mediaTransfer" -> worker.execute {
                    try {
                        val output: Any? = when (call.method) {
                            "mediaList" -> mediaPage(
                                call.argument<Number>("offset")!!.toInt(),
                                call.argument<Number>("limit")!!.toInt())
                            else -> mediaExport(
                                call.argument<String>("id")!!,
                                call.argument<Number>("size")!!.toLong(),
                                call.argument<Number>("modified")!!.toLong())
                        }
                        main.post { result.success(output) }
                    } catch (error: Exception) {
                        val code = when (error) {
                            is SecurityException -> "media_permission"
                            is FileNotFoundException -> "folder_unavailable"
                            is IOException -> "folder_io"
                            else -> "folder_transfer"
                        }
                        main.post { result.error(code, "The photo library operation failed.", null) }
                    }
                }
                "workerNotification" -> {
                    val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    val permitted = Build.VERSION.SDK_INT < 33 ||
                        context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
                    val enabled = Build.VERSION.SDK_INT < 24 || manager.areNotificationsEnabled()
                    val channelEnabled = Build.VERSION.SDK_INT < 26 ||
                        manager.getNotificationChannel("ncloud_scheduled_backup")?.importance != NotificationManager.IMPORTANCE_NONE
                    val id = call.argument<Number>("id")!!.toInt()
                    result.success(permitted && enabled && channelEnabled &&
                        manager.activeNotifications.any { it.id == id })
                }
                "conditions" -> try {
                    val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    val network = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
                    val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                    val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
                    result.success(mapOf(
                        "wifi" to (network?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true),
                        "charging" to (status == BatteryManager.BATTERY_STATUS_CHARGING ||
                            status == BatteryManager.BATTERY_STATUS_FULL)))
                } catch (error: SecurityException) {
                    result.error("conditions_permission", "Could not check network conditions.", null)
                }
                "lock" -> try {
                    val owner = call.argument<String>("account")!!
                    if (call.method == "release") {
                        locks.remove(owner)?.let {
                            try { it.second.release() } finally { it.first.close() }
                        }
                        result.success(null)
                    } else if (locks.containsKey(owner)) {
                        result.success(false)
                    } else {
                        val digest = MessageDigest.getInstance("SHA-256").digest(owner.toByteArray())
                            .joinToString("") { "%02x".format(it) }
                        val file = RandomAccessFile(File(context.filesDir, "sync-$digest.lock"), "rw")
                        try {
                            val lock = try { file.channel.tryLock() } catch (_: OverlappingFileLockException) { null }
                            if (lock == null) { file.close(); result.success(false) }
                            else { locks[owner] = file to lock; result.success(true) }
                        } catch (error: IOException) {
                            file.close()
                            throw error
                        }
                    }
                } catch (error: IOException) {
                    result.error("sync_lock", "Could not access the backup lock.", null)
                } catch (error: SecurityException) {
                    result.error("sync_lock", "Could not access the backup lock.", null)
                }
                "transfer" -> worker.execute {
                    try {
                        val output: Any? = when (call.method) {
                            "stage" -> newStage().path
                            "discard" -> {
                                val file = staged(call.argument<String>("staged")!!)
                                check(!file.exists() || file.delete()) { "Could not remove transfer file." }
                                null
                            }
                            "clearStaging" -> {
                                stageRoot.listFiles()?.filter { it.isFile }?.forEach {
                                    check(it.delete()) { "Could not remove transfer file." }
                                }
                                null
                            }
                            else -> {
                                val token = Uri.parse(call.argument<String>("token")!!)
                                val path = call.argument<List<String>>("path")!!
                                validate(path)
                                val root = DocumentsContract.buildDocumentUriUsingTree(token, DocumentsContract.getTreeDocumentId(token))
                                when (call.method) {
                                    "list" -> children(resolve(root, path)).map { it.second }
                                    "export" -> {
                                        // The listing gave every file's document id, so open it directly.
                                        // Finding it by name would list its whole folder for every file,
                                        // which is far too slow for a folder of thousands of photos.
                                        val id = call.argument<String>("id")
                                        val source = if (id != null) {
                                            DocumentsContract.buildDocumentUriUsingTree(token, id)
                                        } else resolve(root, path)
                                        val before = metadata(source)
                                        check(before["name"] == path.last()) { "Source changed. Scan again." }
                                        val size = call.argument<Number>("size")!!.toLong()
                                        val modified = call.argument<Number>("modified")!!.toLong()
                                        check(before["directory"] == false && before["size"] == size && before["modified"] == modified) {
                                            "Source changed. Scan again."
                                        }
                                        val temp = newStage()
                                        try {
                                            context.contentResolver.openInputStream(source).use { input ->
                                                checkNotNull(input)
                                                temp.outputStream().use { input.copyTo(it) }
                                            }
                                            check(metadata(source) == before && temp.length() == size) { "Source changed during transfer." }
                                            temp.path
                                        } catch (error: Exception) {
                                            temp.delete()
                                            throw error
                                        }
                                    }
                                    else -> {
                                        check(path.isNotEmpty())
                                        val temp = staged(call.argument<String>("staged")!!)
                                        var parent = root
                                        for (name in path.dropLast(1)) {
                                            val match = children(parent).singleOrNull { it.second["name"] == name }
                                            parent = if (match == null) {
                                                checkNotNull(DocumentsContract.createDocument(context.contentResolver, parent,
                                                    DocumentsContract.Document.MIME_TYPE_DIR, name))
                                            } else {
                                                check(match.second["directory"] == true) { "Folder name conflict." }
                                                match.first
                                            }
                                            check(metadata(parent)["name"] == name) { "Provider renamed a folder." }
                                        }
                                        val existing = children(parent)
                                        check(existing.none { it.second["name"] == path.last() }) { "Destination exists. Nothing overwritten." }
                                        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(
                                            path.last().substringAfterLast('.', "").lowercase()) ?: "application/octet-stream"
                                        val created = checkNotNull(DocumentsContract.createDocument(context.contentResolver, parent, mime, path.last()))
                                        check(existing.none { DocumentsContract.getDocumentId(it.first) ==
                                            DocumentsContract.getDocumentId(created) }) { "Provider reused an existing file." }
                                        try {
                                            check(metadata(created)["name"] == path.last()) { "Provider renamed destination." }
                                            context.contentResolver.openOutputStream(created, "w").use { outputStream ->
                                                checkNotNull(outputStream)
                                                temp.inputStream().use { it.copyTo(outputStream) }
                                            }
                                            val saved = metadata(created)
                                            check(saved["size"] == temp.length() && (saved["modified"] as Long) > 0) { "Could not confirm transfer." }
                                            saved
                                        } catch (error: Exception) {
                                            DocumentsContract.deleteDocument(context.contentResolver, created)
                                            throw error
                                        }
                                    }
                                }
                            }
                        }
                        main.post { result.success(output) }
                    } catch (error: Exception) {
                        val code = when (error) {
                            is SecurityException -> "folder_permission"
                            is FileNotFoundException -> "folder_unavailable"
                            is IOException -> "folder_io"
                            else -> "folder_transfer"
                        }
                        main.post { result.error(code, "The selected folder operation failed.", null) }
                    }
                }
                else -> result.notImplemented()
            }
    }

    private fun has(permission: String) =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /** What to ask for: the photo and video permissions of this Android version, and the location in photos. */
    private fun mediaPermissions(): Array<String> {
        val wanted = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= 33) {
            wanted += Manifest.permission.READ_MEDIA_IMAGES
            wanted += Manifest.permission.READ_MEDIA_VIDEO
            if (Build.VERSION.SDK_INT >= 34) wanted += "android.permission.READ_MEDIA_VISUAL_USER_SELECTED"
        } else {
            wanted += Manifest.permission.READ_EXTERNAL_STORAGE
        }
        if (Build.VERSION.SDK_INT >= 29) wanted += Manifest.permission.ACCESS_MEDIA_LOCATION
        return wanted.toTypedArray()
    }

    /** "granted" for the whole library, "partial" for only some of it (selected photos, or photos but not videos), else "denied". */
    private fun mediaStatus(): String {
        if (Build.VERSION.SDK_INT >= 33) {
            val images = has(Manifest.permission.READ_MEDIA_IMAGES)
            val videos = has(Manifest.permission.READ_MEDIA_VIDEO)
            return when {
                images && videos -> "granted"
                images || videos -> "partial"
                Build.VERSION.SDK_INT >= 34 && has("android.permission.READ_MEDIA_VISUAL_USER_SELECTED") -> "partial"
                else -> "denied"
            }
        }
        return if (has(Manifest.permission.READ_EXTERNAL_STORAGE)) "granted" else "denied"
    }

    /** One page of the photo and video library, oldest first, so paging is steady while it is read. */
    private fun mediaPage(offset: Int, limit: Int): List<Map<String, Any?>> {
        require(offset >= 0 && limit in 1..5000)
        val relative = Build.VERSION.SDK_INT >= 29
        val projection = arrayOf(
            MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.MIME_TYPE, MediaStore.MediaColumns.DATE_MODIFIED,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            if (relative) MediaStore.MediaColumns.RELATIVE_PATH else MediaStore.MediaColumns.DATA)
        val selection = "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (?, ?)"
        val arguments = arrayOf(
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString())
        val order = "${MediaStore.MediaColumns._ID} ASC"
        val uri = MediaStore.Files.getContentUri("external")
        val cursor = if (Build.VERSION.SDK_INT >= 26) {
            val query = Bundle().apply {
                putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection)
                putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, arguments)
                putString(ContentResolver.QUERY_ARG_SQL_SORT_ORDER, order)
                putInt(ContentResolver.QUERY_ARG_LIMIT, limit)
                putInt(ContentResolver.QUERY_ARG_OFFSET, offset)
            }
            context.contentResolver.query(uri, projection, query, null)
        } else {
            context.contentResolver.query(uri, projection, selection, arguments, "$order LIMIT $limit OFFSET $offset")
        }
        val items = mutableListOf<Map<String, Any?>>()
        cursor.use {
            checkNotNull(it) { "Photo library listing failed." }
            val root = Environment.getExternalStorageDirectory().absolutePath
            while (it.moveToNext()) {
                val name = it.getString(1)
                val size = it.getLong(2)
                // Without a name or a size a file cannot be backed up or checked.
                if (name.isNullOrEmpty() || size <= 0) continue
                val kind = if (it.getInt(5) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO) "video" else "image"
                val place = it.getString(6) ?: ""
                val folder = if (relative) place.trim('/') else {
                    val parent = java.io.File(place).parent ?: ""
                    (if (parent.startsWith(root)) parent.removePrefix(root) else parent).trim('/')
                }
                items.add(mapOf(
                    "id" to "$kind:${it.getLong(0)}", "name" to name, "size" to size,
                    "modified" to it.getLong(4) * 1000, "contentType" to (it.getString(3) ?: ""),
                    "folder" to folder))
            }
        }
        return items
    }

    /** Copies one photo or video, as the original with its location when allowed, after checking it is unchanged. */
    private fun mediaExport(id: String, size: Long, modified: Long): String {
        val parts = id.split(":")
        check(parts.size == 2) { "Unsupported photo id." }
        val base = if (parts[0] == "video") MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        val uri = ContentUris.withAppendedId(base, parts[1].toLong())
        context.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.DATE_MODIFIED),
            null, null, null).use { cursor ->
            check(cursor != null && cursor.moveToFirst()) { "That photo is no longer in the library." }
            check(cursor.getLong(0) == size && cursor.getLong(1) * 1000 == modified) { "Source changed. Scan again." }
        }
        val temp = newStage()
        try {
            openMedia(uri).use { input ->
                temp.outputStream().use { input.copyTo(it) }
            }
            check(temp.length() == size) { "Source changed during transfer." }
            return temp.path
        } catch (error: Exception) {
            temp.delete()
            throw error
        }
    }

    private fun mediaUri(id: String): Uri {
        val parts = id.split(":")
        check(parts.size == 2) { "Unsupported photo id." }
        val base = if (parts[0] == "video") MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        return ContentUris.withAppendedId(base, parts[1].toLong())
    }

    /** Whether the photo is still in the library. A trashed one is not listed. */
    private fun mediaExists(id: String): Boolean = try {
        context.contentResolver.query(mediaUri(id), arrayOf(MediaStore.MediaColumns._ID), null, null, null)
            .use { it != null && it.moveToFirst() }
    } catch (_: Exception) {
        false
    }

    /** The answer to the system's removal prompt: the ids that are gone, or none if the user declined. */
    private fun onTrashResult(resultCode: Int): Boolean {
        val pending = trashRequest ?: return false
        val ids = trashIds
        trashRequest = null
        trashIds = emptyList()
        if (resultCode != Activity.RESULT_OK) {
            pending.success(emptyList<String>())
            return true
        }
        worker.execute {
            val removed = ids.filter { !mediaExists(it) }
            main.post { pending.success(removed) }
        }
        return true
    }

    /** Opens the original, with its location, when Android allows it; otherwise the file as Android gives it. */
    private fun openMedia(uri: Uri): java.io.InputStream {
        if (Build.VERSION.SDK_INT >= 29 && has(Manifest.permission.ACCESS_MEDIA_LOCATION)) {
            try {
                context.contentResolver.openInputStream(MediaStore.setRequireOriginal(uri))?.let { return it }
            } catch (_: UnsupportedOperationException) {
            } catch (_: SecurityException) {
            }
        }
        return checkNotNull(context.contentResolver.openInputStream(uri)) { "Could not read the photo." }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != 9143) return false
        val pending = mediaRequest ?: return false
        mediaRequest = null
        pending.success(mapOf("status" to mediaStatus()))
        return true
    }

    private fun validate(path: List<String>) {
        check(path.size <= 64 && path.none { it.isEmpty() || it == "." || it == ".." ||
            it.any { char -> char == '/' || char == '\\' || char.code < 32 } })
    }

    private fun staged(path: String): File {
        val file = File(path).canonicalFile
        check(file.parentFile == stageRoot.canonicalFile && file.name.endsWith(".part"))
        return file
    }

    private fun newStage(): File {
        val cutoff = System.currentTimeMillis() - 24 * 60 * 60 * 1000
        stageRoot.listFiles()?.filter { it.isFile && it.name.startsWith("transfer-") &&
            it.name.endsWith(".part") && it.lastModified() < cutoff
        }?.forEach { check(it.delete()) { "Could not clean an interrupted transfer." } }
        return File.createTempFile("transfer-", ".part", stageRoot)
    }

    private fun metadata(uri: Uri): Map<String, Any> {
        context.contentResolver.query(uri, arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED), null, null, null).use { cursor ->
            check(cursor != null && cursor.moveToFirst()) { "Folder permission is no longer available." }
            return mapOf("name" to cursor.getString(1),
                "directory" to (cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR),
                "contentType" to cursor.getString(2), "size" to cursor.getLong(3), "modified" to cursor.getLong(4))
        }
    }

    private fun children(parent: Uri): List<Pair<Uri, Map<String, Any>>> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(parent, DocumentsContract.getDocumentId(parent))
        val values = mutableListOf<Pair<Uri, Map<String, Any>>>()
        context.contentResolver.query(uri, arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED), null, null, null).use { cursor ->
            checkNotNull(cursor) { "Folder listing failed." }
            while (cursor.moveToNext()) {
                check(values.size < 100000) { "Folder is too large." }
                values.add(DocumentsContract.buildDocumentUriUsingTree(parent, cursor.getString(0)) to
                    mapOf("name" to cursor.getString(1), "directory" to
                        (cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR),
                        "contentType" to cursor.getString(2), "size" to cursor.getLong(3), "modified" to cursor.getLong(4),
                        "id" to cursor.getString(0)))
            }
        }
        return values
    }

    private fun resolve(root: Uri, path: List<String>): Uri {
        var uri = root
        for (name in path) uri = children(uri).single { it.second["name"] == name }.first
        return uri
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == 9144) return onTrashResult(resultCode)
        if (requestCode != 9142) return false
        val pending = picker ?: return false
        picker = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) pending.success(null)
        else try {
            val flags = (data?.flags ?: 0) and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            context.contentResolver.takePersistableUriPermission(uri, flags)
            val document = DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
            pending.success(mapOf("token" to uri.toString(), "identity" to uri.toString(), "name" to metadata(document)["name"]))
        } catch (error: Exception) {
            pending.error("folder_access", "Could not retain folder permission. Choose another folder.", null)
        }
        return true
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        activity = binding.activity
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }
    override fun onDetachedFromActivity() {
        binding?.removeActivityResultListener(this)
        binding?.removeRequestPermissionsResultListener(this)
        binding = null
        activity = null
        picker?.error("foreground_required", "Folder picker closed with the activity.", null)
        picker = null
        mediaRequest?.error("foreground_required", "The permission request closed with the activity.", null)
        mediaRequest = null
        trashRequest?.error("foreground_required", "The removal request closed with the activity.", null)
        trashRequest = null
        trashIds = emptyList()
    }
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        // Retain locks until any in-flight SAF write has finished, even after engine teardown.
        worker.execute {
            locks.values.forEach {
                try { it.second.release() } finally { it.first.close() }
            }
            locks.clear()
        }
        worker.shutdown()
    }
}
