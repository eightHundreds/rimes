package com.isaac.inputmethod.rimes

import com.isaac.inputmethod.rimes.buffer.BufferDeliveryCoordinator
import com.isaac.inputmethod.rimes.buffer.BufferInputRoute
import com.isaac.inputmethod.rimes.buffer.BufferModel
import com.isaac.inputmethod.rimes.buffer.Origin
import com.isaac.inputmethod.rimes.input.FocusToken
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BufferModelTest {
    private val token = FocusToken("com.example", 7, 1)

    @Test
    fun captureIsBoundToExactTokenAndEnablement() {
        val model = BufferModel()
        model.activateCapture(token)
        assertEquals(BufferInputRoute.DIRECT_TO_HOST, model.route(token)) // disabled
        model.enabled = true
        model.activateCapture(token)
        assertEquals(BufferInputRoute.CAPTURE_TO_BUFFER, model.route(token))
        assertEquals(BufferInputRoute.DIRECT_TO_HOST, model.route(token.copy(generation = 2)))
        model.pauseCapturePreservingContent()
        assertNull(model.captureOwner)
    }

    @Test
    fun blocksKeepCommitBoundariesAndInsertionOrder() {
        val model = BufferModel()
        model.append("你好")
        model.append("世界")
        assertEquals(listOf("你好", "世界"), model.blocks.map { it.text })
        assertEquals(2, model.insertionIndex)
        assertTrue(model.setInsertionPoint(1))
        model.append("，")
        assertEquals("你好，世界", model.text)
        assertEquals(2, model.insertionIndex)
        assertTrue(model.removeLastBlock())
        assertEquals("你好世界", model.text)
        assertEquals(1, model.insertionIndex)
    }

    @Test
    fun consumingDeliveredBlocksPreservesRemainingOrderAndRetainsNoHistory() {
        val model = BufferModel()
        val a = model.append("a")!!
        val b = model.append("b")!!
        val c = model.append("c")!!
        model.consumeDelivered(listOf(a.id, c.id))
        assertEquals(listOf(b.id), model.blocks.map { it.id })
        assertEquals(1, model.insertionIndex)
        assertNull(model.block(a.id))
    }

    @Test
    fun disablingKeepsQueuedContentVisible() {
        val model = BufferModel()
        model.enabled = true
        model.activateCapture(token)
        model.append("待发送")
        model.enabled = false
        assertEquals(1, model.blocks.size)
        assertNull(model.captureOwner)
        model.discardForPrivacy()
        assertTrue(model.isEmpty)
    }

    @Test
    fun originBadgesOnlyForNonRimeBlocks() {
        assertNull(Origin.Rime.badge)
        assertEquals("粘贴", Origin.Paste.badge)
        assertEquals("segmenter", Origin.Processor("segmenter").badge)
    }

    @Test
    fun deliverySendsNextThenAllAndConsumesOnlyAcceptedBlocks() {
        val model = BufferModel()
        model.enabled = true
        model.activateCapture(token)
        model.append("一")
        model.append("二")
        model.append("三")
        val host = FakeHost(token)
        val coordinator = BufferDeliveryCoordinator(model)

        val first = coordinator.sendNext(token) { host }
        assertEquals(BufferDeliveryCoordinator.Outcome.DELIVERED, first.outcome)
        assertEquals(listOf("一"), host.committed)
        assertEquals(2, model.blocks.size)
        assertFalse(first.wasTerminal)

        val rest = coordinator.sendAll(token) { host }
        assertEquals(listOf("一", "二", "三"), host.committed)
        assertTrue(model.isEmpty)
        assertTrue(rest.wasTerminal)
    }

    @Test
    fun deliveryStopsOnTargetMismatchAndSecureInput() {
        val model = BufferModel()
        model.enabled = true
        model.activateCapture(token)
        model.append("一")
        model.append("二")
        val coordinator = BufferDeliveryCoordinator(model)

        val stale = coordinator.sendAll(token) { FakeHost(token.copy(generation = 99)) }
        assertEquals(BufferDeliveryCoordinator.Outcome.TARGET_MISMATCH, stale.outcome)
        assertEquals(2, model.blocks.size)

        val secure = coordinator.sendNext(token) { FakeHost(token, secureInput = true) }
        assertEquals(BufferDeliveryCoordinator.Outcome.BLOCKED, secure.outcome)
        assertEquals(2, model.blocks.size)

        val empty = BufferDeliveryCoordinator(BufferModel()).sendNext(token) { FakeHost(token) }
        assertEquals(BufferDeliveryCoordinator.Outcome.NOTHING_TO_SEND, empty.outcome)
    }
}
