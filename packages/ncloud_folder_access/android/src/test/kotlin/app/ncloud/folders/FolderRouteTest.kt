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
        assertEquals("mediaAccess", folderRoute("mediaAccess", false))
        for (method in listOf("mediaList", "mediaExport")) {
            assertEquals("mediaTransfer", folderRoute(method, false))
        }
        assertEquals("unsupported", folderRoute("unknown", false))
    }

    @Test
    fun workersNeverAskToRemovePhotos() {
        assertEquals("mediaTrash", folderRoute("mediaTrash", true))
        assertEquals("headless_picker", folderRoute("mediaTrash", false))
    }

    @Test
    fun workersNeverAskForPhotoPermission() {
        assertEquals("mediaRequest", folderRoute("mediaRequest", true))
        assertEquals("headless_picker", folderRoute("mediaRequest", false))
    }
}
