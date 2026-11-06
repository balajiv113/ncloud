package app.ncloud.folders

internal fun folderRoute(method: String, hasActivity: Boolean): String = when (method) {
    "pick" -> if (hasActivity) "pick" else "headless_picker"
    "conditions" -> "conditions"
    "workerNotification" -> "workerNotification"
    "acquire", "release" -> "lock"
    "list", "export", "stage", "import", "discard" -> "transfer"
    else -> "unsupported"
}
