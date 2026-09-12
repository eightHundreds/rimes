package com.isaac.inputmethod.rimes.input

import com.isaac.inputmethod.rimes.rime.RimeContextModel

/** FlyYao divides every printable chording key by physical keyboard half. */
enum class FlyChordHalf { LEFT, RIGHT }

object FlyChordLayout {
    const val LEFT_ALPHABET = "qwertasdfgzxcvb"
    const val RIGHT_ALPHABET = "yuiophjklnm,."

    private val leftKeycodes = LEFT_ALPHABET.map { it.code }.toSet()
    private val rightKeycodes = RIGHT_ALPHABET.map { it.code }.toSet()

    fun half(keycode: Int): FlyChordHalf? = when (keycode) {
        in leftKeycodes -> FlyChordHalf.LEFT
        in rightKeycodes -> FlyChordHalf.RIGHT
        else -> null
    }
}

/**
 * - [SAME_BATCH_ONLY] is 并击: every key inside the current timer batch resolves together.
 * - [INDEPENDENT_HALVES] is 互击: same per-batch settlement, plus a settled left-only
 *   initial may pair with the next right-only final when at least one half is multi-key.
 */
enum class FlyChordSettlementPolicy { SAME_BATCH_ONLY, INDEPENDENT_HALVES }

/**
 * A my_combo session only owns plain alphabet presses while it is composing
 * Chinese; in ASCII mode Rime returns those keys to the host.
 */
object FlyChordRoutingRules {
    fun shouldStage(schemaId: String, asciiMode: Boolean, extensionEnabled: Boolean): Boolean =
        extensionEnabled && schemaId == InputSchemaCatalog.CHORD_SCHEMA_ID && !asciiMode
}

data class FlyChordBoundaryPlan(val before: Boolean, val after: Boolean)

/**
 * Every settled multi-key FlyYao batch is one syllable; the delimiter keeps
 * Rime's speller from merging two strokes whose spellings also form one valid
 * syllable (`ni` + `an` -> `nian`). A one-key batch stays literal.
 */
object FlyChordBoundaryRules {
    const val DELIMITER_KEYCODE = 0x27 // '

    fun shouldInsert(keyCount: Int): Boolean = keyCount > 1

    fun plan(context: RimeContextModel): FlyChordBoundaryPlan {
        val bytes = context.input.toByteArray(Charsets.UTF_8)
        val cursor = context.cursorPos.coerceIn(0, bytes.size)
        val delimiter = DELIMITER_KEYCODE.toByte()
        return FlyChordBoundaryPlan(
            before = cursor > 0 && bytes[cursor - 1] != delimiter,
            after = cursor < bytes.size && bytes[cursor] != delimiter,
        )
    }
}

data class FlyChordKeyEvent(val keycode: Int, val mask: Int)

sealed class FlyChordPressDecision {
    /** Auto-repeat/overflow/unknown key: consumed, not staged again. */
    data object Consume : FlyChordPressDecision()

    /** Newly staged presses that join the eventual replay set. */
    data class Process(val keys: List<FlyChordKeyEvent>) : FlyChordPressDecision()
}

enum class FlyChordBatchShape {
    LEFT_ONLY, RIGHT_ONLY, BOTH_HALVES;

    companion object {
        fun of(keys: List<FlyChordKeyEvent>): FlyChordBatchShape? {
            val halves = keys.mapNotNull { FlyChordLayout.half(it.keycode) }.toSet()
            return when (halves) {
                setOf(FlyChordHalf.LEFT) -> LEFT_ONLY
                setOf(FlyChordHalf.RIGHT) -> RIGHT_ONLY
                setOf(FlyChordHalf.LEFT, FlyChordHalf.RIGHT) -> BOTH_HALVES
                else -> null
            }
        }
    }
}

/** Detect the one mutation chord_composer may make when a batch is released: one contiguous insertion at the cursor. */
object FlyChordInputRollback {
    fun insertedScalarCount(before: String, after: String): Int? {
        val old = before.codePoints().toArray()
        val new = after.codePoints().toArray()
        if (new.size < old.size) return null
        val inserted = new.size - old.size
        for (offset in 0..old.size) {
            val prefixMatches = (0 until offset).all { new[it] == old[it] }
            if (!prefixMatches) continue
            val suffixMatches = (offset until old.size).all { new[it + inserted] == old[it] }
            if (!suffixMatches) continue
            return inserted
        }
        return null
    }
}

/**
 * Tracks the one cross-batch relationship 互击 must preserve: a settled
 * left-only initial followed by a right-only final belongs to one syllable.
 */
class FlyChordMutualPairingState {
    data class SettledLeft(
        val keys: List<FlyChordKeyEvent>,
        val baseInput: String,
        val settledInput: String,
        val settledCursorPos: Int,
        val settledSelStart: Int,
        val settledSelEnd: Int,
        val boundaryPlan: FlyChordBoundaryPlan,
        val insertedScalarCount: Int,
    )

    private var settledLeft: SettledLeft? = null

    fun recordSettledLeft(
        keys: List<FlyChordKeyEvent>,
        baseInput: String,
        settledContext: RimeContextModel,
        boundaryPlan: FlyChordBoundaryPlan,
        policy: FlyChordSettlementPolicy,
        shape: FlyChordBatchShape,
    ) {
        val inserted = FlyChordInputRollback.insertedScalarCount(baseInput, settledContext.input)
        if (policy != FlyChordSettlementPolicy.INDEPENDENT_HALVES || shape != FlyChordBatchShape.LEFT_ONLY ||
            inserted == null || inserted <= 0
        ) {
            settledLeft = null
            return
        }
        settledLeft = SettledLeft(
            keys, baseInput, settledContext.input, settledContext.cursorPos,
            settledContext.selStart, settledContext.selEnd, boundaryPlan, inserted,
        )
    }

    fun takeComplement(
        shape: FlyChordBatchShape,
        currentKeyCount: Int,
        policy: FlyChordSettlementPolicy,
        currentContext: RimeContextModel,
    ): SettledLeft? {
        val pending = settledLeft
        settledLeft = null
        if (policy != FlyChordSettlementPolicy.INDEPENDENT_HALVES || shape != FlyChordBatchShape.RIGHT_ONLY || pending == null) return null
        if (pending.keys.size <= 1 && currentKeyCount <= 1) return null
        if (pending.settledInput != currentContext.input ||
            pending.settledCursorPos != currentContext.cursorPos ||
            pending.settledSelStart != currentContext.selStart ||
            pending.settledSelEnd != currentContext.selEnd
        ) return null
        return pending
    }

    fun reset() {
        settledLeft = null
    }
}

/** Pure batching state, independent of timers so the contract is unit-testable. */
class FlyChordBatchState {
    private val pending = mutableListOf<FlyChordKeyEvent>()
    private val handled = mutableListOf<FlyChordKeyEvent>()

    val hasPending: Boolean get() = pending.isNotEmpty()
    val pendingKeys: List<FlyChordKeyEvent> get() = pending.toList()

    fun stage(key: FlyChordKeyEvent, @Suppress("UNUSED_PARAMETER") policy: FlyChordSettlementPolicy): FlyChordPressDecision {
        FlyChordLayout.half(key.keycode) ?: return FlyChordPressDecision.Consume
        if (pending.any { it.keycode == key.keycode }) return FlyChordPressDecision.Consume
        if (pending.size >= 50) return FlyChordPressDecision.Consume
        pending += key
        // Both modes settle every current batch; they differ only in whether
        // the owner later recombines two batches.
        return FlyChordPressDecision.Process(listOf(key))
    }

    fun noteHandled(key: FlyChordKeyEvent) {
        if (key in pending && key !in handled) handled += key
    }

    fun settle(): List<FlyChordKeyEvent> {
        val replay = handled.toList()
        pending.clear()
        handled.clear()
        return replay
    }

    fun reset() {
        pending.clear()
        handled.clear()
    }
}

/**
 * Chord (并击) release-replay, Squirrel-style: chord keys that Rime handled
 * are buffered; when the duration elapses with no new chord key, every
 * buffered key is replayed with the release mask so chord_composer resolves
 * the chord. The OWNER gates this on the active schema (only my_combo).
 */
class ChordController(private val scheduler: Scheduler) {
    /** Abstracts the main-thread timer so tests can fire deterministically. */
    interface Scheduler {
        fun schedule(delayMillis: Long, action: () -> Unit): Any
        fun cancel(token: Any)
    }

    var durationMillis: Long = ChordSettings.DEFAULT_DURATION_MS

    private val batch = FlyChordBatchState()
    private var timerToken: Any? = null

    /** Replays keys (with the release mask) against the session and drains commits. */
    var onFlush: ((keys: List<FlyChordKeyEvent>) -> Unit)? = null

    /** A defensive empty batch still needs to retire the temporary composition guard. */
    var onDiscard: (() -> Unit)? = null

    val hasPending: Boolean get() = batch.hasPending

    fun stageChordKey(keycode: Int, mask: Int, policy: FlyChordSettlementPolicy): FlyChordPressDecision {
        val decision = batch.stage(FlyChordKeyEvent(keycode, mask), policy)
        if (!batch.hasPending) return decision
        cancelTimer()
        timerToken = scheduler.schedule(durationMillis) { flush() }
        return decision
    }

    /** Record only presses that Rime accepted; releases are synthesised for this subset. */
    fun noteHandledChordKey(keycode: Int, mask: Int) {
        batch.noteHandled(FlyChordKeyEvent(keycode, mask))
    }

    /** Resolve the pending chord NOW (timer, non-chord key, focus loss, forced commit). */
    fun flush() {
        if (!batch.hasPending) return
        val keys = batch.settle()
        cancelTimer()
        if (keys.isEmpty()) onDiscard?.invoke() else onFlush?.invoke(keys)
    }

    /** Cancel after Rime rejected a press; returns the staged subset for release synthesis. */
    fun abort(): List<FlyChordKeyEvent> {
        val keys = batch.settle()
        cancelTimer()
        return keys
    }

    fun invalidate() {
        cancelTimer()
        batch.reset()
    }

    private fun cancelTimer() {
        timerToken?.let { scheduler.cancel(it) }
        timerToken = null
    }
}
