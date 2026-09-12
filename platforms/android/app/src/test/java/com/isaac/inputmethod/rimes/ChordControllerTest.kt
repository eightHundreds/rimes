package com.isaac.inputmethod.rimes

import com.isaac.inputmethod.rimes.input.ChordController
import com.isaac.inputmethod.rimes.input.FlyChordBatchShape
import com.isaac.inputmethod.rimes.input.FlyChordBatchState
import com.isaac.inputmethod.rimes.input.FlyChordBoundaryRules
import com.isaac.inputmethod.rimes.input.FlyChordInputRollback
import com.isaac.inputmethod.rimes.input.FlyChordKeyEvent
import com.isaac.inputmethod.rimes.input.FlyChordLayout
import com.isaac.inputmethod.rimes.input.FlyChordHalf
import com.isaac.inputmethod.rimes.input.FlyChordMutualPairingState
import com.isaac.inputmethod.rimes.input.FlyChordPressDecision
import com.isaac.inputmethod.rimes.input.FlyChordRoutingRules
import com.isaac.inputmethod.rimes.input.FlyChordSettlementPolicy
import com.isaac.inputmethod.rimes.rime.RimeContextModel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChordControllerTest {
    private fun key(c: Char) = FlyChordKeyEvent(c.code, 0)

    @Test
    fun layoutSplitsKeyboardHalves() {
        assertEquals(FlyChordHalf.LEFT, FlyChordLayout.half('q'.code))
        assertEquals(FlyChordHalf.RIGHT, FlyChordLayout.half('p'.code))
        assertEquals(FlyChordHalf.RIGHT, FlyChordLayout.half(','.code))
        assertNull(FlyChordLayout.half('1'.code))
        assertEquals(FlyChordBatchShape.BOTH_HALVES, FlyChordBatchShape.of(listOf(key('q'), key('y'))))
        assertEquals(FlyChordBatchShape.LEFT_ONLY, FlyChordBatchShape.of(listOf(key('d'), key('v'))))
        assertNull(FlyChordBatchShape.of(emptyList()))
    }

    @Test
    fun routingIsSchemaGatedAndExtensionGated() {
        assertTrue(FlyChordRoutingRules.shouldStage("my_combo", asciiMode = false, extensionEnabled = true))
        assertFalse(FlyChordRoutingRules.shouldStage("my_combo", asciiMode = true, extensionEnabled = true))
        assertFalse(FlyChordRoutingRules.shouldStage("my_combo", asciiMode = false, extensionEnabled = false))
        assertFalse(FlyChordRoutingRules.shouldStage("rime_ice", asciiMode = false, extensionEnabled = true))
    }

    @Test
    fun batchStagesUniqueChordKeysAndSettlesOnlyHandledOnes() {
        val batch = FlyChordBatchState()
        assertEquals(FlyChordPressDecision.Process(listOf(key('q'))), batch.stage(key('q'), FlyChordSettlementPolicy.SAME_BATCH_ONLY))
        assertEquals(FlyChordPressDecision.Consume, batch.stage(key('q'), FlyChordSettlementPolicy.SAME_BATCH_ONLY)) // auto-repeat
        assertEquals(FlyChordPressDecision.Consume, batch.stage(FlyChordKeyEvent('1'.code, 0), FlyChordSettlementPolicy.SAME_BATCH_ONLY))
        batch.stage(key('y'), FlyChordSettlementPolicy.INDEPENDENT_HALVES)
        batch.noteHandled(key('q'))
        batch.noteHandled(key('y'))
        batch.noteHandled(key('z')) // never staged: ignored
        assertEquals(listOf(key('q'), key('y')), batch.settle())
        assertFalse(batch.hasPending)
    }

    @Test
    fun boundaryRulesInsertDelimiterOnlyForMultiKeyBatches() {
        assertFalse(FlyChordBoundaryRules.shouldInsert(1))
        assertTrue(FlyChordBoundaryRules.shouldInsert(2))
        val plan = FlyChordBoundaryRules.plan(RimeContextModel(active = true, input = "ni'", cursorPos = 3))
        assertFalse(plan.before) // already delimited
        assertFalse(plan.after)
        val middle = FlyChordBoundaryRules.plan(RimeContextModel(active = true, input = "nihao", cursorPos = 2))
        assertTrue(middle.before)
        assertTrue(middle.after)
    }

    @Test
    fun rollbackDetectsOneContiguousInsertion() {
        assertEquals(2, FlyChordInputRollback.insertedScalarCount("ni", "nihao".take(4)))
        assertEquals(3, FlyChordInputRollback.insertedScalarCount("", "abc"))
        assertNull(FlyChordInputRollback.insertedScalarCount("abc", "ab"))
        assertNull(FlyChordInputRollback.insertedScalarCount("abc", "xyzq"))
    }

    @Test
    fun mutualPairingOnlyCombinesLeftThenRightWithAMultiKeyHalf() {
        val state = FlyChordMutualPairingState()
        val base = RimeContextModel(active = true, input = "", cursorPos = 0)
        val settled = RimeContextModel(active = true, input = "n", cursorPos = 1)
        state.recordSettledLeft(
            keys = listOf(key('d'), key('v')), baseInput = base.input, settledContext = settled,
            boundaryPlan = FlyChordBoundaryRules.plan(base), policy = FlyChordSettlementPolicy.INDEPENDENT_HALVES,
            shape = FlyChordBatchShape.LEFT_ONLY,
        )
        // A right-only single key completes the syllable because the left was multi-key.
        val complement = state.takeComplement(FlyChordBatchShape.RIGHT_ONLY, 1, FlyChordSettlementPolicy.INDEPENDENT_HALVES, settled)
        assertNotNull(complement)
        assertEquals(1, complement!!.insertedScalarCount)

        // Two singleton batches never recombine.
        state.recordSettledLeft(
            keys = listOf(key('q')), baseInput = "", settledContext = RimeContextModel(active = true, input = "q", cursorPos = 1),
            boundaryPlan = FlyChordBoundaryRules.plan(base), policy = FlyChordSettlementPolicy.INDEPENDENT_HALVES,
            shape = FlyChordBatchShape.LEFT_ONLY,
        )
        assertNull(state.takeComplement(FlyChordBatchShape.RIGHT_ONLY, 1, FlyChordSettlementPolicy.INDEPENDENT_HALVES, RimeContextModel(active = true, input = "q", cursorPos = 1)))

        // 并击 never pairs across batches.
        state.recordSettledLeft(
            keys = listOf(key('d'), key('v')), baseInput = "", settledContext = settled,
            boundaryPlan = FlyChordBoundaryRules.plan(base), policy = FlyChordSettlementPolicy.SAME_BATCH_ONLY,
            shape = FlyChordBatchShape.LEFT_ONLY,
        )
        assertNull(state.takeComplement(FlyChordBatchShape.RIGHT_ONLY, 2, FlyChordSettlementPolicy.SAME_BATCH_ONLY, settled))
    }

    @Test
    fun controllerFlushesHandledKeysWhenTheTimerFires() {
        val scheduler = ManualScheduler()
        val controller = ChordController(scheduler)
        controller.durationMillis = 80
        val flushed = mutableListOf<List<FlyChordKeyEvent>>()
        controller.onFlush = { flushed += it }
        controller.stageChordKey('q'.code, 0, FlyChordSettlementPolicy.SAME_BATCH_ONLY)
        controller.noteHandledChordKey('q'.code, 0)
        controller.stageChordKey('y'.code, 0, FlyChordSettlementPolicy.SAME_BATCH_ONLY)
        controller.noteHandledChordKey('y'.code, 0)
        assertEquals(80, scheduler.lastDelay)
        assertEquals(1, scheduler.pendingCount) // the second key rescheduled, not duplicated
        assertTrue(controller.hasPending)
        scheduler.fire()
        assertEquals(listOf(listOf(key('q'), key('y'))), flushed)
        assertFalse(controller.hasPending)
    }

    @Test
    fun controllerAbortReturnsStagedSubsetWithoutCallbacks() {
        val scheduler = ManualScheduler()
        val controller = ChordController(scheduler)
        var flushes = 0
        controller.onFlush = { flushes++ }
        controller.stageChordKey('a'.code, 0, FlyChordSettlementPolicy.INDEPENDENT_HALVES)
        controller.noteHandledChordKey('a'.code, 0)
        assertEquals(listOf(key('a')), controller.abort())
        assertEquals(0, scheduler.pendingCount)
        assertEquals(0, flushes)
    }
}
