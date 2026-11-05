package app.ncloud.ncloud

internal fun photoBackupPath(location: String, name: String, legacyRoot: String? = null): List<String> {
    val directory = if (legacyRoot == null) location else {
        require(location.startsWith("$legacyRoot/")) { "Media path is outside storage." }
        location.removePrefix("$legacyRoot/").substringBeforeLast('/', "")
    }
    val folders = directory.trimEnd('/').split('/')
    require(folders.isNotEmpty() && folders.first().lowercase() in listOf("dcim", "pictures")) {
        "Media path is outside DCIM or Pictures."
    }
    val path = folders + name
    require(path.size <= 64 && path.all { part ->
        part.isNotEmpty() && part != "." && part != ".." &&
            part.none { it == '/' || it == '\\' || it.code < 32 }
    }) { "Invalid media path." }
    return path
}
