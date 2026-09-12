package com.isaac.inputmethod.rimes.input

import android.text.SpannableString
import android.text.Spanned
import android.text.style.UnderlineSpan

enum class HostMarkedTextPresentation { NONE, NORMAL_PREEDIT, BUFFER_PROJECTED }

/**
 * Host composing-text policy, kept separate from buffer delivery and from
 * Rime's semantic composition state (port of the macOS rules). Android hosts
 * do not need the U+200B idle guard because the IME window owns Return and
 * Backspace outright, so the buffer case simply projects the preedit into the
 * workbench rail instead of the host.
 */
object HostMarkedTextPresentationRules {
    fun presentation(bufferCapturesInput: Boolean, secureInput: Boolean): HostMarkedTextPresentation = when {
        secureInput -> HostMarkedTextPresentation.NONE
        bufferCapturesInput -> HostMarkedTextPresentation.BUFFER_PROJECTED
        else -> HostMarkedTextPresentation.NORMAL_PREEDIT
    }
}

/**
 * A composing-text session ALWAYS exists in the host while Rime is composing
 * in direct mode. Without one, hosts echo nothing but also cannot show
 * inline preedit; with one, `commitText` atomically replaces it.
 */
class CompositionSession(
    private val decorate: (String) -> CharSequence = ::underlined,
) {
    var markedTextActive = false
        private set
    var composing = false
        private set

    /** Reflect the current Rime preedit into the host's composing text. `cursorPosUTF8` is librime's byte offset. */
    fun update(preedit: String, cursorPosUTF8: Int, client: HostClient) {
        if (preedit.isEmpty()) {
            clear(client)
            return
        }
        markedTextActive = true
        composing = true
        client.setComposingText(decorate(preedit), utf16Offset(cursorPosUTF8, preedit))
    }

    /** End the session explicitly (escape / focus loss / commit without insert). */
    fun clear(client: HostClient) {
        if (!markedTextActive) return
        markedTextActive = false
        composing = false
        client.setComposingText("", 0)
        client.finishComposingText()
    }

    /** commitText replaces the composing text atomically and closes the session. */
    fun commitDidInsert() {
        markedTextActive = false
        composing = false
    }

    /** Session died with its client (focus already gone); just drop the flags. */
    fun markCleared() {
        markedTextActive = false
        composing = false
    }

    companion object {
        fun underlined(preedit: String): CharSequence {
            val spannable = SpannableString(preedit)
            spannable.setSpan(UnderlineSpan(), 0, spannable.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            return spannable
        }

        fun utf16Offset(byteOffset: Int, text: String): Int {
            if (byteOffset <= 0) return 0
            val bytes = text.toByteArray(Charsets.UTF_8)
            if (byteOffset >= bytes.size) return text.length
            return String(bytes, 0, byteOffset, Charsets.UTF_8).length
        }
    }
}
