package com.isaac.inputmethod.rimes

import android.content.Intent
import android.view.KeyEvent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import com.isaac.inputmethod.rimes.settings.PlaygroundActivity
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.TimeUnit

/**
 * End to end through the real Android input pipeline: RIMES is enabled and
 * selected as the default IME with shell privileges, the playground field is
 * focused, physical key events are injected by the system, and the committed
 * text is read back from the host EditText.
 */
@RunWith(AndroidJUnit4::class)
class TypingEndToEndTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val device: UiDevice = UiDevice.getInstance(instrumentation)
    private val packageName = instrumentation.targetContext.packageName
    private val fieldSelector = By.res(packageName, "playground_field")
    private val passwordSelector = By.res(packageName, "playground_password")

    companion object {
        private const val IME_ID = "com.isaac.inputmethod.rimes/.service.RimesInputMethodService"

        @BeforeClass
        @JvmStatic
        fun deployBeforeTyping() {
            val app = RimesApplication.of(InstrumentationRegistry.getInstrumentation().targetContext)
            assertTrue(app.startEngineAsync().get(40, TimeUnit.MINUTES))
            val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
            device.executeShellCommand("ime enable $IME_ID")
            device.executeShellCommand("ime set $IME_ID")
            device.executeShellCommand("settings put secure show_ime_with_hard_keyboard 1")
        }
    }

    @Before
    fun launchPlayground() {
        val app = RimesApplication.of(instrumentation.targetContext)
        app.prefs.edit().putBoolean(RimesPreferences.BUFFER_ENABLED, false).apply()
        device.pressHome()
        val intent = Intent(instrumentation.targetContext, PlaygroundActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        instrumentation.targetContext.startActivity(intent)
        assertTrue(device.wait(Until.hasObject(fieldSelector), 60_000))
        val field = device.findObject(fieldSelector)
        field.click()
        device.waitForIdle()
        clearField()
    }

    @After
    fun leave() {
        device.pressBack()
        device.pressHome()
    }

    private fun clearField() {
        val field = device.findObject(fieldSelector)
        field.text = ""
        device.waitForIdle()
    }

    private fun press(vararg keyCodes: Int) {
        for (code in keyCodes) {
            device.pressKeyCode(code)
            device.waitForIdle()
        }
    }

    private fun fieldText(): String = device.findObject(fieldSelector).text ?: ""

    private fun waitForFieldText(expected: String, timeoutMs: Long = 30_000) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (fieldText() == expected) return
            Thread.sleep(300)
        }
        assertEquals(expected, fieldText())
    }

    @Test
    fun typingPinyinAndSpaceCommitsChinese() {
        press(KeyEvent.KEYCODE_N, KeyEvent.KEYCODE_I, KeyEvent.KEYCODE_H, KeyEvent.KEYCODE_A, KeyEvent.KEYCODE_O)
        // Composing text is visible in the host while Rime is active.
        val deadline = System.currentTimeMillis() + 30_000
        while (System.currentTimeMillis() < deadline && !fieldText().replace(" ", "").contains("nihao")) Thread.sleep(300)
        assertTrue("expected inline preedit, got '${fieldText()}'", fieldText().replace(" ", "").contains("nihao"))
        press(KeyEvent.KEYCODE_SPACE)
        waitForFieldText("你好")
    }

    @Test
    fun digitSelectsCandidateAndReturnCommitsRaw() {
        press(KeyEvent.KEYCODE_S, KeyEvent.KEYCODE_H, KeyEvent.KEYCODE_I, KeyEvent.KEYCODE_J, KeyEvent.KEYCODE_I, KeyEvent.KEYCODE_E)
        press(KeyEvent.KEYCODE_1)
        waitForFieldText("世界")
        press(KeyEvent.KEYCODE_A, KeyEvent.KEYCODE_B, KeyEvent.KEYCODE_C, KeyEvent.KEYCODE_ENTER)
        waitForFieldText("世界abc")
    }

    @Test
    fun backspaceEditsCompositionBeforeTheHost() {
        press(KeyEvent.KEYCODE_N, KeyEvent.KEYCODE_I, KeyEvent.KEYCODE_X)
        press(KeyEvent.KEYCODE_DEL)
        press(KeyEvent.KEYCODE_SPACE)
        waitForFieldText("你")
        press(KeyEvent.KEYCODE_DEL)
        waitForFieldText("")
    }

    @Test
    fun passwordFieldsBypassRime() {
        val password = device.findObject(passwordSelector)
        password.click()
        device.waitForIdle()
        press(KeyEvent.KEYCODE_N, KeyEvent.KEYCODE_I)
        val deadline = System.currentTimeMillis() + 30_000
        var text = ""
        while (System.currentTimeMillis() < deadline) {
            text = device.findObject(passwordSelector).text ?: ""
            if (text.length == 2) break
            Thread.sleep(300)
        }
        // UiAutomator reads password fields as masked dots; only the length is observable.
        assertEquals(2, text.length)
        device.findObject(passwordSelector).text = ""
    }
}
