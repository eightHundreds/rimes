package com.isaac.inputmethod.rimes.settings

import android.content.SharedPreferences
import com.isaac.inputmethod.rimes.input.InputTelemetrySink
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The 统计 and 打字测速 extensions, reduced to what Android can observe: key
 * counts, committed character counts and active minutes per day. Only
 * aggregates are stored; no text, no field identity, no per-app breakdown.
 */
class StatisticsStore(private val prefs: SharedPreferences) : InputTelemetrySink {
    data class DaySummary(val day: String, val keys: Long, val chars: Long, val commits: Long, val activeMinutes: Long) {
        /** Characters per active minute, the typing-speed extension's headline figure. */
        val charsPerMinute: Double get() = if (activeMinutes == 0L) 0.0 else chars.toDouble() / activeMinutes
    }

    var enabled: Boolean
        get() = prefs.getBoolean(KEY_ENABLED, true)
        set(value) = prefs.edit().putBoolean(KEY_ENABLED, value).apply()

    private val dayFormat = SimpleDateFormat("yyyy-MM-dd", Locale.US)
    private var lastActiveMinute = -1L

    override fun recordKey(keycode: Int) {
        if (!enabled) return
        bump("keys", 1)
        val minute = System.currentTimeMillis() / 60_000
        if (minute != lastActiveMinute) {
            lastActiveMinute = minute
            bump("minutes", 1)
        }
    }

    override fun recordCommit(characterCount: Int, toBuffer: Boolean) {
        if (!enabled || characterCount <= 0) return
        bump("chars", characterCount.toLong())
        bump("commits", 1)
        if (toBuffer) bump("bufferCommits", 1)
    }

    fun today(): DaySummary = summary(dayFormat.format(Date()))

    fun summary(day: String): DaySummary {
        val json = read().optJSONObject(day) ?: JSONObject()
        return DaySummary(
            day = day,
            keys = json.optLong("keys"),
            chars = json.optLong("chars"),
            commits = json.optLong("commits"),
            activeMinutes = json.optLong("minutes"),
        )
    }

    fun recentDays(limit: Int = 14): List<DaySummary> {
        val json = read()
        return json.keys().asSequence().toList().sortedDescending().take(limit).map { summary(it) }
    }

    fun totals(): DaySummary {
        val all = recentDays(Int.MAX_VALUE)
        return DaySummary(
            day = "total",
            keys = all.sumOf { it.keys },
            chars = all.sumOf { it.chars },
            commits = all.sumOf { it.commits },
            activeMinutes = all.sumOf { it.activeMinutes },
        )
    }

    fun clear() {
        prefs.edit().remove(KEY_DATA).apply()
    }

    @Synchronized
    private fun bump(field: String, delta: Long) {
        val root = read()
        val day = dayFormat.format(Date())
        val entry = root.optJSONObject(day) ?: JSONObject()
        entry.put(field, entry.optLong(field) + delta)
        root.put(day, entry)
        // Keep the store bounded: 400 days is plenty for a year heatmap.
        val keys = root.keys().asSequence().toList().sorted()
        if (keys.size > 400) keys.take(keys.size - 400).forEach { root.remove(it) }
        prefs.edit().putString(KEY_DATA, root.toString()).apply()
    }

    private fun read(): JSONObject = runCatching { JSONObject(prefs.getString(KEY_DATA, null) ?: "{}") }.getOrDefault(JSONObject())

    companion object {
        const val KEY_ENABLED = "statistics.enabled.v1"
        const val KEY_DATA = "statistics.days.v1"
    }
}
