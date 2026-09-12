package com.isaac.inputmethod.rimes

import android.view.KeyEvent
import com.isaac.inputmethod.rimes.buffer.BufferModel
import com.isaac.inputmethod.rimes.input.ChordExtensionMode
import com.isaac.inputmethod.rimes.input.ChordExtensionStore
import com.isaac.inputmethod.rimes.input.FocusToken
import com.isaac.inputmethod.rimes.input.InputConfigurationStore
import com.isaac.inputmethod.rimes.input.InputController
import com.isaac.inputmethod.rimes.input.InputSchemaCatalog
import com.isaac.inputmethod.rimes.input.InputTelemetrySink
import com.isaac.inputmethod.rimes.rime.RimeKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class InputControllerTest {
    private lateinit var engine: FakeEngine
    private lateinit var buffer: BufferModel
    private lateinit var prefs: FakeSharedPreferences
    private lateinit var chord: ChordExtensionStore
    private lateinit var configuration: InputConfigurationStore
    private lateinit var scheduler: ManualScheduler
    private lateinit var controller: InputController
    private lateinit var host: FakeHost
    private val telemetry = object : InputTelemetrySink {
        var keys = 0
        var chars = 0
        var bufferCommits = 0
        override fun recordKey(keycode: Int) { keys++ }
        override fun recordCommit(characterCount: Int, toBuffer: Boolean) {
            chars += characterCount
            if (toBuffer) bufferCommits++
        }
    }

    @Before
    fun setUp() {
        engine = FakeEngine()
        buffer = BufferModel()
        prefs = FakeSharedPreferences()
        chord = ChordExtensionStore(prefs)
        configuration = InputConfigurationStore(prefs, chord)
        scheduler = ManualScheduler()
        controller = InputController(engine, buffer, configuration, chord, scheduler, telemetry, preeditDecorator = { it })
        host = FakeHost()
        controller.bind(host)
    }

    private fun type(text: String) {
        for (c in text) assertTrue("key $c consumed", controller.handleKey(c.code, 0))
    }

    @Test
    fun directTypingCommitsThroughDeliveryAndKeepsPreeditInHost() {
        type("nihao")
        assertEquals("nihao", host.composing.last())
        assertTrue(controller.lastUiState.context.active)
        assertEquals("你好", controller.lastUiState.context.candidates.first().text)
        assertTrue(controller.handleKey(RimeKey.SPACE, 0))
        assertEquals(listOf("你好"), host.committed)
        assertFalse(controller.lastUiState.context.active)
        assertEquals(6, telemetry.keys)
        assertEquals(2, telemetry.chars)
    }

    @Test
    fun candidateTapSelectsOnCurrentPage() {
        type("ni")
        assertTrue(controller.selectCandidate(0))
        assertEquals(listOf("你"), host.committed)
    }

    @Test
    fun returnCommitsRawInputInsteadOfNewline() {
        type("nihao")
        assertTrue(controller.handleKey(RimeKey.RETURN, 0))
        assertEquals(listOf("nihao"), host.committed)
        assertTrue(host.editorActions == 0 && host.keyEvents.isEmpty())
    }

    @Test
    fun idleReturnAndBackspaceGoToTheHost() {
        assertTrue(controller.handleKey(RimeKey.RETURN, 0))
        assertEquals(1, host.editorActions)
        assertTrue(controller.handleKey(RimeKey.BACKSPACE, 0))
        assertEquals(listOf(KeyEvent.KEYCODE_DEL), host.keyEvents)
    }

    @Test
    fun asciiModeLettersFallThroughAsDirectText() {
        engine.asciiMode = true
        type("ab")
        assertEquals(listOf("a", "b"), host.committed)
        assertTrue(controller.handleKey('c'.code, RimeKey.SHIFT_MASK))
        assertEquals(listOf("a", "b", "C"), host.committed)
    }

    @Test
    fun standaloneShiftTogglesAsciiThroughRime() {
        assertFalse(engine.asciiMode)
        controller.handleStandaloneModifierTap(RimeKey.SHIFT_L)
        assertTrue(engine.asciiMode)
        assertTrue(controller.lastUiState.status.asciiMode)
    }

    @Test
    fun bufferCaptureRoutesCommitsIntoBlocksAndDeliversOnSend() {
        controller.setBufferEnabled(true)
        assertTrue(controller.lastUiState.bufferCaptures)
        type("nihao")
        // Preedit is projected in the workbench, never in the host.
        assertTrue(host.composing.all { it.isEmpty() })
        assertEquals("nihao", controller.lastUiState.context.preedit)
        controller.handleKey(RimeKey.SPACE, 0)
        type("shijie")
        controller.handleKey(RimeKey.SPACE, 0)
        assertEquals(listOf("你好", "世界"), buffer.blocks.map { it.text })
        assertTrue(host.committed.isEmpty())
        assertEquals(2, telemetry.bufferCommits)

        val next = controller.performBufferSend(all = false)
        assertNotNull(next)
        assertEquals(listOf("你好"), host.committed)
        assertEquals(1, buffer.blocks.size)
        val rest = controller.performBufferSend(all = true)
        assertEquals(listOf("你好", "世界"), host.committed)
        assertTrue(rest!!.wasTerminal)
        // Default preference: the exact last delivery pauses capture, content stays enabled.
        assertFalse(controller.lastUiState.bufferCaptures)
        assertTrue(buffer.enabled)
    }

    @Test
    fun bufferReturnWithPendingCompositionOnlySettles() {
        controller.setBufferEnabled(true)
        type("nihao")
        assertTrue(controller.hasPendingComposition())
        assertTrue(controller.bufferOwnsReturn())
        assertTrue(controller.handleKey(RimeKey.RETURN, 0))
        assertEquals(listOf("nihao"), buffer.blocks.map { it.text })
        assertTrue(host.committed.isEmpty())
        assertTrue(host.keyEvents.isEmpty())
        // A send with pending composition settles instead of sending.
        type("ni")
        assertEquals(null, controller.performBufferSend(all = false))
        assertEquals(listOf("nihao", "ni"), buffer.blocks.map { it.text })
    }

    @Test
    fun bufferBackspaceEditsCompositionThenRemovesBlocksNeverTheHost() {
        controller.setBufferEnabled(true)
        type("ni")
        controller.handleKey(RimeKey.SPACE, 0)
        type("hao")
        assertTrue(controller.handleKey(RimeKey.BACKSPACE, 0))
        assertEquals("ha", controller.lastUiState.context.input)
        controller.handleKey(RimeKey.BACKSPACE, 0)
        controller.handleKey(RimeKey.BACKSPACE, 0)
        assertFalse(controller.hasPendingComposition())
        assertTrue(controller.handleKey(RimeKey.BACKSPACE, 0))
        assertTrue(buffer.isEmpty)
        assertTrue(controller.handleKey(RimeKey.BACKSPACE, 0)) // empty workbench: consumed
        assertTrue(host.keyEvents.isEmpty())
    }

    @Test
    fun directAsciiRunsMergeIntoOneBlockWhileCapturing() {
        controller.setBufferEnabled(true)
        engine.asciiMode = true
        type("ok")
        assertEquals(listOf("ok"), buffer.blocks.map { it.text })
    }

    @Test
    fun newFieldReturnsToDirectRoutingButKeepsContent() {
        controller.setBufferEnabled(true)
        type("ni")
        controller.handleKey(RimeKey.SPACE, 0)
        val other = FakeHost(FocusToken("com.other", 2, 2))
        controller.unbind()
        controller.bind(other)
        assertFalse(controller.lastUiState.bufferCaptures)
        assertEquals(1, buffer.blocks.size)
        type("ni")
        controller.handleKey(RimeKey.SPACE, 0)
        assertEquals(listOf("你"), other.committed)
        // Stale-token delivery must fail closed.
        controller.toggleBufferCapture()
        assertTrue(controller.lastUiState.bufferCaptures)
        val result = controller.performBufferSend(all = true)
        assertEquals(listOf("你", "你"), other.committed)
        assertTrue(result!!.wasTerminal)
    }

    @Test
    fun secureFieldsBypassRimeAndBuffer() {
        controller.setBufferEnabled(true)
        val secure = FakeHost(FocusToken("com.bank", 9, 3), secureInput = true)
        controller.unbind()
        controller.bind(secure)
        assertTrue(controller.handleKey('a'.code, 0))
        assertTrue(controller.handleKey('b'.code, RimeKey.SHIFT_MASK))
        assertEquals(listOf("a", "B"), secure.committed)
        assertTrue(secure.composing.isEmpty())
        assertFalse(controller.lastUiState.bufferCaptures)
        assertTrue(controller.handleKey(RimeKey.RETURN, 0))
        assertEquals(1, secure.editorActions)
    }

    @Test
    fun engineOutageStillTypesLatin() {
        engine.healthy = false
        val fresh = FakeHost(FocusToken("com.example", 5, 5))
        controller.unbind()
        controller.bind(fresh)
        assertTrue(controller.handleKey('h'.code, 0))
        assertTrue(controller.handleKey('i'.code, RimeKey.SHIFT_MASK))
        assertEquals(listOf("h", "I"), fresh.committed)
        assertTrue(controller.handleKey(RimeKey.RETURN, 0))
        assertEquals(1, fresh.editorActions)
    }

    @Test
    fun schemaSelectionPersistsAndAppliesToTheSession() {
        assertTrue(controller.selectSchema("wubi86"))
        assertEquals("wubi86", engine.schemaId)
        assertEquals("wubi86", configuration.selectedSchemaId)
        assertEquals("english", controller.cycleSchema())
        assertEquals("rime_ice", controller.cycleSchema()) // wraps; my_combo hidden while the extension is off
        assertFalse(controller.selectSchema("melt_eng"))
    }

    @Test
    fun chordKeysAreStagedAndReplayedWithReleasesOnlyForMyCombo() {
        chord.setEnabled(true)
        chord.setMode(ChordExtensionMode.CHORD)
        controller.selectSchema(InputSchemaCatalog.CHORD_SCHEMA_ID)
        engine.keyLog.clear()
        assertTrue(controller.handleKey('q'.code, 0))
        assertTrue(controller.handleKey('y'.code, 0))
        assertTrue(controller.lastUiState.chordPending)
        assertTrue(engine.keyLog.isEmpty()) // staged, not yet in Rime
        scheduler.fire()
        val presses = engine.keyLog.filter { it.second and RimeKey.RELEASE_MASK == 0 }.map { it.first }
        val releases = engine.keyLog.filter { it.second and RimeKey.RELEASE_MASK != 0 }.map { it.first }
        assertEquals(listOf('q'.code, 'y'.code), presses)
        assertEquals(listOf('q'.code, 'y'.code), releases)
        assertFalse(controller.lastUiState.chordPending)
        assertEquals("qy", controller.lastUiState.context.input)

        // Sequential schemas never see synthetic releases.
        controller.selectSchema("rime_ice")
        engine.keyLog.clear()
        controller.handleKey('n'.code, 0)
        assertEquals(listOf('n'.code to 0), engine.keyLog)
        assertFalse(controller.lastUiState.chordPending)
    }

    @Test
    fun chordDelimiterInsertedBetweenMultiKeyBatches() {
        chord.setEnabled(true)
        chord.setMode(ChordExtensionMode.CHORD)
        controller.selectSchema(InputSchemaCatalog.CHORD_SCHEMA_ID)
        controller.handleKey('q'.code, 0)
        controller.handleKey('y'.code, 0)
        scheduler.fire()
        controller.handleKey('d'.code, 0)
        controller.handleKey('v'.code, 0)
        scheduler.fire()
        assertEquals("qy'dv", controller.lastUiState.context.input)
        // A single-key batch stays literal without a delimiter.
        controller.handleKey('a'.code, 0)
        scheduler.fire()
        assertEquals("qy'dva", controller.lastUiState.context.input)
    }

    @Test
    fun mutualModeRecombinesLeftInitialWithRightFinal() {
        chord.setEnabled(true)
        chord.setMode(ChordExtensionMode.MUTUAL)
        controller.selectSchema(InputSchemaCatalog.CHORD_SCHEMA_ID)
        controller.handleKey('d'.code, 0)
        controller.handleKey('v'.code, 0)
        scheduler.fire()
        assertEquals("dv", controller.lastUiState.context.input)
        controller.handleKey('i'.code, 0)
        scheduler.fire()
        // Left batch rolled back, both halves replayed as one chord.
        assertEquals("dvi", controller.lastUiState.context.input)
    }
}
