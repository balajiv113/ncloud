package app.ncloud.folders

import org.junit.Assert.assertEquals
import org.junit.Test

class FolderRouteTest {
    @Test
    fun workerRoutesNeverLaunchPermissionUi() {
        assertEquals("headless_picker", folderRoute("pick", false))
        assertEquals("pick", folderRoute("pick", true))
        assertEquals("conditions", folderRoute("conditions", false))
        assertEquals("workerNotification", folderRoute("workerNotification", false))
        for (method in listOf("list", "export", "stage", "import", "discard", "clearStaging")) {
            assertEquals("transfer", folderRoute(method, false))
        }
        for (method in listOf("acquire", "release")) {
            assertEquals("lock", folderRoute(method, false))
        }
        assertEquals("unsupported", folderRoute("unknown", false))
    }
}
