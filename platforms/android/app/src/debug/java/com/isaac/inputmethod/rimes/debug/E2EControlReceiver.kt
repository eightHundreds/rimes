package com.isaac.inputmethod.rimes.debug

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.isaac.inputmethod.rimes.IMELog
import com.isaac.inputmethod.rimes.RimesPreferences

/**
 * Debug-build automation hook: lets the emulator E2E script flip buffer mode
 * through the same preference the settings screen writes, so the input method
 * reacts exactly as it would to a user action.
 */
class E2EControlReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_SET_BUFFER) return
        val enabled = intent.getBooleanExtra("enabled", false)
        RimesPreferences.of(context).edit().putBoolean(RimesPreferences.BUFFER_ENABLED, enabled).apply()
        IMELog.write("e2e hook: buffer enabled=$enabled")
    }

    companion object {
        const val ACTION_SET_BUFFER = "com.isaac.inputmethod.rimes.E2E_SET_BUFFER"
    }
}
