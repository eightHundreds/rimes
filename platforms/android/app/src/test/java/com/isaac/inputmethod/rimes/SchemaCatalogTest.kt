package com.isaac.inputmethod.rimes

import com.isaac.inputmethod.rimes.input.ChordExtensionMode
import com.isaac.inputmethod.rimes.input.ChordExtensionStore
import com.isaac.inputmethod.rimes.input.ChordSettings
import com.isaac.inputmethod.rimes.input.InputConfigurationStore
import com.isaac.inputmethod.rimes.input.InputEncoding
import com.isaac.inputmethod.rimes.input.InputSchemaCatalog
import com.isaac.inputmethod.rimes.input.SchemaListStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class SchemaCatalogTest {
    @Test
    fun catalogExposesFiveCoreSchemasAndOptionalChord() {
        assertEquals(listOf("rime_ice", "double_pinyin", "double_pinyin_flypy", "wubi86", "english"), InputSchemaCatalog.defaultEnabledIds)
        assertEquals(
            listOf("rime_ice", "double_pinyin", "double_pinyin_flypy", "wubi86", "english", "my_combo"),
            InputSchemaCatalog.enabledIds(chordExtensionEnabled = true),
        )
        assertEquals(listOf("rime_ice", "wubi86"), InputSchemaCatalog.normalized(listOf("wubi86", "melt_eng", "rime_ice")))
        assertEquals("wubi86", InputEncoding.WUBI86.schemaId)
    }

    @Test
    fun schemaListStoreRewritesOnlyThePatchList() {
        val dir = Files.createTempDirectory("rimes-schema").toFile()
        val file = File(dir, "default.custom.yaml")
        file.writeText(
            """
            patch:
              schema_list:
                - schema: rime_ice          # 雾凇拼音
                - schema: wubi86
              menu:
                page_size: 9                # 候选词个数
            """.trimIndent() + "\n",
        )
        assertEquals(listOf("rime_ice", "wubi86"), SchemaListStore.enabledIds(file))
        SchemaListStore.writeEnabledIds(InputSchemaCatalog.enabledIds(true), file)
        val text = file.readText()
        assertTrue(text.contains("    - schema: my_combo"))
        assertTrue(text.contains("page_size: 9"))
        assertEquals(InputSchemaCatalog.enabledIds(true), SchemaListStore.enabledIds(file))
        assertTrue(File(dir, "default.custom.yaml.bak").exists())

        SchemaListStore.writeEnabledIds(InputSchemaCatalog.defaultEnabledIds, file)
        assertFalse(file.readText().contains("my_combo"))
        dir.deleteRecursively()
    }

    @Test(expected = SchemaListStore.EmptySelectionException::class)
    fun schemaListStoreRejectsEmptySelection() {
        val file = Files.createTempFile("rimes", ".yaml").toFile()
        try {
            SchemaListStore.writeEnabledIds(listOf("unknown"), file)
        } finally {
            file.delete()
        }
    }

    @Test
    fun selectingChordSchemaEnablesExtensionAndDisablingFallsBack() {
        val prefs = FakeSharedPreferences()
        val chord = ChordExtensionStore(prefs)
        val store = InputConfigurationStore(prefs, chord)
        var changes = 0
        store.addListener { changes++ }

        assertEquals("rime_ice", store.selectedSchemaId)
        assertTrue(store.select(InputEncoding.WUBI86))
        assertEquals("wubi86", store.selectedSchemaId)
        assertEquals("wubi86", store.lastOrdinarySchemaId)

        assertTrue(store.select(InputSchemaCatalog.CHORD_SCHEMA_ID))
        assertTrue(chord.isEnabled)
        assertEquals("my_combo", store.selectedSchemaId)
        assertEquals("wubi86", store.lastOrdinarySchemaId)

        chord.setEnabled(false)
        assertEquals("wubi86", store.selectedSchemaId)
        assertEquals(3, changes)

        // Runtime switcher residue for a disabled extension fails closed.
        assertFalse(store.adoptRuntimeSchema("my_combo"))
        assertEquals("wubi86", store.selectedSchemaId)
        assertFalse(store.select("melt_eng"))
    }

    @Test
    fun chordExtensionDefaultsAndClamping() {
        val prefs = FakeSharedPreferences()
        val chord = ChordExtensionStore(prefs)
        assertFalse(chord.isEnabled)
        assertEquals(ChordExtensionMode.MUTUAL, chord.mode)
        assertEquals(ChordSettings.DEFAULT_DURATION_MS, chord.durationMillis)
        chord.setDurationMillis(5)
        assertEquals(ChordSettings.RANGE_MS.first, chord.durationMillis)
        chord.setDurationMillis(9000)
        assertEquals(ChordSettings.RANGE_MS.last, chord.durationMillis)
        chord.resetDuration()
        assertEquals(ChordSettings.DEFAULT_DURATION_MS, chord.durationMillis)
        assertTrue(chord.setMode(ChordExtensionMode.CHORD))
        assertFalse(chord.setMode(ChordExtensionMode.CHORD))
    }
}
