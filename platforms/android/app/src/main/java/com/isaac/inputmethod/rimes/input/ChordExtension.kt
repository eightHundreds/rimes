package com.isaac.inputmethod.rimes.input

import android.content.SharedPreferences
import com.isaac.inputmethod.rimes.IMELog
import java.util.concurrent.CopyOnWriteArrayList

/** The two settlement behaviours supplied by the optional chord extension. */
enum class ChordExtensionMode(val title: String, val implementationName: String) {
    CHORD("并击", "飞耀并击"),
    MUTUAL("互击", "飞耀互击");

    val settlementPolicy: FlyChordSettlementPolicy
        get() = when (this) {
            CHORD -> FlyChordSettlementPolicy.SAME_BATCH_ONLY
            MUTUAL -> FlyChordSettlementPolicy.INDEPENDENT_HALVES
        }
}

data class ChordExtensionConfiguration(
    val isEnabled: Boolean,
    val mode: ChordExtensionMode,
    val durationMillis: Long,
)

/**
 * User-tunable 并击 release window. Single source of truth (mirrors
 * `ChordSettings` on macOS; the squirrel.yaml migration does not apply here).
 */
object ChordSettings {
    const val DEFAULT_DURATION_MS = 100L
    val RANGE_MS = 20L..500L

    fun clamp(value: Long): Long = value.coerceIn(RANGE_MS)
}

/**
 * Authoritative product state for the optional “并击” extension. Enablement
 * is not inferred from the active schema: the extension may be enabled while
 * an ordinary schema is selected.
 */
class ChordExtensionStore(private val prefs: SharedPreferences) {
    fun interface Listener {
        fun chordExtensionDidChange(previous: ChordExtensionConfiguration, current: ChordExtensionConfiguration, source: String)
    }

    private val listeners = CopyOnWriteArrayList<Listener>()

    /** Installed by [InputConfigurationStore] so disabling retires a selected FlyYao schema first. */
    var fallbackBeforeDisable: (() -> Unit)? = null

    fun addListener(listener: Listener) = listeners.addIfAbsent(listener)
    fun removeListener(listener: Listener) = listeners.remove(listener)

    val isEnabled: Boolean get() = prefs.getBoolean(KEY_ENABLED, false)

    val mode: ChordExtensionMode
        get() = prefs.getString(KEY_MODE, null)
            ?.let { raw -> ChordExtensionMode.entries.firstOrNull { it.name == raw } }
            ?: ChordExtensionMode.MUTUAL

    val durationMillis: Long
        get() = if (prefs.contains(KEY_DURATION)) ChordSettings.clamp(prefs.getLong(KEY_DURATION, ChordSettings.DEFAULT_DURATION_MS))
        else ChordSettings.DEFAULT_DURATION_MS

    val configuration: ChordExtensionConfiguration
        get() = ChordExtensionConfiguration(isEnabled, mode, durationMillis)

    fun setEnabled(enabled: Boolean, source: String = "user"): Boolean {
        val previous = configuration
        if (previous.isEnabled == enabled) return false
        if (!enabled) fallbackBeforeDisable?.invoke()
        prefs.edit().putBoolean(KEY_ENABLED, enabled).apply()
        publish(previous, source)
        return true
    }

    fun setMode(mode: ChordExtensionMode, source: String = "user"): Boolean {
        val previous = configuration
        if (previous.mode == mode) return false
        prefs.edit().putString(KEY_MODE, mode.name).apply()
        publish(previous, source)
        return true
    }

    fun setDurationMillis(value: Long, source: String = "user") {
        val previous = configuration
        val clamped = ChordSettings.clamp(value)
        prefs.edit().putLong(KEY_DURATION, clamped).apply()
        IMELog.write("chord_duration=${clamped}ms source=preference")
        publish(previous, source)
    }

    fun resetDuration() {
        val previous = configuration
        prefs.edit().remove(KEY_DURATION).apply()
        publish(previous, "user")
    }

    private fun publish(previous: ChordExtensionConfiguration, source: String) {
        val current = configuration
        if (previous == current) return
        IMELog.write("chord_extension enabled=${current.isEnabled} mode=${current.mode} source=$source")
        listeners.forEach { it.chordExtensionDidChange(previous, current, source) }
    }

    companion object {
        const val KEY_ENABLED = "chord.extension.enabled.v1"
        const val KEY_MODE = "chord.extension.mode.v1"
        const val KEY_DURATION = "chord.duration.ms.v1"
        const val SCHEMA_ID = InputSchemaCatalog.CHORD_SCHEMA_ID
    }
}
