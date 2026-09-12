package com.isaac.inputmethod.rimes.input

import android.content.SharedPreferences
import com.isaac.inputmethod.rimes.IMELog
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList

enum class InputEncoding(val title: String, val schemaId: String) {
    FULL_PINYIN("雾凇全拼", "rime_ice"),
    NATURAL_DOUBLE_PINYIN("自然码双拼", "double_pinyin"),
    XIAOHE_DOUBLE_PINYIN("小鹤双拼", "double_pinyin_flypy"),
    WUBI86("五笔86", "wubi86"),
    ENGLISH("英文", "english"),
}

/** Which learned user dictionary a schema writes to (`user_dict` name). */
enum class LexiconFamily(val dictName: String, val title: String) {
    CHINESE("rime_ice", "雾凇拼音"),
    WUBI86("wubi86", "五笔86"),
    ENGLISH("english", "Easy English"),
}

data class InputSchemaOption(
    val id: String,
    val name: String,
    val detail: String,
    val lexiconFamily: LexiconFamily,
    val requiresChordExtension: Boolean = false,
)

/**
 * Product-level schema catalog (same five core schemes and the optional
 * `my_combo` as macOS). Supporting schemas such as melt_eng and radical_pinyin
 * stay on disk as dependencies but never appear in the switcher.
 */
object InputSchemaCatalog {
    const val CHORD_SCHEMA_ID = "my_combo"
    const val DEFAULT_SCHEMA_ID = "rime_ice"

    val options: List<InputSchemaOption> = listOf(
        InputSchemaOption("rime_ice", "雾凇全拼", "完整拼音输入", LexiconFamily.CHINESE),
        InputSchemaOption("double_pinyin", "自然码双拼", "自然码双拼方案", LexiconFamily.CHINESE),
        InputSchemaOption("double_pinyin_flypy", "小鹤双拼", "小鹤双拼方案", LexiconFamily.CHINESE),
        InputSchemaOption("wubi86", "五笔86", "86 版五笔字型", LexiconFamily.WUBI86),
        InputSchemaOption("english", "英文", "英文候选与补全", LexiconFamily.ENGLISH),
        InputSchemaOption(CHORD_SCHEMA_ID, "飞耀输入", "由并击扩展提供", LexiconFamily.CHINESE, requiresChordExtension = true),
    )

    fun option(id: String): InputSchemaOption? = options.firstOrNull { it.id == id }

    fun enabledIds(chordExtensionEnabled: Boolean): List<String> =
        options.filter { !it.requiresChordExtension || chordExtensionEnabled }.map { it.id }

    val defaultEnabledIds: List<String> get() = enabledIds(chordExtensionEnabled = false)

    /** Keeps catalog order and drops unknown ids. */
    fun normalized(ids: Collection<String>): List<String> {
        val requested = ids.toSet()
        return options.map { it.id }.filter { it in requested }
    }

    fun isOrdinary(id: String): Boolean = option(id)?.requiresChordExtension == false
}

/**
 * Reads and rewrites only `patch.schema_list` in the user directory's
 * `default.custom.yaml`, preserving unrelated keys (menu size, ...). Port of
 * `SchemaListStore.swift`.
 */
object SchemaListStore {
    class EmptySelectionException : IllegalArgumentException("至少保留一个输入方案。")

    fun enabledIds(file: File): List<String> {
        val text = runCatching { file.readText() }.getOrNull() ?: return emptyList()
        val lines = text.lines()
        val start = lines.indexOfFirst { it.trim() == "schema_list:" }
        if (start < 0) return emptyList()
        val baseIndent = leadingSpaces(lines[start])
        val ids = mutableListOf<String>()
        for (line in lines.drop(start + 1)) {
            val trimmed = line.trim()
            if (trimmed.isEmpty()) continue
            if (leadingSpaces(line) <= baseIndent) break
            if (!trimmed.startsWith("- schema:")) continue
            val id = trimmed.removePrefix("- schema:")
                .substringBefore('#')
                .trim()
                .trim('"', '\'')
            if (id.isNotEmpty()) ids += id
        }
        return InputSchemaCatalog.normalized(ids)
    }

    fun writeEnabledIds(requested: Collection<String>, file: File) {
        val ids = InputSchemaCatalog.normalized(requested)
        if (ids.isEmpty()) throw EmptySelectionException()
        val existing = runCatching { file.readText() }.getOrNull()
            ?: "patch:\n  schema_list:\n  menu:\n    page_size: 9\n"
        val lines = existing.lines().toMutableList()
        val itemLines = ids.map { "    - schema: $it" }

        val start = lines.indexOfFirst { it.trim() == "schema_list:" }
        if (start >= 0) {
            val baseIndent = leadingSpaces(lines[start])
            var end = start + 1
            while (end < lines.size) {
                val trimmed = lines[end].trim()
                if (trimmed.isNotEmpty() && leadingSpaces(lines[end]) <= baseIndent) break
                end++
            }
            lines.subList(start + 1, end).clear()
            lines.addAll(start + 1, itemLines + "")
        } else {
            val patchIndex = lines.indexOfFirst { it.trim() == "patch:" }
            if (patchIndex >= 0) {
                lines.addAll(patchIndex + 1, listOf("  schema_list:") + itemLines + "")
            } else {
                if (lines.isNotEmpty() && lines.last() != "") lines += ""
                lines += listOf("patch:", "  schema_list:") + itemLines + ""
            }
        }
        var text = lines.joinToString("\n")
        if (!text.endsWith("\n")) text += "\n"

        file.parentFile?.mkdirs()
        if (file.exists()) {
            val backup = File(file.path + ".bak")
            backup.delete()
            runCatching { file.copyTo(backup) }
        }
        val temp = File(file.parentFile, file.name + ".tmp")
        temp.writeText(text)
        check(temp.renameTo(file)) { "cannot replace ${file.name}" }
    }

    private fun leadingSpaces(line: String): Int = line.takeWhile { it == ' ' }.length
}

/**
 * Authoritative persisted schema selection. Choosing FlyYao (`my_combo`) is
 * also an explicit request to enable its extension; choosing an ordinary
 * schema remembers a safe fallback without disabling the extension. Port of
 * `InputConfigurationStore.swift` without the pre-v2 migration paths (Android
 * has no legacy profiles).
 */
class InputConfigurationStore(
    private val prefs: SharedPreferences,
    private val chordExtensionStore: ChordExtensionStore,
) {
    fun interface Listener {
        fun inputConfigurationDidChange(store: InputConfigurationStore)
    }

    private val listeners = CopyOnWriteArrayList<Listener>()

    init {
        chordExtensionStore.fallbackBeforeDisable = { fallBackFromChordScheme() }
    }

    fun addListener(listener: Listener) = listeners.addIfAbsent(listener)
    fun removeListener(listener: Listener) = listeners.remove(listener)

    val selectedSchemaId: String
        get() {
            val stored = prefs.getString(KEY_SELECTED, null)
            if (stored != null && InputSchemaCatalog.option(stored) != null) {
                if (stored == InputSchemaCatalog.CHORD_SCHEMA_ID && !chordExtensionStore.isEnabled) {
                    // Persisted residue is not an enable gesture; fail closed.
                    val fallback = lastOrdinarySchemaId
                    prefs.edit().putString(KEY_SELECTED, fallback).apply()
                    IMELog.write("input_schema retired disabled persisted chord schema fallback=$fallback")
                    return fallback
                }
                return stored
            }
            return InputSchemaCatalog.DEFAULT_SCHEMA_ID
        }

    val lastOrdinarySchemaId: String
        get() {
            val stored = prefs.getString(KEY_LAST_ORDINARY, null)
            if (stored != null && stored != InputSchemaCatalog.CHORD_SCHEMA_ID && InputSchemaCatalog.option(stored) != null) {
                return stored
            }
            return InputSchemaCatalog.DEFAULT_SCHEMA_ID
        }

    val selectedOption: InputSchemaOption
        get() = InputSchemaCatalog.option(selectedSchemaId) ?: InputSchemaCatalog.options.first()

    fun select(encoding: InputEncoding): Boolean = select(encoding.schemaId)

    fun select(schemaId: String): Boolean = select(schemaId, source = "schemaSelection")

    /** A runtime switcher (Rime menu) picked a schema; a disabled extension fails closed. */
    fun adoptRuntimeSchema(schemaId: String): Boolean {
        if (schemaId == InputSchemaCatalog.CHORD_SCHEMA_ID && !chordExtensionStore.isEnabled) {
            fallBackFromChordScheme()
            IMELog.write("input_schema rejected disabled runtime chord schema")
            return false
        }
        return select(schemaId, source = "runtimeSchema")
    }

    fun fallBackFromChordScheme(): Boolean {
        if (prefs.getString(KEY_SELECTED, null) != InputSchemaCatalog.CHORD_SCHEMA_ID) return false
        return select(lastOrdinarySchemaId, source = "rollback")
    }

    private fun select(schemaId: String, source: String): Boolean {
        InputSchemaCatalog.option(schemaId) ?: return false
        if (schemaId == InputSchemaCatalog.CHORD_SCHEMA_ID) {
            chordExtensionStore.setEnabled(true, source = source)
        }
        val changed = prefs.getString(KEY_SELECTED, null) != schemaId
        val editor = prefs.edit().putString(KEY_SELECTED, schemaId)
        if (schemaId != InputSchemaCatalog.CHORD_SCHEMA_ID) {
            editor.putString(KEY_LAST_ORDINARY, schemaId)
        }
        editor.apply()
        if (changed) {
            IMELog.write("input_schema selected=$schemaId source=$source")
            listeners.forEach { it.inputConfigurationDidChange(this) }
        }
        return true
    }

    companion object {
        const val KEY_SELECTED = "input.configuration.schemaID.v2"
        const val KEY_LAST_ORDINARY = "input.configuration.lastOrdinarySchemaID.v2"
    }
}
