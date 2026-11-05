package app.ncloud.ncloud

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.content.IntentFilter
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private var picker: MethodChannel.Result? = null
    private val pickCode = 9142
    private val stageRoot get() = File(cacheDir, "ncloud-sync-staging").apply { mkdirs() }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.ncloud/folder_sync")
            .setMethodCallHandler { call, result ->
                if (call.method == "pick") {
                    if (picker != null) {
                        result.error("busy", "A folder picker is already open.", null)
                    } else {
                        picker = result
                        try {
                            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                            }, pickCode)
                        } catch (error: Exception) {
                            picker = null
                            result.error("folder_access", "Could not open the system folder picker.", null)
                        }
                        if (call.method == "conditions") {
                            val connectivity = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
                            val network = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
                            val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                            val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
                            result.success(mapOf(
                                "wifi" to (network?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true),
                                "charging" to (status == BatteryManager.BATTERY_STATUS_CHARGING ||
                                    status == BatteryManager.BATTERY_STATUS_FULL)))
                            return@setMethodCallHandler
                        }
                    }
                    return@setMethodCallHandler
                }
                if (call.method !in listOf("list", "export", "stage", "import", "discard")) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                worker.execute {
                    try {
                        val output: Any? = when (call.method) {
                            "stage" -> newStage().path
                            "discard" -> {
                                staged(call.argument<String>("staged")!!).let {
                                    if (it.exists() && !it.delete()) error("Could not remove temporary transfer.")
                                }
                                null
                            }
                            else -> {
                                val token = Uri.parse(call.argument<String>("token")!!)
                                val path = call.argument<List<String>>("path")!!
                                validate(path)
                                val root = DocumentsContract.buildDocumentUriUsingTree(
                                    token, DocumentsContract.getTreeDocumentId(token))
                                when (call.method) {
                                    "list" -> children(resolve(root, path)).map { it.second }
                                    "export" -> {
                                        val source = resolve(root, path)
                                        val before = metadata(source)
                                        val size = call.argument<Number>("size")!!.toLong()
                                        val modified = call.argument<Number>("modified")!!.toLong()
                                        check(before["directory"] == false &&
                                            before["size"] == size && before["modified"] == modified) {
                                            "Source changed. Scan again."
                                        }
                                        val temp = newStage()
                                        try {
                                            contentResolver.openInputStream(source).use { input ->
                                                checkNotNull(input) { "Source is unavailable." }
                                                temp.outputStream().use { input.copyTo(it) }
                                            }
                                            check(metadata(source) == before && temp.length() == size) {
                                                "Source changed during transfer."
                                            }
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
                                                checkNotNull(DocumentsContract.createDocument(
                                                    contentResolver, parent,
                                                    DocumentsContract.Document.MIME_TYPE_DIR, name))
                                            } else {
                                                check(match.second["directory"] == true) { "Folder name conflict." }
                                                match.first
                                            }
                                            check(metadata(parent)["name"] == name) { "Provider renamed a folder." }
                                        }
                                        val existing = children(parent)
                                        check(existing.none { it.second["name"] == path.last() }) {
                                            "Destination exists. Nothing overwritten."
                                        }
                                        val extension = path.last().substringAfterLast('.', "")
                                        val mime = MimeTypeMap.getSingleton()
                                            .getMimeTypeFromExtension(extension.lowercase()) ?: "application/octet-stream"
                                        val created = checkNotNull(DocumentsContract.createDocument(
                                            contentResolver, parent, mime, path.last()))
                                        // Never open a provider-returned pre-existing document for writing.
                                        check(existing.none {
                                            DocumentsContract.getDocumentId(it.first) ==
                                                DocumentsContract.getDocumentId(created)
                                        }) { "Provider reused an existing file." }
                                        try {
                                            check(metadata(created)["name"] == path.last()) { "Provider renamed the destination." }
                                            contentResolver.openOutputStream(created, "w").use { outputStream ->
                                                checkNotNull(outputStream)
                                                temp.inputStream().use { it.copyTo(outputStream) }
                                            }
                                            val saved = metadata(created)
                                            check(saved["size"] == temp.length() &&
                                                (saved["modified"] as Long) > 0) { "Could not confirm transfer." }
                                            saved
                                        } catch (error: Exception) {
                                            // Only this operation's newly created, unconfirmed file.
                                            DocumentsContract.deleteDocument(contentResolver, created)
                                            throw error
                                        }
                                    }
                                }
                            }
                        }
                        runOnUiThread { result.success(output) }
                    } catch (error: Exception) {
                        runOnUiThread {
                            result.error("folder_access", "Folder access or transfer failed. Check permission and free space.", null)
                        }
                    }
                }
            }
    }

    private fun validate(path: List<String>) {
        check(path.size <= 64 && path.none {
            it.isEmpty() || it == "." || it == ".." ||
                it.any { char -> char == '/' || char == '\\' || char.code < 32 }
        }) { "Invalid relative path." }
    }

    private fun staged(path: String): File {
        val file = File(path).canonicalFile
        check(file.parentFile == stageRoot.canonicalFile && file.name.endsWith(".part")) {
            "Invalid transfer file."
        }
        return file
    }

    private fun newStage(): File {
        val cutoff = System.currentTimeMillis() - 24 * 60 * 60 * 1000
        stageRoot.listFiles()?.filter {
            it.isFile && it.name.startsWith("transfer-") &&
                it.name.endsWith(".part") && it.lastModified() < cutoff
        }?.forEach { check(it.delete()) { "Could not clean an interrupted transfer." } }
        return File.createTempFile("transfer-", ".part", stageRoot)
    }

    private fun metadata(uri: Uri): Map<String, Any> {
        contentResolver.query(uri, arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED), null, null, null).use { cursor ->
            check(cursor != null && cursor.moveToFirst()) { "Folder permission is no longer available." }
            return mapOf(
                "name" to cursor.getString(1),
                "directory" to (cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR),
                "size" to cursor.getLong(3),
                "modified" to cursor.getLong(4))
        }
    }

    private fun children(parent: Uri): List<Pair<Uri, Map<String, Any>>> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(
            parent, DocumentsContract.getDocumentId(parent))
        val values = mutableListOf<Pair<Uri, Map<String, Any>>>()
        contentResolver.query(uri, arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED), null, null, null).use { cursor ->
            checkNotNull(cursor) { "Folder listing failed." }
            while (cursor.moveToNext()) {
                check(values.size < 100000) { "Folder is too large." }
                val child = DocumentsContract.buildDocumentUriUsingTree(parent, cursor.getString(0))
                values.add(child to mapOf(
                    "name" to cursor.getString(1),
                    "directory" to (cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR),
                    "size" to cursor.getLong(3),
                    "modified" to cursor.getLong(4)))
            }
        }
        return values
    }

    private fun resolve(root: Uri, path: List<String>): Uri {
        var uri = root
        for (name in path) {
            uri = children(uri).single { it.second["name"] == name }.first
        }
        return uri
    }

    @Deprecated("Android activity result API required by FlutterActivity integration")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickCode) return
        val pending = picker ?: return
        picker = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending.success(null)
            return
        }
        try {
            val flags = (data?.flags ?: 0) and
                (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            contentResolver.takePersistableUriPermission(uri, flags)
            val document = DocumentsContract.buildDocumentUriUsingTree(
                uri, DocumentsContract.getTreeDocumentId(uri))
            pending.success(mapOf("token" to uri.toString(),
                "identity" to uri.toString(), "name" to metadata(document)["name"]))
        } catch (error: Exception) {
            pending.error("folder_access", "Could not retain folder permission. Choose another folder.", null)
        }
    }
}
