package com.isaac.inputmethod.rimes.buffer

import com.isaac.inputmethod.rimes.IMELog
import com.isaac.inputmethod.rimes.input.Delivery
import com.isaac.inputmethod.rimes.input.FocusToken
import com.isaac.inputmethod.rimes.input.HostClient

/**
 * The only component allowed to turn staged blocks into [Delivery.insert]
 * calls. A send starts from the live host bound at the moment of the user
 * gesture; the expected [FocusToken] is revalidated before every block and
 * the operation stops at the first mismatch, secure field, or failure.
 * Accepted blocks are consumed synchronously; failed and unsent blocks stay.
 */
class BufferDeliveryCoordinator(private val model: BufferModel) {
    enum class Outcome { DELIVERED, NOTHING_TO_SEND, TARGET_MISMATCH, BLOCKED }

    data class Result(val outcome: Outcome, val deliveredCount: Int, val remaining: Int, val wasTerminal: Boolean)

    /** Resolves the live host; returns null when nothing trustworthy is bound. */
    fun interface TargetResolver {
        fun liveTarget(): HostClient?
    }

    fun sendNext(expected: FocusToken, resolver: TargetResolver): Result = send(expected, resolver, all = false)

    fun sendAll(expected: FocusToken, resolver: TargetResolver): Result = send(expected, resolver, all = true)

    private fun send(expected: FocusToken, resolver: TargetResolver, all: Boolean): Result {
        val pending = model.blocks
        if (pending.isEmpty()) return Result(Outcome.NOTHING_TO_SEND, 0, 0, wasTerminal = false)
        var delivered = 0
        val toSend = if (all) pending else pending.take(1)
        for (block in toSend) {
            val target = resolver.liveTarget()
            if (target == null || target.token != expected) {
                IMELog.write("buffer delivery stopped: target mismatch expected=$expected actual=${target?.token}")
                return Result(Outcome.TARGET_MISMATCH, delivered, model.blocks.size, wasTerminal = false)
            }
            if (target.secureInput) {
                IMELog.write("buffer delivery blocked: secure input")
                return Result(Outcome.BLOCKED, delivered, model.blocks.size, wasTerminal = false)
            }
            if (!Delivery.insert(block.text, target)) {
                return Result(Outcome.BLOCKED, delivered, model.blocks.size, wasTerminal = false)
            }
            model.consumeDelivered(listOf(block.id))
            delivered++
        }
        val remaining = model.blocks.size
        IMELog.write("buffer delivered blocks=$delivered remaining=$remaining all=$all")
        return Result(Outcome.DELIVERED, delivered, remaining, wasTerminal = delivered > 0 && remaining == 0)
    }
}
