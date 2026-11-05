package app.ncloud.ncloud

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.rule.GrantPermissionRule
import io.flutter.embedding.engine.FlutterEngine
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SyncUploadServiceTest {
    @get:Rule
    val notifications: GrantPermissionRule =
        GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS)

    private fun awaitState(message: String, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 10000
        while (!condition() && System.currentTimeMillis() < deadline) Thread.sleep(50)
        assertTrue(message, condition())
    }

    @Test
    fun notificationAndEngineSurviveClosedActivityAndReattachUntilStopped() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        var scenario = ActivityScenario.launch(MainActivity::class.java)
        var retained: FlutterEngine? = null
        val ready = CountDownLatch(1)
        var startError: String? = "Not started"
        try {
            scenario.onActivity { activity ->
                retained = SyncUploadService.engine
                assertNotNull(retained)
                SyncUploadService.ready = { error -> startError = error; ready.countDown() }
                activity.startForegroundService(Intent(activity, SyncUploadService::class.java))
            }
            assertTrue("Service did not report readiness", ready.await(20, TimeUnit.SECONDS))
            assertNull(startError)
            assertTrue(SyncUploadService.running)
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            awaitState("The foreground upload notification with Pause did not appear") {
                manager.activeNotifications.any { it.notification.actions?.any { action ->
                    action.title.toString() == "Pause"
                } == true }
            }

            scenario.close()
            assertFalse(SyncUploadService.hostAttached)
            assertSame(retained, SyncUploadService.engine)
            assertTrue(retained!!.dartExecutor.isExecutingDart)
            assertTrue(SyncUploadService.running)

            scenario = ActivityScenario.launch(MainActivity::class.java)
            scenario.onActivity {
                assertTrue(SyncUploadService.hostAttached)
                assertSame(retained, SyncUploadService.engine)
            }
            SyncUploadService.finishing = true
            context.stopService(Intent(context, SyncUploadService::class.java))
            awaitState("Service or upload notification remained after stop") {
                !SyncUploadService.running && manager.activeNotifications.isEmpty()
            }
        } finally {
            SyncUploadService.finishing = true
            context.stopService(Intent(context, SyncUploadService::class.java))
            scenario.close()
        }
    }
}
