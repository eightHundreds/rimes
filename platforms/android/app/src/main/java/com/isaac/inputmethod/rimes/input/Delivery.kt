package com.isaac.inputmethod.rimes.input

import com.isaac.inputmethod.rimes.IMELog

/**
 * The SOLE place text reaches the host field. Every commit — ordinary, chord
 * release, raw fallback, or buffer flush — goes through here so ordering is
 * guaranteed and the secure-input backstop is always applied.
 */
object Delivery {
    /**
     * Inserts `text` into the bound field unless it is a password field.
     * Returns whether the text was actually inserted so the buffer can keep
     * unsent blocks instead of dropping them.
     *
     * `allowSecure` is only set by the direct ASCII passthrough that types
     * exactly what the user pressed into a password field; buffered or
     * transformed text never lands there.
     */
    fun insert(text: String, client: HostClient, allowSecure: Boolean = false): Boolean {
        if (text.isEmpty()) return true
        if (client.secureInput && !allowSecure) {
            IMELog.write("delivery blocked: secure input active len=${text.length}")
            return false
        }
        client.commitText(text)
        return true
    }
}
