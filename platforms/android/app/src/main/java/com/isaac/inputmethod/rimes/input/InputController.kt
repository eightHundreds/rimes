package com.isaac.inputmethod.rimes.input

import android.view.KeyEvent
import com.isaac.inputmethod.rimes.IMELog
import com.isaac.inputmethod.rimes.buffer.BufferDeliveryCoordinator
import com.isaac.inputmethod.rimes.buffer.BufferModel
import com.isaac.inputmethod.rimes.buffer.Origin
import com.isaac.inputmethod.rimes.rime.RimeContextModel
import com.isaac.inputmethod.rimes.rime.RimeEngineApi
import com.isaac.inputmethod.rimes.rime.RimeKey
import com.isaac.inputmethod.rimes.rime.RimeStatusModel

/** Aggregate statistics sink (统计 / 打字测速 extensions). Never receives text. */
interface InputTelemetrySink {
    fun recordKey(keycode: Int)
    fun recordCommit(characterCount: Int, toBuffer: Boolean)
}

/** Everything the input view needs to render one frame. */
data class InputUiState(
    val context: RimeContextModel = RimeContextModel.EMPTY,
    val status: RimeStatusModel = RimeStatusModel.EMPTY,
    val bufferEnabled: Boolean = false,
    val bufferCaptures: Boolean = false,
    val bufferBlocks: List<BufferModel.Block> = emptyList(),
    val bufferInsertionIndex: Int = 0,
    val chordPending: Boolean = false,
    val secureInput: Boolean = false,
    val engineState: EngineState = EngineState.STARTING,
    val engineMessage: String = "",
)

enum class EngineState { STARTING, READY, FAILED }

/**
 * Key routing, composition, commit drain and buffer capture for one bound
 * field. Port of the load-bearing parts of `RimeBufferController.swift`:
 *
 *  - one Rime session per bound field, created lazily and destroyed on unbind;
 *  - Rime first for every mapped key, then buffer/host fallbacks;
 *  - `drainCommit` is the single routing point: capture -> [BufferModel],
 *    direct -> [Delivery.insert];
 *  - chord release replay only for `my_combo` while the extension is enabled;
 *  - printable keys can never be dropped: engine outage falls back to raw text;
 *  - secure fields bypass Rime and the buffer entirely.
 */
class InputController(
    private val engine: RimeEngineApi,
    val buffer: BufferModel,
    private val configuration: InputConfigurationStore,
    private val chordExtension: ChordExtensionStore,
    scheduler: ChordController.Scheduler,
    private val telemetry: InputTelemetrySink? = null,
    preeditDecorator: (String) -> CharSequence = CompositionSession::underlined,
) {
    fun interface UiListener {
        fun uiStateDidChange(state: InputUiState)
    }

    var uiListener: UiListener? = null

    /** Preference: close (pause) the workbench after the last block is delivered. */
    var closeBufferAfterLastDelivery: Boolean = true

    var engineState: EngineState = EngineState.STARTING
        private set
    var engineMessage: String = ""
        private set

    private var client: HostClient? = null
    private var session: Long = 0L
    private val composition = CompositionSession(preeditDecorator)
    private val chord = ChordController(scheduler).also { controller ->
        controller.onFlush = { keys -> replayChordReleases(keys) }
        controller.onDiscard = { publishUi() }
    }
    private val mutualPairing = FlyChordMutualPairingState()
    private var pendingChordBase: Pair<RimeContextModel, FlyChordSettlementPolicy>? = null
    private val deliveryCoordinator = BufferDeliveryCoordinator(buffer)
    private var directRunBlockId: java.util.UUID? = null

    var lastUiState: InputUiState = InputUiState()
        private set

    init {
        chord.durationMillis = chordExtension.durationMillis
    }

    // MARK: Lifecycle

    fun setEngineState(state: EngineState, message: String = "") {
        engineState = state
        engineMessage = message
        publishUi()
    }

    /** A field gained focus. Creates the per-field session and applies the stored schema. */
    fun bind(host: HostClient) {
        if (client?.token == host.token && session != 0L && engine.sessionExists(session)) {
            client = host
            publishUi()
            return
        }
        unbind()
        client = host
        directRunBlockId = null
        if (!host.secureInput) {
            ensureSessionReady()
        }
        // A new exact field returns to direct routing; the workbench keeps content.
        if (buffer.captureOwner != host.token) buffer.pauseCapturePreservingContent()
        publishUi()
    }

    /** Focus left the field. Settles chords and composition without inserting into the old field. */
    fun unbind() {
        val old = client ?: run {
            destroySession()
            return
        }
        chord.invalidate()
        mutualPairing.reset()
        pendingChordBase = null
        if (session != 0L) {
            engine.clearComposition(session)
            engine.takeCommit(session)
        }
        composition.markCleared()
        client = null
        destroySession()
        if (buffer.captureOwner == old.token) buffer.pauseCapturePreservingContent()
    }

    fun refreshClient(host: HostClient) {
        if (client?.token == host.token) client = host
    }

    val boundToken: FocusToken? get() = client?.token
    val isBound: Boolean get() = client != null

    private fun destroySession() {
        if (session != 0L) {
            engine.destroySession(session)
            session = 0L
        }
    }

    private fun ensureSessionReady(): Boolean {
        if (!engine.start()) return false
        if (session != 0L && engine.sessionExists(session)) return true
        session = engine.createSession()
        if (session == 0L) return false
        applyStoredSchemaPreference()
        return true
    }

    private fun applyStoredSchemaPreference() {
        if (session == 0L) return
        val wanted = configuration.selectedSchemaId
        val current = engine.currentSchema(session)
        if (current != wanted) {
            val deployed = engine.schemaList().map { it.id }
            if (wanted in deployed || deployed.isEmpty()) {
                if (!engine.selectSchema(wanted, session)) {
                    IMELog.write("schema preference $wanted rejected by librime")
                }
            } else {
                IMELog.write("schema preference $wanted not deployed; keeping $current")
            }
        }
    }

    /** Settings changed the schema or the chord extension. */
    fun applyStoredInputConfiguration() {
        chord.durationMillis = chordExtension.durationMillis
        if (session == 0L) return
        if (composition.composing || chord.hasPending) forceCommit()
        applyStoredSchemaPreference()
        publishUi()
    }

    // MARK: User dictionary maintenance

    fun prepareForUserDictionaryMaintenance() {
        forceCommit()
        composition.markCleared()
        destroySession()
        publishUi()
    }

    fun finishUserDictionaryMaintenance() {
        if (client != null && client?.secureInput == false) ensureSessionReady()
        publishUi()
    }

    // MARK: Key routing

    /**
     * Route one physical or soft key press. `keycode` is an X11 keysym, `mask`
     * the Rime modifier mask (never containing the release bit). Returns true
     * when the input method consumed the key.
     */
    fun handleKey(keycode: Int, mask: Int, isRepeat: Boolean = false): Boolean {
        val host = client ?: return false
        telemetry?.recordKey(keycode)

        if (host.secureInput) return handleSecureKey(keycode, mask, host)

        val unmodified = !RimeKey.hasCommandModifier(mask)
        if (buffer.capturesInput(host.token)) {
            if (keycode == RimeKey.BACKSPACE && unmodified) {
                return handleBufferBackspace(mask, host)
            }
            if ((keycode == RimeKey.RETURN || keycode == RimeKey.KEYPAD_ENTER) && unmodified) {
                // Return with pending composition only settles it; sending is a
                // separate tap/hold gesture (see performBufferSend). Either way
                // the host never receives a newline while the buffer captures.
                if (chord.hasPending || compositionActive()) settlePendingComposition(host)
                publishUi()
                return true
            }
        }

        // Engine down: raw fallback so the user can still type Latin.
        if (!ensureSessionReady()) {
            return rawFallback(keycode, mask, host)
        }

        if (keycode == RimeKey.RETURN && unmodified && commitRawInput(host)) {
            return true
        }

        val handled = processRimeKey(keycode, mask, host)
        if (handled) return true

        if (RimeKey.isPrintable(keycode) && unmodified && !isRepeat) {
            // librime intentionally returns Latin keys to the frontend in ASCII
            // mode; that frontend is the workbench while it captures the field.
            val scalar = if (mask and RimeKey.SHIFT_MASK != 0 && keycode in 'a'.code..'z'.code) keycode - 0x20 else keycode
            insertDirectText(scalar.toChar().toString(), host, source = "unhandled printable")
            return true
        }
        if (RimeKey.isPrintable(keycode) && unmodified && isRepeat) {
            insertDirectText(keycode.toChar().toString(), host, source = "unhandled printable repeat")
            return true
        }
        if ((keycode == RimeKey.RETURN || keycode == RimeKey.KEYPAD_ENTER) && unmodified) {
            if (buffer.capturesInput(host.token)) return true
            performHostEnter(host)
            return true
        }
        if (keycode == RimeKey.BACKSPACE && unmodified) {
            host.sendKeyEvent(KeyEvent.KEYCODE_DEL)
            return true
        }
        return false
    }

    /** True when Return belongs to the buffer gesture state machine rather than Rime/host. */
    fun bufferOwnsReturn(): Boolean {
        val host = client ?: return false
        return !host.secureInput && buffer.capturesInput(host.token)
    }

    fun hasPendingComposition(): Boolean = chord.hasPending || compositionActive()

    /** A modifier tap that Rime should see as press+release (standalone Shift toggles ASCII). */
    fun handleStandaloneModifierTap(keysym: Int): Boolean {
        val host = client ?: return false
        if (host.secureInput || !ensureSessionReady()) return false
        val mask = when (keysym) {
            RimeKey.SHIFT_L, RimeKey.SHIFT_R -> RimeKey.SHIFT_MASK
            RimeKey.CONTROL_L, RimeKey.CONTROL_R -> RimeKey.CONTROL_MASK
            else -> 0
        }
        chord.flush()
        engine.processKey(keysym, mask, session)
        val handled = engine.processKey(keysym, mask or RimeKey.RELEASE_MASK, session)
        drainCommit(host)
        publishUi()
        return handled
    }

    private fun handleSecureKey(keycode: Int, mask: Int, host: HostClient): Boolean {
        if (RimeKey.hasCommandModifier(mask)) return false
        return when {
            RimeKey.isPrintable(keycode) -> {
                val scalar = if (mask and RimeKey.SHIFT_MASK != 0 && keycode in 'a'.code..'z'.code) keycode - 0x20 else keycode
                Delivery.insert(scalar.toChar().toString(), host, allowSecure = true)
                true
            }
            keycode == RimeKey.BACKSPACE -> {
                host.sendKeyEvent(KeyEvent.KEYCODE_DEL)
                true
            }
            keycode == RimeKey.RETURN || keycode == RimeKey.KEYPAD_ENTER -> {
                performHostEnter(host)
                true
            }
            else -> false
        }
    }

    private fun rawFallback(keycode: Int, mask: Int, host: HostClient): Boolean {
        if (RimeKey.hasCommandModifier(mask)) return false
        if (RimeKey.isPrintable(keycode)) {
            val scalar = if (mask and RimeKey.SHIFT_MASK != 0 && keycode in 'a'.code..'z'.code) keycode - 0x20 else keycode
            insertDirectText(scalar.toChar().toString(), host, source = "engine down")
            return true
        }
        if (keycode == RimeKey.BACKSPACE) {
            if (buffer.capturesInput(host.token)) return handleBufferBackspace(mask, host)
            host.sendKeyEvent(KeyEvent.KEYCODE_DEL)
            return true
        }
        if (keycode == RimeKey.RETURN || keycode == RimeKey.KEYPAD_ENTER) {
            if (buffer.capturesInput(host.token)) return true
            performHostEnter(host)
            return true
        }
        return false
    }

    private fun processRimeKey(keycode: Int, mask: Int, host: HostClient): Boolean {
        val status = engine.getStatus(session)
        val chordGated = FlyChordRoutingRules.shouldStage(
            schemaId = status.schemaId,
            asciiMode = status.asciiMode,
            extensionEnabled = chordExtension.isEnabled,
        )
        val isChordKey = !RimeKey.hasCommandModifier(mask) && RimeKey.isChordingKey(keycode) && chordGated
        if (!isChordKey) {
            // A press of a non-chord key resolves the pending chord first.
            chord.flush()
            mutualPairing.reset()
        }

        if (isChordKey) {
            val policy = chordExtension.mode.settlementPolicy
            if (!chord.hasPending) {
                pendingChordBase = engine.getContext(session) to policy
            }
            val batchPolicy = pendingChordBase?.second ?: policy
            when (val decision = chord.stageChordKey(keycode, mask, batchPolicy)) {
                FlyChordPressDecision.Consume -> {
                    publishUi()
                    return true
                }
                is FlyChordPressDecision.Process -> {
                    // Presses are staged until the batch boundary; every shape
                    // settles and only 互击 may later recombine two batches.
                    decision.keys.forEach { chord.noteHandledChordKey(it.keycode, it.mask) }
                    publishUi()
                    return true
                }
            }
        }

        val handled = engine.processKey(keycode, mask, session)
        if (handled) chord.flush()
        drainCommit(host)
        publishUi()
        return handled
    }

    // MARK: Chord replay

    private fun replayChordReleases(keys: List<FlyChordKeyEvent>) {
        val host = client ?: return
        if (session == 0L) return
        val base = pendingChordBase
        pendingChordBase = null
        val policy = base?.second ?: chordExtension.mode.settlementPolicy
        val baseContext = base?.first ?: engine.getContext(session)
        val shape = FlyChordBatchShape.of(keys)

        // 互击: a settled left-only initial followed by a right-only final is
        // one syllable. Roll back the left insertion and replay both halves as
        // one full chord so Rime sees the same canonical raw input.
        val complement = if (shape != null) {
            mutualPairing.takeComplement(shape, keys.size, policy, baseContext)
        } else {
            null
        }
        val replayKeys: List<FlyChordKeyEvent>
        if (complement != null) {
            // Remove exactly the left batch's insertion (delimiters included) so
            // the combined chord starts from the same base input.
            repeat(complement.insertedScalarCount) { engine.processKey(RimeKey.BACKSPACE, 0, session) }
            replayKeys = complement.keys + keys
        } else {
            replayKeys = keys
        }

        val beforeReplay = engine.getContext(session)
        val boundaryPlan = FlyChordBoundaryRules.plan(beforeReplay)
        val insertsBoundary = FlyChordBoundaryRules.shouldInsert(replayKeys.size)
        val delimiter = FlyChordBoundaryRules.DELIMITER_KEYCODE
        if (insertsBoundary && boundaryPlan.before) engine.processKey(delimiter, 0, session)
        for (key in replayKeys) engine.processKey(key.keycode, key.mask, session)
        for (key in replayKeys) engine.processKey(key.keycode, key.mask or RimeKey.RELEASE_MASK, session)
        if (insertsBoundary && boundaryPlan.after) engine.processKey(delimiter, 0, session)

        val settled = engine.getContext(session)
        if (shape != null && complement == null) {
            mutualPairing.recordSettledLeft(
                keys = keys,
                baseInput = beforeReplay.input,
                settledContext = settled,
                boundaryPlan = boundaryPlan,
                policy = policy,
                shape = shape,
            )
        } else {
            mutualPairing.reset()
        }
        drainCommit(host)
        publishUi()
    }

    // MARK: Buffer controls

    private fun handleBufferBackspace(mask: Int, host: HostClient): Boolean {
        if (chord.hasPending) {
            chord.flush()
            return true
        }
        if (session != 0L && engine.getContext(session).active) {
            engine.processKey(RimeKey.BACKSPACE, mask, session)
            drainCommit(host)
            publishUi()
            return true
        }
        directRunBlockId = null
        if (!buffer.removeLastBlock()) {
            IMELog.write("buffer backspace on empty workbench consumed")
        }
        publishUi()
        return true
    }

    /** Return tap while the buffer captures: send the next block to the exact field. */
    fun performBufferSend(all: Boolean): BufferDeliveryCoordinator.Result? {
        val host = client ?: return null
        if (!buffer.enabled) return null
        if (chord.hasPending || compositionActive()) {
            settlePendingComposition(host)
            return null
        }
        val expected = host.token
        val result = if (all) {
            deliveryCoordinator.sendAll(expected) { client }
        } else {
            deliveryCoordinator.sendNext(expected) { client }
        }
        if (result.outcome == BufferDeliveryCoordinator.Outcome.DELIVERED) {
            if (result.wasTerminal && closeBufferAfterLastDelivery) {
                buffer.pauseCapturePreservingContent()
            }
        }
        directRunBlockId = null
        publishUi()
        return result
    }

    fun toggleBufferCapture() {
        val host = client
        if (!buffer.enabled) return
        if (host != null && buffer.capturesInput(host.token)) {
            settlePendingComposition(host)
            buffer.pauseCapturePreservingContent()
        } else if (host != null && !host.secureInput) {
            settlePendingComposition(host)
            composition.clear(host)
            buffer.activateCapture(host.token)
        }
        publishUi()
    }

    fun setBufferEnabled(enabled: Boolean) {
        buffer.enabled = enabled
        if (enabled) {
            client?.takeIf { !it.secureInput }?.let { host ->
                settlePendingComposition(host)
                composition.clear(host)
                buffer.activateCapture(host.token)
            }
        }
        publishUi()
    }

    /** Text pasted into the workbench by the user (paste is never host-directed). */
    fun pasteIntoBuffer(text: String): Boolean {
        val host = client ?: return false
        if (!buffer.capturesInput(host.token) || text.isEmpty() || text.length > 1_048_576 || text.contains('\u0000')) return false
        settlePendingComposition(host)
        directRunBlockId = null
        buffer.append(text, Origin.Paste)
        publishUi()
        return true
    }

    // MARK: Candidates / schema / options

    fun selectCandidate(onPageIndex: Int): Boolean {
        val host = client ?: return false
        if (session == 0L) return false
        chord.flush()
        val ok = engine.selectCandidate(onPageIndex, session)
        drainCommit(host)
        publishUi()
        return ok
    }

    fun pageCandidates(delta: Int): Boolean {
        val host = client ?: return false
        if (session == 0L) return false
        return processRimeKey(if (delta < 0) RimeKey.PAGE_UP else RimeKey.PAGE_DOWN, 0, host)
    }

    /**
     * Collects up to `maxPages` following pages (including the current one)
     * for the expanded candidate matrix, then restores the current page. The
     * session ends on the same page it started on.
     */
    fun previewCandidatePages(maxPages: Int): List<RimeContextModel> {
        if (session == 0L) return emptyList()
        val first = engine.getContext(session)
        if (!first.active || first.candidates.isEmpty()) return emptyList()
        val pages = mutableListOf(first)
        var moved = 0
        while (pages.size < maxPages && !pages.last().isLastPage) {
            if (!engine.processKey(RimeKey.PAGE_DOWN, 0, session)) break
            val next = engine.getContext(session)
            if (next.pageNo == pages.last().pageNo) break
            pages += next
            moved++
        }
        repeat(moved) { engine.processKey(RimeKey.PAGE_UP, 0, session) }
        return pages
    }

    fun selectCandidate(pageDelta: Int, indexOnPage: Int): Boolean {
        if (session == 0L) return false
        repeat(pageDelta) { engine.processKey(RimeKey.PAGE_DOWN, 0, session) }
        return selectCandidate(indexOnPage)
    }

    fun toggleAsciiMode(): Boolean = handleStandaloneModifierTap(RimeKey.SHIFT_L)

    fun setOption(name: String, value: Boolean) {
        if (session == 0L) return
        engine.setOption(name, value, session)
        publishUi()
    }

    fun getOption(name: String): Boolean = session != 0L && engine.getOption(name, session)

    fun selectSchema(schemaId: String): Boolean {
        val host = client
        if (host != null) forceCommit()
        if (!configuration.select(schemaId)) return false
        if (session != 0L) {
            engine.selectSchema(schemaId, session)
        }
        publishUi()
        return true
    }

    fun cycleSchema(): String? {
        val enabled = engine.schemaList().map { it.id }.ifEmpty { InputSchemaCatalog.enabledIds(chordExtension.isEnabled) }
        val visible = InputSchemaCatalog.normalized(enabled).filter { it != InputSchemaCatalog.CHORD_SCHEMA_ID || chordExtension.isEnabled }
        if (visible.isEmpty()) return null
        val current = configuration.selectedSchemaId
        val next = visible[(visible.indexOf(current) + 1).mod(visible.size)]
        return if (selectSchema(next)) next else null
    }

    fun forceCommit() {
        val host = client ?: return
        if (chord.hasPending) chord.flush()
        mutualPairing.reset()
        if (session == 0L) return
        engine.commitComposition(session)
        drainCommit(host)
        engine.clearComposition(session)
        composition.clear(host)
        publishUi()
    }

    /** Escape: drop the composition without inserting. */
    fun cancelComposition() {
        val host = client ?: return
        chord.invalidate()
        mutualPairing.reset()
        if (session != 0L) engine.clearComposition(session)
        composition.clear(host)
        publishUi()
    }

    /** An Enter that neither Rime nor the buffer consumed: editor action first, raw key otherwise. */
    private fun performHostEnter(host: HostClient) {
        if (!host.performEditorAction()) host.sendKeyEvent(KeyEvent.KEYCODE_ENTER)
    }

    // MARK: Commit drain + UI

    private fun compositionActive(): Boolean = session != 0L && engine.getContext(session).active

    private fun settlePendingComposition(host: HostClient) {
        if (chord.hasPending) chord.flush()
        mutualPairing.reset()
        if (session != 0L && engine.getContext(session).active) {
            if (!commitRawInput(host)) {
                engine.commitComposition(session)
                drainCommit(host)
                engine.clearComposition(session)
            }
        }
        composition.clear(host)
    }

    /** Return with raw input pending: insert the raw letters (Rime-idle Return semantics). */
    private fun commitRawInput(host: HostClient): Boolean {
        if (session == 0L) return false
        if (chord.hasPending) chord.flush()
        mutualPairing.reset()
        val ctx = engine.getContext(session)
        val raw = ctx.input
        if (raw.isEmpty()) return false
        engine.clearComposition(session)
        routeCommittedText(raw, host, source = "raw")
        publishUi()
        return true
    }

    /**
     * The single routing point: buffer capture -> the commit becomes a staged
     * block and the inline preedit is cleared from the field; direct -> host.
     */
    private fun drainCommit(host: HostClient): String? {
        val commit = engine.takeCommit(session) ?: return null
        routeCommittedText(commit, host, source = "commit")
        return commit
    }

    private fun routeCommittedText(text: String, host: HostClient, source: String) {
        directRunBlockId = null
        if (buffer.capturesInput(host.token)) {
            buffer.append(text, Origin.Rime)
            composition.clear(host)
            telemetry?.recordCommit(text.length, toBuffer = true)
            IMELog.write("$source ${IMELog.redact(text)} -> buffer (${buffer.blocks.size} blocks)")
        } else {
            val inserted = Delivery.insert(text, host)
            composition.commitDidInsert()
            if (inserted) telemetry?.recordCommit(text.length, toBuffer = false)
            IMELog.write("$source ${IMELog.redact(text)} inserted=$inserted")
        }
    }

    private fun insertDirectText(text: String, host: HostClient, source: String) {
        if (buffer.capturesInput(host.token)) {
            // Consecutive direct characters form one run so ASCII words stay one block.
            val runId = directRunBlockId
            val existing = runId?.let { buffer.block(it) }
            if (existing != null && buffer.blocks.lastOrNull()?.id == existing.id) {
                buffer.removeBlock(existing.id)
                directRunBlockId = buffer.append(existing.text + text, Origin.Rime)?.id
            } else {
                directRunBlockId = buffer.append(text, Origin.Rime)?.id
            }
            telemetry?.recordCommit(text.length, toBuffer = true)
        } else {
            composition.clear(host)
            val inserted = Delivery.insert(text, host)
            if (inserted) telemetry?.recordCommit(text.length, toBuffer = false)
            IMELog.write("direct text ${IMELog.redact(text)} inserted=$inserted source=$source")
        }
        publishUi()
    }

    fun publishUi() {
        val host = client
        val context = if (session != 0L) engine.getContext(session) else RimeContextModel.EMPTY
        val status = if (session != 0L) engine.getStatus(session) else RimeStatusModel.EMPTY
        val captures = host != null && buffer.capturesInput(host.token)
        if (host != null) {
            when (HostMarkedTextPresentationRules.presentation(captures, host.secureInput)) {
                HostMarkedTextPresentation.NORMAL_PREEDIT -> {
                    if (context.active && context.preedit.isNotEmpty()) {
                        composition.update(context.preedit, context.cursorPos, host)
                    } else {
                        composition.clear(host)
                    }
                }
                HostMarkedTextPresentation.BUFFER_PROJECTED, HostMarkedTextPresentation.NONE -> composition.clear(host)
            }
        }
        val state = InputUiState(
            context = context,
            status = status,
            bufferEnabled = buffer.enabled,
            bufferCaptures = captures,
            bufferBlocks = buffer.blocks,
            bufferInsertionIndex = buffer.insertionIndex,
            chordPending = chord.hasPending,
            secureInput = host?.secureInput == true,
            engineState = engineState,
            engineMessage = engineMessage,
        )
        lastUiState = state
        uiListener?.uiStateDidChange(state)
    }

    val currentSchemaId: String? get() = if (session != 0L) engine.currentSchema(session) else null
}
