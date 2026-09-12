package com.isaac.inputmethod.rimes.rime

import android.view.KeyCharacterMap
import android.view.KeyEvent

/**
 * X11/ibus keysyms + modifier masks that librime's `process_key` expects.
 * Values are byte-identical to `RimeKey.swift` (macOS) and
 * `key_translation.cpp` (Windows); the `1 << 30` release mask is how chord
 * release is signalled to Rime.
 */
object RimeKey {
    const val SHIFT_MASK = 1 shl 0
    const val LOCK_MASK = 1 shl 1
    const val CONTROL_MASK = 1 shl 2
    const val ALT_MASK = 1 shl 3
    const val MOD2_MASK = 1 shl 4 // Num Lock
    const val SUPER_MASK = 1 shl 6
    const val RELEASE_MASK = 1 shl 30

    const val BACKSPACE = 0xff08
    const val TAB = 0xff09
    const val RETURN = 0xff0d
    const val ESCAPE = 0xff1b
    const val SPACE = 0x20
    const val DELETE_FORWARD = 0xffff
    const val HOME = 0xff50
    const val LEFT = 0xff51
    const val UP = 0xff52
    const val RIGHT = 0xff53
    const val DOWN = 0xff54
    const val PAGE_UP = 0xff55
    const val PAGE_DOWN = 0xff56
    const val END = 0xff57
    const val INSERT = 0xff63
    const val MENU = 0xff67
    const val KEYPAD_ENTER = 0xff8d
    const val KEYPAD_0 = 0xffb0
    const val F1 = 0xffbe
    const val SHIFT_L = 0xffe1
    const val SHIFT_R = 0xffe2
    const val CONTROL_L = 0xffe3
    const val CONTROL_R = 0xffe4
    const val CAPS_LOCK = 0xffe5
    const val ALT_L = 0xffe9
    const val ALT_R = 0xffea
    const val SUPER_L = 0xffeb
    const val SUPER_R = 0xffec

    const val COMMAND_MODIFIERS = CONTROL_MASK or ALT_MASK or SUPER_MASK

    /** Printable ASCII scalar -> keysym (identity for 0x20..0x7e). */
    fun fromScalar(scalar: Int): Int? = when (scalar) {
        0x08, 0x7f -> BACKSPACE
        0x09 -> TAB
        0x0a, 0x0d -> RETURN
        0x1b -> ESCAPE
        in 0x20..0x7e -> scalar
        else -> null
    }

    fun fromChar(char: Char): Int? = fromScalar(char.code)

    /**
     * Android hardware key -> keysym. Letters honour the event's own Unicode
     * character when it is printable ASCII so keyboard layouts and Shift are
     * respected; everything else is a table lookup on the Android keycode.
     */
    fun fromKeyEvent(event: KeyEvent): Int? {
        val unicode = event.unicodeChar
        if (unicode and KeyCharacterMap.COMBINING_ACCENT == 0 && unicode in 0x20..0x7e) {
            // Keys carrying Ctrl/Alt keep their base printable keysym; the
            // modifier travels separately in Rime's mask.
            return unicode
        }
        if (event.metaState and (KeyEvent.META_CTRL_MASK or KeyEvent.META_ALT_MASK or KeyEvent.META_META_MASK) != 0) {
            val base = event.getUnicodeChar(0)
            if (base in 0x20..0x7e) return base
        }
        return fromKeyCode(event.keyCode)
    }

    fun fromKeyCode(keyCode: Int): Int? = when (keyCode) {
        in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z -> 'a'.code + (keyCode - KeyEvent.KEYCODE_A)
        in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9 -> '0'.code + (keyCode - KeyEvent.KEYCODE_0)
        in KeyEvent.KEYCODE_NUMPAD_0..KeyEvent.KEYCODE_NUMPAD_9 -> KEYPAD_0 + (keyCode - KeyEvent.KEYCODE_NUMPAD_0)
        in KeyEvent.KEYCODE_F1..KeyEvent.KEYCODE_F12 -> F1 + (keyCode - KeyEvent.KEYCODE_F1)
        KeyEvent.KEYCODE_SPACE -> SPACE
        KeyEvent.KEYCODE_DEL -> BACKSPACE
        KeyEvent.KEYCODE_FORWARD_DEL -> DELETE_FORWARD
        KeyEvent.KEYCODE_TAB -> TAB
        KeyEvent.KEYCODE_ENTER -> RETURN
        KeyEvent.KEYCODE_NUMPAD_ENTER -> KEYPAD_ENTER
        KeyEvent.KEYCODE_ESCAPE -> ESCAPE
        KeyEvent.KEYCODE_MOVE_HOME -> HOME
        KeyEvent.KEYCODE_MOVE_END -> END
        KeyEvent.KEYCODE_DPAD_LEFT -> LEFT
        KeyEvent.KEYCODE_DPAD_RIGHT -> RIGHT
        KeyEvent.KEYCODE_DPAD_UP -> UP
        KeyEvent.KEYCODE_DPAD_DOWN -> DOWN
        KeyEvent.KEYCODE_PAGE_UP -> PAGE_UP
        KeyEvent.KEYCODE_PAGE_DOWN -> PAGE_DOWN
        KeyEvent.KEYCODE_INSERT -> INSERT
        KeyEvent.KEYCODE_MENU -> MENU
        KeyEvent.KEYCODE_SHIFT_LEFT -> SHIFT_L
        KeyEvent.KEYCODE_SHIFT_RIGHT -> SHIFT_R
        KeyEvent.KEYCODE_CTRL_LEFT -> CONTROL_L
        KeyEvent.KEYCODE_CTRL_RIGHT -> CONTROL_R
        KeyEvent.KEYCODE_ALT_LEFT -> ALT_L
        KeyEvent.KEYCODE_ALT_RIGHT -> ALT_R
        KeyEvent.KEYCODE_META_LEFT -> SUPER_L
        KeyEvent.KEYCODE_META_RIGHT -> SUPER_R
        KeyEvent.KEYCODE_CAPS_LOCK -> CAPS_LOCK
        KeyEvent.KEYCODE_COMMA -> ','.code
        KeyEvent.KEYCODE_PERIOD -> '.'.code
        KeyEvent.KEYCODE_MINUS -> '-'.code
        KeyEvent.KEYCODE_EQUALS -> '='.code
        KeyEvent.KEYCODE_LEFT_BRACKET -> '['.code
        KeyEvent.KEYCODE_RIGHT_BRACKET -> ']'.code
        KeyEvent.KEYCODE_BACKSLASH -> '\\'.code
        KeyEvent.KEYCODE_SEMICOLON -> ';'.code
        KeyEvent.KEYCODE_APOSTROPHE -> '\''.code
        KeyEvent.KEYCODE_GRAVE -> '`'.code
        KeyEvent.KEYCODE_SLASH -> '/'.code
        else -> null
    }

    fun modifierMask(metaState: Int): Int {
        var mask = 0
        if (metaState and KeyEvent.META_SHIFT_MASK != 0) mask = mask or SHIFT_MASK
        if (metaState and KeyEvent.META_CAPS_LOCK_ON != 0) mask = mask or LOCK_MASK
        if (metaState and KeyEvent.META_CTRL_MASK != 0) mask = mask or CONTROL_MASK
        if (metaState and KeyEvent.META_ALT_MASK != 0) mask = mask or ALT_MASK
        if (metaState and KeyEvent.META_NUM_LOCK_ON != 0) mask = mask or MOD2_MASK
        if (metaState and KeyEvent.META_META_MASK != 0) mask = mask or SUPER_MASK
        return mask
    }

    fun isModifierKeysym(keycode: Int): Boolean = keycode in SHIFT_L..SUPER_R

    /** Chord material: plain presses of `a`..`z`, `,` and `.` (identical to macOS). */
    fun isChordingKey(keycode: Int): Boolean =
        keycode in 'a'.code..'z'.code || keycode == ','.code || keycode == '.'.code

    fun isPrintable(keycode: Int): Boolean = keycode in 0x20..0x7e

    fun hasCommandModifier(mask: Int): Boolean = mask and COMMAND_MODIFIERS != 0
}
