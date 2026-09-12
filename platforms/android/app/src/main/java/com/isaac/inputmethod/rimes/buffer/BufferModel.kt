package com.isaac.inputmethod.rimes.buffer

import com.isaac.inputmethod.rimes.input.FocusToken
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList

/** Where a block came from. Drives the provenance badge and delivery gating. */
sealed class Origin {
    /** Local typing (no badge). */
    data object Rime : Origin()

    /** Text pasted into the workbench by the user. */
    data object Paste : Origin()

    /** A locally derived result (segmenter, future plugins). */
    data class Processor(val id: String) : Origin()

    val badge: String?
        get() = when (this) {
            Rime -> null
            Paste -> "粘贴"
            is Processor -> id
        }
}

/** Where the exact focused field's next editing event is routed. */
enum class BufferInputRoute { DIRECT_TO_HOST, CAPTURE_TO_BUFFER }

/**
 * Ordered staging buffer. Rime commits establish block boundaries before they
 * enter this model, so editing and delivery preserve identity and provenance.
 *
 * Contract (see `references/buffer-ui.md`):
 *  - live blocks are pending by definition; successful delivery consumes them;
 *  - no automatic flushing, no timer deletion, no plaintext delivery history;
 *  - content is process-local and never persisted;
 *  - capture is bound to the exact [FocusToken]; a new field returns to direct routing.
 */
class BufferModel {
    data class Block(
        val id: UUID,
        val text: String,
        val origin: Origin,
        val createdAt: Long,
    )

    fun interface Listener {
        fun bufferDidChange(model: BufferModel)
    }

    private val listeners = CopyOnWriteArrayList<Listener>()
    private val mutableBlocks = mutableListOf<Block>()

    /** Product-level enablement of buffer mode (persisted by settings). */
    var enabled: Boolean = false
        set(value) {
            if (field == value) return
            field = value
            if (!value) captureOwner = null
            notifyChange()
        }

    /** The exact field whose typing is currently captured, or null for direct routing. */
    var captureOwner: FocusToken? = null
        private set

    /** Blocks are inserted here; defaults to the end. */
    var insertionIndex: Int = 0
        private set

    val blocks: List<Block> get() = mutableBlocks.toList()
    val isEmpty: Boolean get() = mutableBlocks.isEmpty()
    val text: String get() = mutableBlocks.joinToString("") { it.text }

    fun addListener(listener: Listener) = listeners.addIfAbsent(listener)
    fun removeListener(listener: Listener) = listeners.remove(listener)

    fun activateCapture(token: FocusToken) {
        if (!enabled) return
        if (captureOwner == token) return
        captureOwner = token
        notifyChange()
    }

    fun capturesInput(token: FocusToken?): Boolean = enabled && token != null && captureOwner == token

    fun route(token: FocusToken?): BufferInputRoute =
        if (capturesInput(token)) BufferInputRoute.CAPTURE_TO_BUFFER else BufferInputRoute.DIRECT_TO_HOST

    /** Focus moved or the workbench closed: keep content, route typing to the host. */
    fun pauseCapturePreservingContent() {
        if (captureOwner == null) return
        captureOwner = null
        notifyChange()
    }

    fun append(text: String, origin: Origin = Origin.Rime): Block? {
        if (text.isEmpty()) return null
        val block = Block(UUID.randomUUID(), text, origin, System.currentTimeMillis())
        val index = insertionIndex.coerceIn(0, mutableBlocks.size)
        mutableBlocks.add(index, block)
        insertionIndex = index + 1
        notifyChange()
        return block
    }

    fun setInsertionPoint(index: Int): Boolean {
        val clamped = index.coerceIn(0, mutableBlocks.size)
        if (clamped == insertionIndex) return false
        insertionIndex = clamped
        notifyChange()
        return true
    }

    fun moveInsertionPoint(delta: Int): Boolean = setInsertionPoint(insertionIndex + delta)

    /** Backspace in buffer mode with no composition: remove the block before the caret. */
    fun removeLastBlock(): Boolean {
        if (mutableBlocks.isEmpty()) return false
        val index = (insertionIndex - 1).coerceIn(0, mutableBlocks.size - 1)
        mutableBlocks.removeAt(index)
        insertionIndex = index
        notifyChange()
        return true
    }

    fun removeBlock(id: UUID): Boolean {
        val index = mutableBlocks.indexOfFirst { it.id == id }
        if (index < 0) return false
        mutableBlocks.removeAt(index)
        if (insertionIndex > index) insertionIndex--
        notifyChange()
        return true
    }

    fun block(id: UUID): Block? = mutableBlocks.firstOrNull { it.id == id }

    /** Consume blocks whose delivery was accepted, preserving the order of the rest. */
    fun consumeDelivered(blockIds: Collection<UUID>) {
        if (blockIds.isEmpty()) return
        val ids = blockIds.toSet()
        var removedBeforeCaret = 0
        mutableBlocks.forEachIndexed { index, block ->
            if (block.id in ids && index < insertionIndex) removedBeforeCaret++
        }
        mutableBlocks.removeAll { it.id in ids }
        insertionIndex = (insertionIndex - removedBeforeCaret).coerceIn(0, mutableBlocks.size)
        notifyChange()
    }

    /** Irreversible privacy discard (app switch with the reset preference, secure field). */
    fun discardForPrivacy() {
        if (mutableBlocks.isEmpty()) return
        mutableBlocks.clear()
        insertionIndex = 0
        notifyChange()
    }

    private fun notifyChange() {
        listeners.forEach { it.bufferDidChange(this) }
    }
}
