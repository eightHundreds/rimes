package com.isaac.inputmethod.rimes

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.isaac.inputmethod.rimes.input.InputSchemaCatalog
import com.isaac.inputmethod.rimes.rime.RimeKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Real librime on the device: seeds the bundled data, deploys every schema,
 * and drives sessions through the shared bridge exactly like the input method
 * does. The first run compiles the dictionaries, so the class-level start has
 * a generous timeout.
 */
@RunWith(AndroidJUnit4::class)
class RimeEngineInstrumentedTest {
    companion object {
        lateinit var app: RimesApplication

        @BeforeClass
        @JvmStatic
        fun startEngine() {
            app = RimesApplication.of(InstrumentationRegistry.getInstrumentation().targetContext)
            val ok = app.startEngineAsync().get(40, TimeUnit.MINUTES)
            assertTrue("librime failed to start: ${app.engine.lastError()}", ok)
        }
    }

    private fun type(session: Long, text: String) {
        for (c in text) assertTrue("Rime should consume '$c'", app.engine.processKey(c.code, 0, session))
    }

    @Test
    fun bundledDataDeploysTheFiveCoreSchemasInOrder() {
        val ids = app.engine.schemaList().map { it.id }
        assertEquals(InputSchemaCatalog.defaultEnabledIds, ids.filter { it in InputSchemaCatalog.defaultEnabledIds })
        assertFalse("my_combo must stay out of the switcher while the extension is off", ids.contains("my_combo"))
        assertTrue(File(app.deployer.userDir, "build/rime_ice.schema.yaml").isFile)
        assertTrue(File(app.deployer.sharedDir, "opencc/s2t.json").isFile)
        assertTrue(File(app.deployer.sharedDir, "lua/v_filter.lua").isFile)
        assertTrue(app.engine.isHealthy)
    }

    @Test
    fun fullPinyinComposesAndCommitsThroughTheBridge() {
        val session = app.engine.createSession()
        assertTrue(session != 0L)
        try {
            assertTrue(app.engine.selectSchema("rime_ice", session))
            type(session, "nihao")
            val context = app.engine.getContext(session)
            assertTrue(context.active)
            assertEquals("nihao", context.input)
            assertTrue(context.preedit.isNotEmpty())
            assertTrue("expected 你好 among ${context.candidateList.map { it.text }}", context.candidateList.any { it.text == "你好" })
            assertEquals("1", context.candidates.first().label)

            assertTrue(app.engine.processKey(RimeKey.SPACE, 0, session))
            assertEquals("你好", app.engine.takeCommit(session))
            assertFalse(app.engine.getContext(session).active)

            val status = app.engine.getStatus(session)
            assertEquals("rime_ice", status.schemaId)
            assertFalse(status.asciiMode)
        } finally {
            app.engine.destroySession(session)
        }
    }

    @Test
    fun candidateSelectionPagingAndEscape() {
        val session = app.engine.createSession()
        try {
            app.engine.selectSchema("rime_ice", session)
            type(session, "shijie")
            val first = app.engine.getContext(session)
            assertTrue(first.candidates.size > 1)
            assertTrue(app.engine.processKey(RimeKey.PAGE_DOWN, 0, session))
            val second = app.engine.getContext(session)
            assertEquals(first.pageNo + 1, second.pageNo)
            assertTrue(app.engine.processKey(RimeKey.PAGE_UP, 0, session))
            assertEquals(first.pageNo, app.engine.getContext(session).pageNo)
            assertTrue(app.engine.selectCandidate(0, session))
            assertEquals(first.candidates.first().text, app.engine.takeCommit(session))

            type(session, "ceshi")
            assertTrue(app.engine.processKey(RimeKey.ESCAPE, 0, session))
            assertFalse(app.engine.getContext(session).active)
            assertEquals(null, app.engine.takeCommit(session))
        } finally {
            app.engine.destroySession(session)
        }
    }

    @Test
    fun sessionsAreIsolatedFromEachOther() {
        val a = app.engine.createSession()
        val b = app.engine.createSession()
        try {
            type(a, "ni")
            assertTrue(app.engine.getContext(a).active)
            assertFalse(app.engine.getContext(b).active)
            app.engine.clearComposition(a)
            assertFalse(app.engine.getContext(a).active)
        } finally {
            app.engine.destroySession(a)
            app.engine.destroySession(b)
            assertFalse(app.engine.sessionExists(a))
        }
    }

    @Test
    fun otherCoreSchemasProduceCandidates() {
        val session = app.engine.createSession()
        try {
            assertTrue(app.engine.selectSchema("wubi86", session))
            assertEquals("wubi86", app.engine.getStatus(session).schemaId)
            type(session, "gggg")
            val wubi = app.engine.getContext(session)
            assertTrue("wubi candidates: ${wubi.candidateList.map { it.text }}", wubi.candidateList.any { it.text == "王" })
            app.engine.clearComposition(session)

            assertTrue(app.engine.selectSchema("double_pinyin_flypy", session))
            type(session, "nihc")
            assertTrue(app.engine.getContext(session).candidateList.any { it.text == "你好" })
            app.engine.clearComposition(session)

            assertTrue(app.engine.selectSchema("english", session))
            type(session, "hel")
            val english = app.engine.getContext(session)
            assertTrue("english candidates: ${english.candidateList.map { it.text }}", english.candidateList.any { it.text.startsWith("hel", ignoreCase = true) })
            app.engine.clearComposition(session)
        } finally {
            app.engine.destroySession(session)
        }
    }

    @Test
    fun asciiModeToggleAndOptions() {
        val session = app.engine.createSession()
        try {
            app.engine.selectSchema("rime_ice", session)
            assertFalse(app.engine.getOption("ascii_mode", session))
            app.engine.setOption("ascii_mode", true, session)
            assertTrue(app.engine.getStatus(session).asciiMode)
            // librime returns Latin keys to the frontend in ASCII mode.
            assertFalse(app.engine.processKey('a'.code, 0, session))
            app.engine.setOption("ascii_mode", false, session)
            assertTrue(app.engine.processKey('a'.code, 0, session))
            app.engine.clearComposition(session)
        } finally {
            app.engine.destroySession(session)
        }
    }

    @Test
    fun streamDecodeReturnsCompleteCommitPreviews() {
        val session = app.engine.createSession()
        try {
            app.engine.selectSchema("rime_ice", session)
            val texts = app.engine.decodeCandidateTexts("nihao", 3, session)
            assertNotNull(texts)
            assertTrue(texts!!.isNotEmpty())
            assertTrue(texts.contains("你好"))
            assertFalse(app.engine.getContext(session).active)
        } finally {
            app.engine.destroySession(session)
        }
    }

    @Test
    fun userDictionaryExportGoesThroughLevers() {
        val session = app.engine.createSession()
        try {
            app.engine.selectSchema("rime_ice", session)
            type(session, "nihao")
            app.engine.processKey(RimeKey.SPACE, 0, session)
            assertEquals("你好", app.engine.takeCommit(session))
        } finally {
            app.engine.destroySession(session)
        }
        assertTrue(app.engine.hasUserDictionary("rime_ice"))
        val out = File(app.cacheDir, "rime_ice-export-test.txt")
        out.delete()
        var began = 0
        var ended = 0
        val observer = object : com.isaac.inputmethod.rimes.rime.RimeEngine.MaintenanceObserver {
            override fun rimeUserDictionaryMaintenanceWillBegin() { began++ }
            override fun rimeUserDictionaryMaintenanceDidEnd(succeeded: Boolean) { ended++ }
        }
        app.engine.addMaintenanceObserver(observer)
        val count = try {
            app.engine.exportUserDictionary("rime_ice", out)
        } finally {
            app.engine.removeMaintenanceObserver(observer)
        }
        assertTrue("export returned $count", count >= 1)
        assertEquals(1, began)
        assertEquals(1, ended)
        assertTrue(out.isFile && out.length() > 0)
        assertTrue(out.readText().contains("你好"))

        val imported = app.engine.importUserDictionary("rime_ice", out)
        assertTrue("import returned $imported", imported >= 0)
        out.delete()
        // Sessions still work after maintenance closed and reopened the LevelDB.
        val session2 = app.engine.createSession()
        assertTrue(session2 != 0L)
        app.engine.destroySession(session2)
    }
}
