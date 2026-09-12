package com.isaac.inputmethod.rimes

import android.content.SharedPreferences
import com.isaac.inputmethod.rimes.input.ChordController
import com.isaac.inputmethod.rimes.input.FocusToken
import com.isaac.inputmethod.rimes.input.HostClient
import com.isaac.inputmethod.rimes.rime.RimeCandidateModel
import com.isaac.inputmethod.rimes.rime.RimeContextModel
import com.isaac.inputmethod.rimes.rime.RimeEngineApi
import com.isaac.inputmethod.rimes.rime.RimeKey
import com.isaac.inputmethod.rimes.rime.RimeSchemaItem
import com.isaac.inputmethod.rimes.rime.RimeStatusModel

/** Records everything the input method pushes into a field. */
class FakeHost(
    override val token: FocusToken = FocusToken("com.example.app", 1, 1),
    override val secureInput: Boolean = false,
) : HostClient {
    val committed = mutableListOf<String>()
    val composing = mutableListOf<String>()
    val keyEvents = mutableListOf<Int>()
    var finishCount = 0
    var editorActions = 0

    override fun setComposingText(text: CharSequence, caret: Int) {
        composing += text.toString()
    }

    override fun finishComposingText() {
        finishCount++
    }

    override fun commitText(text: CharSequence) {
        committed += text.toString()
    }

    override fun deleteSurroundingText(before: Int, after: Int) = Unit

    override fun sendKeyEvent(androidKeyCode: Int) {
        keyEvents += androidKeyCode
    }

    override fun performEditorAction(): Boolean {
        editorActions++
        return true
    }
}

/** Deterministic timer: actions run only when the test calls [fire]. */
class ManualScheduler : ChordController.Scheduler {
    private val pending = linkedMapOf<Any, () -> Unit>()
    var lastDelay = -1L

    override fun schedule(delayMillis: Long, action: () -> Unit): Any {
        lastDelay = delayMillis
        val token = Any()
        pending[token] = action
        return token
    }

    override fun cancel(token: Any) {
        pending.remove(token)
    }

    val pendingCount: Int get() = pending.size

    fun fire() {
        val actions = pending.values.toList()
        pending.clear()
        actions.forEach { it() }
    }
}

/**
 * A scripted "librime": letters accumulate as raw input; Space converts a known
 * spelling into Chinese; Return is unhandled (the frontend commits raw); in
 * ASCII mode letters are unhandled. Chord keys are recorded so replay order
 * can be asserted. Good enough to exercise the controller's routing contract.
 */
class FakeEngine : RimeEngineApi {
    val dictionary = mutableMapOf("nihao" to "你好", "ni" to "你", "shijie" to "世界", "qy" to "轻")
    var healthy = true
    var schemaId = "rime_ice"
    var asciiMode = false
    private var nextSession = 100L
    private val sessions = mutableMapOf<Long, Session>()
    val keyLog = mutableListOf<Pair<Int, Int>>()

    class Session {
        var input = ""
        var commit: String? = null
    }

    override val isHealthy: Boolean get() = healthy
    override fun createSession(): Long {
        if (!healthy) return 0L
        val id = nextSession++
        sessions[id] = Session()
        return id
    }

    override fun destroySession(session: Long) {
        sessions.remove(session)
    }

    override fun sessionExists(session: Long): Boolean = sessions.containsKey(session)

    override fun processKey(keycode: Int, mask: Int, session: Long): Boolean {
        val s = sessions[session] ?: return false
        keyLog += keycode to mask
        if (mask and RimeKey.RELEASE_MASK != 0) return true
        if (RimeKey.hasCommandModifier(mask)) return false
        return when {
            keycode == RimeKey.SHIFT_L -> {
                asciiMode = !asciiMode
                true
            }
            keycode in 'a'.code..'z'.code || keycode == '\''.code -> {
                if (asciiMode) return false
                s.input += keycode.toChar()
                true
            }
            keycode == RimeKey.BACKSPACE -> {
                if (s.input.isEmpty()) return false
                s.input = s.input.dropLast(1)
                true
            }
            keycode == RimeKey.SPACE -> {
                if (s.input.isEmpty()) return false
                s.commit = dictionary[s.input.replace("'", "")] ?: s.input
                s.input = ""
                true
            }
            keycode == RimeKey.ESCAPE -> {
                if (s.input.isEmpty()) return false
                s.input = ""
                true
            }
            else -> false
        }
    }

    override fun commitComposition(session: Long): Boolean {
        val s = sessions[session] ?: return false
        if (s.input.isEmpty()) return false
        s.commit = dictionary[s.input] ?: s.input
        s.input = ""
        return true
    }

    override fun clearComposition(session: Long) {
        sessions[session]?.input = ""
    }

    override fun selectCandidate(onPageIndex: Int, session: Long): Boolean {
        val s = sessions[session] ?: return false
        if (s.input.isEmpty()) return false
        s.commit = (dictionary[s.input] ?: s.input) + if (onPageIndex > 0) "#$onPageIndex" else ""
        s.input = ""
        return true
    }

    override fun getOption(name: String, session: Long): Boolean = name == "ascii_mode" && asciiMode
    override fun setOption(name: String, value: Boolean, session: Long) {
        if (name == "ascii_mode") asciiMode = value
    }

    override fun selectSchema(id: String, session: Long): Boolean {
        schemaId = id
        return true
    }

    override fun takeCommit(session: Long): String? {
        val s = sessions[session] ?: return null
        val commit = s.commit
        s.commit = null
        return commit
    }

    override fun currentSchema(session: Long): String? = schemaId

    override fun getContext(session: Long): RimeContextModel {
        val s = sessions[session] ?: return RimeContextModel.EMPTY
        if (s.input.isEmpty()) return RimeContextModel.EMPTY
        val candidate = dictionary[s.input] ?: s.input
        return RimeContextModel(
            active = true,
            preedit = s.input,
            input = s.input,
            cursorPos = s.input.length,
            pageSize = 5,
            candidates = arrayOf(RimeCandidateModel(candidate, "", "1")),
        )
    }

    override fun getStatus(session: Long): RimeStatusModel =
        RimeStatusModel(schemaId = schemaId, schemaName = schemaId, asciiMode = asciiMode, composing = sessions[session]?.input?.isNotEmpty() == true)

    override fun schemaList(): List<RimeSchemaItem> = listOf(
        RimeSchemaItem("rime_ice", "雾凇拼音"),
        RimeSchemaItem("double_pinyin", "自然码双拼"),
        RimeSchemaItem("wubi86", "五笔86"),
        RimeSchemaItem("english", "English"),
        RimeSchemaItem("my_combo", "飞耀"),
    )
}

/** Minimal in-memory SharedPreferences so the stores can be tested on the JVM. */
class FakeSharedPreferences : SharedPreferences {
    private val values = mutableMapOf<String, Any?>()
    private val listeners = mutableSetOf<SharedPreferences.OnSharedPreferenceChangeListener>()

    override fun getAll(): MutableMap<String, *> = values.toMutableMap()
    override fun getString(key: String?, defValue: String?): String? = values[key] as? String ?: defValue
    override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? =
        @Suppress("UNCHECKED_CAST") (values[key] as? MutableSet<String>) ?: defValues
    override fun getInt(key: String?, defValue: Int): Int = values[key] as? Int ?: defValue
    override fun getLong(key: String?, defValue: Long): Long = values[key] as? Long ?: defValue
    override fun getFloat(key: String?, defValue: Float): Float = values[key] as? Float ?: defValue
    override fun getBoolean(key: String?, defValue: Boolean): Boolean = values[key] as? Boolean ?: defValue
    override fun contains(key: String?): Boolean = values.containsKey(key)
    override fun edit(): SharedPreferences.Editor = Editor()
    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) {
        listeners += listener
    }
    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) {
        listeners -= listener
    }

    inner class Editor : SharedPreferences.Editor {
        private val staged = mutableMapOf<String, Any?>()
        private val removed = mutableSetOf<String>()
        private var clear = false

        override fun putString(key: String, value: String?) = apply { staged[key] = value }
        override fun putStringSet(key: String, values: MutableSet<String>?) = apply { staged[key] = values }
        override fun putInt(key: String, value: Int) = apply { staged[key] = value }
        override fun putLong(key: String, value: Long) = apply { staged[key] = value }
        override fun putFloat(key: String, value: Float) = apply { staged[key] = value }
        override fun putBoolean(key: String, value: Boolean) = apply { staged[key] = value }
        override fun remove(key: String) = apply { removed += key }
        override fun clear() = apply { clear = true }
        override fun commit(): Boolean {
            apply()
            return true
        }

        override fun apply() {
            if (clear) values.clear()
            removed.forEach { values.remove(it) }
            staged.forEach { (k, v) -> if (v == null) values.remove(k) else values[k] = v }
            (removed + staged.keys).forEach { key -> listeners.forEach { it.onSharedPreferenceChanged(this@FakeSharedPreferences, key) } }
        }
    }
}
