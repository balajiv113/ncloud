package app.ncloud.ncloud

internal fun dispatchFolderMethod(
    method: String,
    pick: () -> Unit,
    conditions: () -> Unit,
    transfer: () -> Unit,
    unsupported: () -> Unit
) {
    when (method) {
        "pick" -> pick()
        "conditions" -> conditions()
        "list", "export", "stage", "import", "discard" -> transfer()
        else -> unsupported()
    }
}
