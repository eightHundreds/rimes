package com.isaac.inputmethod.rimes.service

import android.content.Intent
import android.content.SharedPreferences
import android.inputmethodservice.InputMethodService
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.FrameLayout
import android.widget.LinearLayout
import com.isaac.inputmethod.rimes.IMELog
import com.isaac.inputmethod.rimes.RimesApplication
import com.isaac.inputmethod.rimes.RimesPreferences
import com.isaac.inputmethod.rimes.input.ChordController
import com.isaac.inputmethod.rimes.input.ChordExtensionConfiguration
import com.isaac.inputmethod.rimes.input.ChordExtensionStore
import com.isaac.inputmethod.rimes.input.EngineState
import com.isaac.inputmethod.rimes.input.FocusToken
import com.isaac.inputmethod.rimes.input.HostClient
import com.isaac.inputmethod.rimes.input.InputConfigurationStore
import com.isaac.inputmethod.rimes.input.InputConnectionHost
import com.isaac.inputmethod.rimes.input.InputController
import com.isaac.inputmethod.rimes.input.InputSchemaCatalog
import com.isaac.inputmethod.rimes.input.InputUiState
import com.isaac.inputmethod.rimes.input.SecureInputRules
import com.isaac.inputmethod.rimes.rime.RimeEngine
import com.isaac.inputmethod.rimes.rime.RimeKey
import com.isaac.inputmethod.rimes.settings.SchemaPickerDialog
import com.isaac.inputmethod.rimes.settings.SettingsActivity
import com.isaac.inputmethod.rimes.ui.BufferRailView
import com.isaac.inputmethod.rimes.ui.CandidateBarView
import com.isaac.inputmethod.rimes.ui.ExpandedCandidatesView
import com.isaac.inputmethod.rimes.ui.RimesAppearance
import com.isaac.inputmethod.rimes.ui.SoftKeyboardView
import com.isaac.inputmethod.rimes.ui.ToolbarView

/**
 * The Android input method. Thin by design: it binds fields into
 * [InputController], forwards hardware and soft keys through the single
 * routing path, and renders [InputUiState]. All text reaches the field through
 * `Delivery.insert`.
 */
class RimesInputMethodService :
    InputMethodService(),
    InputController.UiListener,
    RimeEngine.MaintenanceObserver,
    SharedPreferences.OnSharedPreferenceChangeListener,
    InputConfigurationStore.Listener,
    ChordExtensionStore.Listener {

    private lateinit var app: RimesApplication
    private lateinit var controller: InputController
    private val mainHandler = Handler(Looper.getMainLooper())

    private var root: LinearLayout? = null
    private var bufferRail: BufferRailView? = null
    private var candidateBar: CandidateBarView? = null
    private var toolbar: ToolbarView? = null
    private var keyboard: SoftKeyboardView? = null
    private var expanded: ExpandedCandidatesView? = null
    private var keyboardHost: FrameLayout? = null

    private var generation = 0L
    private var currentToken: FocusToken? = null
    private var lastPackage: String? = null
    private var lastState = InputUiState()
    private var expandedVisible = false

    // Return tap/hold gesture (buffer send) and standalone Shift tap tracking.
    private var returnDownAt = 0L
    private var returnHoldFired = false
    private var returnSettledComposition = false
    private var shiftDownAt = 0L
    private var shiftKeysym = 0
    private var otherKeyDuringShift = false
    private val returnHoldRunnable = Runnable {
        returnHoldFired = true
        controller.performBufferSend(all = true)
    }

    override fun onCreate() {
        super.onCreate()
        app = RimesApplication.of(this)
        controller = InputController(
            engine = app.engine,
            buffer = app.bufferModel,
            configuration = app.inputConfigurationStore,
            chordExtension = app.chordExtensionStore,
            scheduler = HandlerScheduler(mainHandler),
            telemetry = app.statistics,
        )
        controller.uiListener = this
        controller.closeBufferAfterLastDelivery = app.prefs.getBoolean(RimesPreferences.BUFFER_CLOSE_AFTER_LAST, true)
        app.engine.addMaintenanceObserver(this)
        app.prefs.registerOnSharedPreferenceChangeListener(this)
        app.inputConfigurationStore.addListener(this)
        app.chordExtensionStore.addListener(this)
        startEngine()
    }

    override fun onDestroy() {
        app.engine.removeMaintenanceObserver(this)
        app.prefs.unregisterOnSharedPreferenceChangeListener(this)
        app.inputConfigurationStore.removeListener(this)
        app.chordExtensionStore.removeListener(this)
        controller.unbind()
        super.onDestroy()
    }

    private fun startEngine() {
        controller.setEngineState(EngineState.STARTING, "正在部署输入方案…")
        val future = app.startEngineAsync()
        app.engineExecutor.execute {
            val ok = runCatching { future.get() }.getOrDefault(false)
            mainHandler.post {
                if (ok) {
                    controller.setEngineState(EngineState.READY)
                    // A field may already be bound; give it a session now.
                    currentInputEditorInfo?.let { bindCurrentField(it) }
                } else {
                    controller.setEngineState(EngineState.FAILED, "引擎启动失败：${app.engine.lastError()}")
                }
            }
        }
    }

    // MARK: Input view

    override fun onCreateInputView(): View {
        val palette = RimesAppearance.current(app.prefs).palette
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val rail = BufferRailView(this).apply {
            this.palette = palette
            listener = object : BufferRailView.Listener {
                override fun onSendNext() { controller.performBufferSend(all = false) }
                override fun onSendAll() { controller.performBufferSend(all = true) }
                override fun onToggleCapture() { controller.toggleBufferCapture() }
                override fun onSetInsertionPoint(index: Int) { controller.buffer.setInsertionPoint(index); controller.publishUi() }
                override fun onClose() {
                    controller.setBufferEnabled(false)
                    app.prefs.edit().putBoolean(RimesPreferences.BUFFER_ENABLED, false).apply()
                }
            }
        }
        val bar = CandidateBarView(this).apply {
            this.palette = palette
            listener = object : CandidateBarView.Listener {
                override fun onCandidateTap(indexOnPage: Int) { controller.selectCandidate(indexOnPage) }
                override fun onPage(delta: Int) { controller.pageCandidates(delta) }
                override fun onToggleExpanded() { setExpanded(!expandedVisible) }
            }
        }
        val strip = ToolbarView(this).apply {
            this.palette = palette
            listener = object : ToolbarView.Listener {
                override fun onSchemaTap() { controller.cycleSchema() }
                override fun onSchemaLongPress() { showSchemaPicker() }
                override fun onToggleBuffer() {
                    val enable = !controller.buffer.enabled
                    controller.setBufferEnabled(enable)
                    app.prefs.edit().putBoolean(RimesPreferences.BUFFER_ENABLED, enable).apply()
                }
                override fun onOpenSettings() { openSettings() }
                override fun onToggleAscii() { controller.toggleAsciiMode() }
            }
        }
        val keys = SoftKeyboardView(this).apply {
            this.palette = palette
            listener = object : SoftKeyboardView.Listener {
                override fun onKeyPress(keysym: Int, mask: Int) { onSoftKeyDown(keysym, mask) }
                override fun onKeyRelease(keysym: Int, mask: Int, heldMillis: Long) { onSoftKeyUp(keysym) }
                override fun onShiftTap() = Unit
                override fun onToggleAscii() { controller.toggleAsciiMode() }
                override fun onHideKeyboard() { requestHideSelf(0) }
            }
        }
        val matrix = ExpandedCandidatesView(this).apply {
            this.palette = palette
            listener = object : ExpandedCandidatesView.Listener {
                override fun onSelect(pageDelta: Int, indexOnPage: Int) {
                    setExpanded(false)
                    controller.selectCandidate(pageDelta, indexOnPage)
                }
                override fun onCollapse() { setExpanded(false) }
            }
            visibility = View.GONE
        }
        val host = FrameLayout(this)
        host.addView(keys, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT))
        host.addView(matrix, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))

        root.addView(rail, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        root.addView(bar, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        root.addView(strip, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        root.addView(host, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))

        this.root = root
        bufferRail = rail
        candidateBar = bar
        toolbar = strip
        keyboard = keys
        expanded = matrix
        keyboardHost = host
        render(lastState)
        return root
    }

    private fun applyPalette() {
        val palette = RimesAppearance.current(app.prefs).palette
        bufferRail?.palette = palette
        candidateBar?.palette = palette
        toolbar?.palette = palette
        keyboard?.palette = palette
        expanded?.palette = palette
    }

    private fun setExpanded(visible: Boolean) {
        val matrix = expanded ?: return
        val pages = if (visible) controller.previewCandidatePages(EXPANDED_PAGES) else emptyList()
        expandedVisible = visible && pages.isNotEmpty()
        if (expandedVisible) {
            matrix.render(pages, keyboard?.height ?: 0)
            matrix.visibility = View.VISIBLE
            keyboard?.visibility = View.INVISIBLE
        } else {
            matrix.visibility = View.GONE
            keyboard?.visibility = View.VISIBLE
        }
    }

    override fun onEvaluateFullscreenMode(): Boolean = false

    // MARK: Field lifecycle

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        if (attribute == null) return
        val packageName = attribute.packageName ?: ""
        if (lastPackage != null && lastPackage != packageName &&
            app.prefs.getBoolean(RimesPreferences.BUFFER_RESET_ON_APP_SWITCH, false)
        ) {
            app.bufferModel.discardForPrivacy()
        }
        lastPackage = packageName
        bindCurrentField(attribute)
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        if (info != null && (!controller.isBound || currentToken == null)) bindCurrentField(info)
        applyPalette()
        render(controller.lastUiState)
    }

    override fun onFinishInput() {
        super.onFinishInput()
        cancelReturnGesture()
        controller.unbind()
        currentToken = null
        setExpanded(false)
    }

    private fun bindCurrentField(info: EditorInfo) {
        val connection = currentInputConnection ?: return
        val secure = SecureInputRules.isSecure(info)
        val existing = currentToken
        val token = if (existing != null && existing.packageName == (info.packageName ?: "") && existing.fieldId == info.fieldId && controller.isBound) {
            existing
        } else {
            FocusToken(info.packageName ?: "", info.fieldId, ++generation)
        }
        currentToken = token
        val host = InputConnectionHost(connection, token, secure, info)
        controller.bind(host)
        if (secure) IMELog.write("secure field bound; Rime and buffer bypassed")
    }

    /** InputConnection objects can be replaced between callbacks; always bind the live one. */
    private fun refreshHost(): HostClient? {
        val token = currentToken ?: return null
        val info = currentInputEditorInfo ?: return null
        val connection = currentInputConnection ?: return null
        val host = InputConnectionHost(connection, token, SecureInputRules.isSecure(info), info)
        controller.refreshClient(host)
        return host
    }

    // MARK: Hardware keys

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (currentToken == null || currentInputConnection == null) return super.onKeyDown(keyCode, event)
        refreshHost()
        val keysym = RimeKey.fromKeyEvent(event) ?: return super.onKeyDown(keyCode, event)
        if (RimeKey.isModifierKeysym(keysym)) {
            if (keysym == RimeKey.SHIFT_L || keysym == RimeKey.SHIFT_R) {
                if (event.repeatCount == 0) {
                    shiftDownAt = System.currentTimeMillis()
                    shiftKeysym = keysym
                    otherKeyDuringShift = false
                }
            }
            return super.onKeyDown(keyCode, event)
        }
        if (shiftKeysym != 0) otherKeyDuringShift = true
        val mask = RimeKey.modifierMask(event.metaState)
        if ((keysym == RimeKey.RETURN || keysym == RimeKey.KEYPAD_ENTER) && mask and RimeKey.COMMAND_MODIFIERS == 0 && controller.bufferOwnsReturn()) {
            if (event.repeatCount == 0) beginReturnGesture()
            consumedKeyDowns += keyCode
            return true
        }
        val handled = controller.handleKey(keysym, mask, isRepeat = event.repeatCount > 0)
        if (handled) consumedKeyDowns += keyCode else consumedKeyDowns -= keyCode
        return handled || super.onKeyDown(keyCode, event)
    }

    private val consumedKeyDowns = mutableSetOf<Int>()

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        if (currentToken == null) return super.onKeyUp(keyCode, event)
        val keysym = RimeKey.fromKeyEvent(event)
        if (keysym == RimeKey.SHIFT_L || keysym == RimeKey.SHIFT_R) {
            val held = System.currentTimeMillis() - shiftDownAt
            val standalone = !otherKeyDuringShift && held in 0..STANDALONE_SHIFT_MS && shiftKeysym == keysym &&
                event.metaState and (KeyEvent.META_CTRL_MASK or KeyEvent.META_ALT_MASK or KeyEvent.META_META_MASK) == 0
            shiftKeysym = 0
            if (standalone && app.prefs.getBoolean(RimesPreferences.HARDWARE_SHIFT_TOGGLES_ASCII, true)) {
                controller.handleStandaloneModifierTap(keysym)
                return true
            }
            return super.onKeyUp(keyCode, event)
        }
        if ((keysym == RimeKey.RETURN || keysym == RimeKey.KEYPAD_ENTER) && returnDownAt != 0L) {
            consumedKeyDowns -= keyCode
            endReturnGesture()
            return true
        }
        return if (consumedKeyDowns.remove(keyCode)) true else super.onKeyUp(keyCode, event)
    }

    // MARK: Soft keys (same routing path)

    private fun onSoftKeyDown(keysym: Int, mask: Int) {
        if (currentToken == null) return
        refreshHost()
        if (keysym == RimeKey.RETURN && controller.bufferOwnsReturn()) {
            beginReturnGesture()
            return
        }
        controller.handleKey(keysym, mask)
    }

    private fun onSoftKeyUp(keysym: Int) {
        if (keysym == RimeKey.RETURN && returnDownAt != 0L) endReturnGesture()
    }

    // MARK: Return tap/hold state machine (buffer delivery)

    private fun beginReturnGesture() {
        returnDownAt = System.currentTimeMillis()
        returnHoldFired = false
        returnSettledComposition = false
        if (controller.hasPendingComposition()) {
            // Settle only; this press must not also send.
            controller.handleKey(RimeKey.RETURN, 0)
            returnSettledComposition = true
            return
        }
        mainHandler.postDelayed(returnHoldRunnable, RETURN_HOLD_MS)
    }

    private fun endReturnGesture() {
        mainHandler.removeCallbacks(returnHoldRunnable)
        val settled = returnSettledComposition
        val holdFired = returnHoldFired
        returnDownAt = 0L
        returnSettledComposition = false
        returnHoldFired = false
        if (settled || holdFired) return
        controller.performBufferSend(all = false)
    }

    private fun cancelReturnGesture() {
        mainHandler.removeCallbacks(returnHoldRunnable)
        returnDownAt = 0L
        returnHoldFired = false
        returnSettledComposition = false
    }

    // MARK: Rendering

    override fun uiStateDidChange(state: InputUiState) {
        lastState = state
        render(state)
    }

    private fun render(state: InputUiState) {
        val rail = bufferRail ?: return
        val bar = candidateBar ?: return
        val strip = toolbar ?: return
        val keys = keyboard ?: return

        val showRail = state.bufferEnabled || state.bufferBlocks.isNotEmpty()
        rail.visibility = if (showRail && !state.secureInput) View.VISIBLE else View.GONE
        rail.render(
            blocks = state.bufferBlocks,
            insertionIndex = state.bufferInsertionIndex,
            captures = state.bufferCaptures,
            preedit = if (state.bufferCaptures) state.context.preedit else "",
            chordPending = state.bufferCaptures && state.chordPending,
        )

        val showCandidates = state.context.active && state.context.candidates.isNotEmpty()
        bar.visibility = if (showCandidates) View.VISIBLE else View.GONE
        bar.render(state.context, showPreeditInBar = !state.bufferCaptures)
        if (expandedVisible && !showCandidates) setExpanded(false)

        strip.visibility = if (showCandidates) View.GONE else View.VISIBLE
        val schemaName = InputSchemaCatalog.option(state.status.schemaId)?.name ?: state.status.schemaName
        val (status, warning) = when {
            state.secureInput -> "密码框：直接输入，不经 Rime/缓冲" to true
            state.engineState == EngineState.STARTING -> state.engineMessage.ifEmpty { "正在启动…" } to false
            state.engineState == EngineState.FAILED -> state.engineMessage to true
            state.chordPending -> "并击待结算" to false
            state.bufferCaptures -> "缓冲中 · 回车投递 / 长按全部" to false
            else -> "" to false
        }
        strip.render(schemaName, state.status.asciiMode, state.bufferEnabled, state.bufferCaptures, status, warning)
        keys.asciiMode = state.status.asciiMode
        keys.schemaLabel = if (state.status.asciiMode) "English" else schemaName
    }

    // MARK: Settings & schema picker

    private fun openSettings() {
        val intent = Intent(this, SettingsActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    private fun showSchemaPicker() {
        val token = window?.window?.decorView?.windowToken ?: return
        SchemaPickerDialog.show(this, token, app) { schemaId -> controller.selectSchema(schemaId) }
    }

    // MARK: Observers

    override fun rimeUserDictionaryMaintenanceWillBegin() {
        controller.prepareForUserDictionaryMaintenance()
    }

    override fun rimeUserDictionaryMaintenanceDidEnd(succeeded: Boolean) {
        controller.finishUserDictionaryMaintenance()
    }

    override fun onSharedPreferenceChanged(prefs: SharedPreferences?, key: String?) {
        when (key) {
            RimesPreferences.BUFFER_ENABLED -> controller.setBufferEnabled(app.prefs.getBoolean(key, false))
            RimesPreferences.BUFFER_CLOSE_AFTER_LAST -> controller.closeBufferAfterLastDelivery = app.prefs.getBoolean(key, true)
            RimesAppearance.PREF_KEY -> {
                applyPalette()
                render(lastState)
            }
        }
    }

    override fun inputConfigurationDidChange(store: InputConfigurationStore) {
        mainHandler.post { controller.applyStoredInputConfiguration() }
    }

    override fun chordExtensionDidChange(previous: ChordExtensionConfiguration, current: ChordExtensionConfiguration, source: String) {
        if (previous.isEnabled != current.isEnabled) {
            // my_combo enters/leaves the switcher list: rewrite default.custom.yaml and redeploy.
            controller.setEngineState(EngineState.STARTING, "正在更新方案列表…")
            app.engineExecutor.execute {
                val changed = runCatching { app.syncSchemaListWithExtension() }.getOrDefault(false)
                if (changed && app.engine.started) app.engine.deploy()
                mainHandler.post {
                    controller.setEngineState(EngineState.READY)
                    controller.applyStoredInputConfiguration()
                }
            }
        } else {
            mainHandler.post { controller.applyStoredInputConfiguration() }
        }
    }

    private class HandlerScheduler(private val handler: Handler) : ChordController.Scheduler {
        override fun schedule(delayMillis: Long, action: () -> Unit): Any {
            val runnable = Runnable { action() }
            handler.postDelayed(runnable, delayMillis)
            return runnable
        }

        override fun cancel(token: Any) {
            (token as? Runnable)?.let { handler.removeCallbacks(it) }
        }
    }

    companion object {
        const val RETURN_HOLD_MS = 1200L
        const val STANDALONE_SHIFT_MS = 500L
        const val EXPANDED_PAGES = 5
    }
}
