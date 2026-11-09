package app.ncloud.folders

internal fun folderRoute(method: String, hasActivity: Boolean): String = when (method) {
    "pick" -> if (hasActivity) "pick" else "headless_picker"
    "conditions" -> "conditions"
    "workerNotification" -> "workerNotification"
    "mediaAccess" -> "mediaAccess"
    "mediaRequest" -> if (hasActivity) "mediaRequest" else "headless_picker"
    "mediaList", "mediaExport" -> "mediaTransfer"
    "mediaTrash" -> if (hasActivity) "mediaTrash" else "headless_picker"
    "acquire", "release" -> "lock"
    "list", "export", "stage", "import", "discard", "clearStaging" -> "transfer"
    else -> "unsupported"
}
