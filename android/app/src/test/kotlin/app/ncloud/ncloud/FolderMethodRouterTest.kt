package app.ncloud.ncloud

import org.junit.Assert.assertEquals
import org.junit.Test

class FolderMethodRouterTest {
    private fun route(method: String): List<String> {
        val called = mutableListOf<String>()
        dispatchFolderMethod(
            method,
            pick = { called.add("pick") },
            conditions = { called.add("conditions") },
            transfer = { called.add("transfer") },
            unsupported = { called.add("unsupported") }
        )
        return called
    }

    @Test
    fun conditionsDoesNotOpenPickerOrReturnNotImplemented() {
        assertEquals(listOf("conditions"), route("conditions"))
    }

    @Test
    fun repeatedSyncCallsNeverRequestFolderPermission() {
        repeat(3) {
            assertEquals(listOf("conditions"), route("conditions"))
            for (method in listOf("list", "export", "stage", "import", "discard")) {
                assertEquals(listOf("transfer"), route(method))
            }
        }
    }

    @Test
    fun onlyExplicitPickRequestsPermission() {
        assertEquals(listOf("pick"), route("pick"))
        assertEquals(listOf("unsupported"), route("unknown"))
    }
}
