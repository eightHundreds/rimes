package com.isaac.inputmethod.rimes

import android.view.KeyEvent
import com.isaac.inputmethod.rimes.rime.RimeKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RimeKeyTest {
    @Test
    fun keysymConstantsMatchTheOtherPlatforms() {
        // Byte-identical to RimeKey.swift and key_translation.cpp.
        assertEquals(0xff08, RimeKey.BACKSPACE)
        assertEquals(0xff0d, RimeKey.RETURN)
        assertEquals(0xff1b, RimeKey.ESCAPE)
        assertEquals(0xffbe, RimeKey.F1)
        assertEquals(0xffe1, RimeKey.SHIFT_L)
        assertEquals(1 shl 30, RimeKey.RELEASE_MASK)
        assertEquals(1 shl 6, RimeKey.SUPER_MASK)
    }

    @Test
    fun androidKeyCodesMapToKeysyms() {
        assertEquals('a'.code, RimeKey.fromKeyCode(KeyEvent.KEYCODE_A))
        assertEquals('z'.code, RimeKey.fromKeyCode(KeyEvent.KEYCODE_Z))
        assertEquals('7'.code, RimeKey.fromKeyCode(KeyEvent.KEYCODE_7))
        assertEquals(RimeKey.SPACE, RimeKey.fromKeyCode(KeyEvent.KEYCODE_SPACE))
        assertEquals(RimeKey.BACKSPACE, RimeKey.fromKeyCode(KeyEvent.KEYCODE_DEL))
        assertEquals(RimeKey.RETURN, RimeKey.fromKeyCode(KeyEvent.KEYCODE_ENTER))
        assertEquals(RimeKey.F1 + 3, RimeKey.fromKeyCode(KeyEvent.KEYCODE_F4))
        assertEquals(RimeKey.KEYPAD_0 + 5, RimeKey.fromKeyCode(KeyEvent.KEYCODE_NUMPAD_5))
        assertEquals(','.code, RimeKey.fromKeyCode(KeyEvent.KEYCODE_COMMA))
        assertEquals('`'.code, RimeKey.fromKeyCode(KeyEvent.KEYCODE_GRAVE))
        assertNull(RimeKey.fromKeyCode(KeyEvent.KEYCODE_VOLUME_UP))
    }

    @Test
    fun modifierMaskFollowsX11Bits() {
        assertEquals(RimeKey.SHIFT_MASK, RimeKey.modifierMask(KeyEvent.META_SHIFT_ON))
        assertEquals(RimeKey.CONTROL_MASK, RimeKey.modifierMask(KeyEvent.META_CTRL_ON))
        assertEquals(RimeKey.ALT_MASK, RimeKey.modifierMask(KeyEvent.META_ALT_ON))
        assertEquals(RimeKey.SUPER_MASK, RimeKey.modifierMask(KeyEvent.META_META_ON))
        assertEquals(RimeKey.LOCK_MASK, RimeKey.modifierMask(KeyEvent.META_CAPS_LOCK_ON))
        assertEquals(RimeKey.SHIFT_MASK or RimeKey.CONTROL_MASK, RimeKey.modifierMask(KeyEvent.META_SHIFT_ON or KeyEvent.META_CTRL_ON))
    }

    @Test
    fun scalarsMapLikeMacOS() {
        assertEquals(RimeKey.BACKSPACE, RimeKey.fromScalar(0x7f))
        assertEquals(RimeKey.RETURN, RimeKey.fromScalar(0x0a))
        assertEquals('A'.code, RimeKey.fromScalar('A'.code))
        assertNull(RimeKey.fromScalar(0x4E2D))
    }

    @Test
    fun chordMaterialIsLettersCommaPeriod() {
        assertTrue(RimeKey.isChordingKey('q'.code))
        assertTrue(RimeKey.isChordingKey(','.code))
        assertTrue(RimeKey.isChordingKey('.'.code))
        assertFalse(RimeKey.isChordingKey('1'.code))
        assertFalse(RimeKey.isChordingKey(RimeKey.SPACE))
        assertTrue(RimeKey.hasCommandModifier(RimeKey.CONTROL_MASK))
        assertFalse(RimeKey.hasCommandModifier(RimeKey.SHIFT_MASK))
    }
}
