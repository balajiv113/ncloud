package app.ncloud.ncloud

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PhotoBackupPathsTest {
    @Test
    fun preservesDcimAndPicturesSubfolders() {
        assertEquals(listOf("DCIM", "Camera", "a.jpg"), photoBackupPath("DCIM/Camera/", "a.jpg"))
        assertEquals(listOf("Pictures", "Screenshots", "b.png"),
            photoBackupPath("Pictures/Screenshots/", "b.png"))
        assertEquals(listOf("Pictures", "c.jpg"), photoBackupPath("Pictures/", "c.jpg"))
    }

    @Test
    fun legacyAbsoluteMediaPathsStayRelativeToSelectedCloudDestination() {
        assertEquals(listOf("DCIM", "Camera", "a.jpg"),
            photoBackupPath("/storage/emulated/0/DCIM/Camera/a.jpg", "a.jpg", "/storage/emulated/0"))
        assertThrows(IllegalArgumentException::class.java) {
            photoBackupPath("/elsewhere/DCIM/a.jpg", "a.jpg", "/storage/emulated/0")
        }
    }

    @Test
    fun rejectsOtherFoldersAndTraversalInsteadOfFlatteningOrEscaping() {
        for (location in listOf("Downloads/", "DCIM/../Pictures/", "DCIM//Camera/")) {
            assertThrows(IllegalArgumentException::class.java) { photoBackupPath(location, "a.jpg") }
        }
        assertThrows(IllegalArgumentException::class.java) { photoBackupPath("DCIM/", "../a.jpg") }
    }
}
