package com.isaac.inputmethod.rimes

import android.text.InputType
import android.view.inputmethod.EditorInfo
import com.isaac.inputmethod.rimes.input.CompositionSession
import com.isaac.inputmethod.rimes.input.Delivery
import com.isaac.inputmethod.rimes.input.HostMarkedTextPresentation
import com.isaac.inputmethod.rimes.input.HostMarkedTextPresentationRules
import com.isaac.inputmethod.rimes.input.SecureInputRules
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CompositionRulesTest {
    @Test
    fun utf8ByteOffsetsBecomeUtf16Offsets() {
        assertEquals(0, CompositionSession.utf16Offset(0, "你好"))
        assertEquals(1, CompositionSession.utf16Offset(3, "你好"))
        assertEquals(2, CompositionSession.utf16Offset(6, "你好"))
        assertEquals(2, CompositionSession.utf16Offset(99, "你好"))
        assertEquals(3, CompositionSession.utf16Offset(3, "ni h"))
    }

    @Test
    fun presentationRulesMatchTheMacOSContract() {
        assertEquals(HostMarkedTextPresentation.NONE, HostMarkedTextPresentationRules.presentation(bufferCapturesInput = true, secureInput = true))
        assertEquals(HostMarkedTextPresentation.BUFFER_PROJECTED, HostMarkedTextPresentationRules.presentation(bufferCapturesInput = true, secureInput = false))
        assertEquals(HostMarkedTextPresentation.NORMAL_PREEDIT, HostMarkedTextPresentationRules.presentation(bufferCapturesInput = false, secureInput = false))
    }

    @Test
    fun compositionSessionTracksMarkedTextLifecycle() {
        val host = FakeHost()
        val session = CompositionSession(decorate = { it })
        session.update("ni hao", 6, host)
        assertTrue(session.markedTextActive)
        assertEquals(listOf("ni hao"), host.composing)
        session.commitDidInsert()
        assertFalse(session.composing)
        session.update("", 0, host) // empty preedit clears (no-op when already inactive)
        assertEquals(0, host.finishCount)
        session.update("x", 1, host)
        session.clear(host)
        assertEquals(1, host.finishCount)
        assertEquals(listOf("ni hao", "x", ""), host.composing)
    }

    @Test
    fun secureFieldsAreDetectedFromInputType() {
        fun info(type: Int) = EditorInfo().apply { inputType = type }
        assertTrue(SecureInputRules.isSecure(info(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)))
        assertTrue(SecureInputRules.isSecure(info(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD)))
        assertTrue(SecureInputRules.isSecure(info(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD)))
        assertTrue(SecureInputRules.isSecure(info(InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD)))
        assertFalse(SecureInputRules.isSecure(info(InputType.TYPE_CLASS_TEXT)))
        assertFalse(SecureInputRules.isSecure(info(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS)))
        assertFalse(SecureInputRules.isSecure(null))
    }

    @Test
    fun deliveryRefusesBufferedTextInSecureFields() {
        val secure = FakeHost(secureInput = true)
        assertFalse(Delivery.insert("你好", secure))
        assertTrue(secure.committed.isEmpty())
        assertTrue(Delivery.insert("a", secure, allowSecure = true))
        assertEquals(listOf("a"), secure.committed)
        val plain = FakeHost()
        assertTrue(Delivery.insert("", plain))
        assertTrue(Delivery.insert("你好", plain))
        assertEquals(listOf("你好"), plain.committed)
    }
}
