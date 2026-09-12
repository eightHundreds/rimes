package com.isaac.inputmethod.rimes.input

import android.text.InputType
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection

/**
 * Identity of the exact text field the input method is bound to. Android has
 * no IMK client proxy; the analogue of macOS `FocusToken` is the package plus
 * field id plus a monotonically increasing bind generation. Any stale token
 * fails closed in buffer delivery.
 */
data class FocusToken(
    val packageName: String,
    val fieldId: Int,
    val generation: Long,
) {
    override fun toString(): String = "$packageName#$fieldId@$generation"
}

/**
 * Android's equivalent of macOS secure input: password variations of the
 * text input type. While one is focused, Rime composition is bypassed, the
 * buffer never captures or delivers, and nothing about the field is logged.
 */
object SecureInputRules {
    fun isSecure(editorInfo: EditorInfo?): Boolean {
        val inputType = editorInfo?.inputType ?: return false
        val klass = inputType and InputType.TYPE_MASK_CLASS
        val variation = inputType and InputType.TYPE_MASK_VARIATION
        if (klass == InputType.TYPE_CLASS_TEXT) {
            return variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
        }
        if (klass == InputType.TYPE_CLASS_NUMBER) {
            return variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
        }
        return false
    }
}

/**
 * The narrow view of a bound text field used by the composition session and
 * the delivery path. Production wraps [InputConnection]; tests use a fake.
 */
interface HostClient {
    val token: FocusToken
    val secureInput: Boolean

    /** Marked-text equivalent. `caret` is a UTF-16 offset into `text`. */
    fun setComposingText(text: CharSequence, caret: Int)
    fun finishComposingText()
    fun commitText(text: CharSequence)
    fun deleteSurroundingText(before: Int, after: Int)
    fun sendKeyEvent(androidKeyCode: Int)
    fun performEditorAction(): Boolean
}

class InputConnectionHost(
    private val connection: InputConnection,
    override val token: FocusToken,
    override val secureInput: Boolean,
    private val editorInfo: EditorInfo?,
) : HostClient {
    override fun setComposingText(text: CharSequence, caret: Int) {
        // InputConnection cannot place the host caret strictly inside the
        // composing span without an absolute selection index, so the caret
        // always sits after the preedit; the in-preedit caret is rendered in the
        // candidate bar instead (see CandidateBarView).
        connection.setComposingText(text, 1)
    }

    override fun finishComposingText() {
        connection.finishComposingText()
    }

    override fun commitText(text: CharSequence) {
        connection.commitText(text, 1)
    }

    override fun deleteSurroundingText(before: Int, after: Int) {
        connection.deleteSurroundingText(before, after)
    }

    override fun sendKeyEvent(androidKeyCode: Int) {
        connection.sendKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, androidKeyCode))
        connection.sendKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, androidKeyCode))
    }

    override fun performEditorAction(): Boolean {
        val info = editorInfo ?: return false
        val action = info.imeOptions and EditorInfo.IME_MASK_ACTION
        val noEnterAction = info.imeOptions and EditorInfo.IME_FLAG_NO_ENTER_ACTION != 0
        if (action == EditorInfo.IME_ACTION_NONE || action == EditorInfo.IME_ACTION_UNSPECIFIED || noEnterAction) {
            return false
        }
        return connection.performEditorAction(action)
    }
}
