package app.ncloud.ncloud

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import app.ncloud.folders.FolderAccessPlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HeadlessFolderAccessTest {
    private fun call(plugin: FolderAccessPlugin, method: String, args: Map<String, Any> = emptyMap()): Pair<Any?, String?> {
        val ready = CountDownLatch(1)
        var value: Any? = null
        var code: String? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            plugin.onMethodCall(MethodCall(method, args), object : MethodChannel.Result {
                override fun success(result: Any?) { value = result; ready.countDown() }
                override fun error(errorCode: String, message: String?, details: Any?) { code = errorCode; ready.countDown() }
                override fun notImplemented() { code = "notImplemented"; ready.countDown() }
            })
        }
        assertTrue("Headless $method did not respond", ready.await(10, TimeUnit.SECONDS))
        return value to code
    }

    @Test
    fun automaticWorkerRegistrationRoutesSafWithoutActivityAndLocksAcrossEngines() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        lateinit var first: FlutterEngine
        lateinit var second: FlutterEngine
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            first = FlutterEngine(context)
            second = FlutterEngine(context)
        }
        try {
            assertTrue(first.plugins.has(FolderAccessPlugin::class.java))
            val one = first.plugins.get(FolderAccessPlugin::class.java) as FolderAccessPlugin
            val two = second.plugins.get(FolderAccessPlugin::class.java) as FolderAccessPlugin
            assertEquals("foreground_required", call(one, "pick").second)
            val conditions = call(one, "conditions")
            assertNull(conditions.second)
            assertTrue((conditions.first as Map<*, *>)["wifi"] is Boolean)
            assertEquals(false, call(one, "workerNotification", mapOf("id" to 12345)).first)
            val staged = call(one, "stage")
            assertNull(staged.second)
            assertTrue(File(staged.first as String).exists())
            assertNull(call(one, "discard", mapOf("staged" to staged.first!!)).second)
            val account = mapOf<String, Any>("account" to "headless-test-account")
            assertEquals(true, call(one, "acquire", account).first)
            assertEquals(false, call(two, "acquire", account).first)
            call(one, "release", account)
            assertEquals(true, call(two, "acquire", account).first)
            call(two, "release", account)
        } finally {
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                first.destroy()
                second.destroy()
            }
        }
    }
}
