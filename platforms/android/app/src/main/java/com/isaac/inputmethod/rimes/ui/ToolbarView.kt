package com.isaac.inputmethod.rimes.ui

import android.content.Context
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.TextView

/**
 * The status strip shown while Rime is idle (the Android home of the macOS
 * status menu): schema name (tap cycles, long-press opens the picker),
 * 中/英 state, chord badge, buffer toggle, and settings.
 */
class ToolbarView(context: Context) : LinearLayout(context) {
    interface Listener {
        fun onSchemaTap()
        fun onSchemaLongPress()
        fun onToggleBuffer()
        fun onOpenSettings()
        fun onToggleAscii()
    }

    var listener: Listener? = null
    var palette: RimesPalette = RimesPalettes.night
        set(value) {
            field = value
            applyPalette()
        }

    private val density = resources.displayMetrics.density
    private val schemaButton = TextView(context)
    private val asciiButton = TextView(context)
    private val statusLabel = TextView(context)
    private val bufferButton = TextView(context)
    private val settingsButton = TextView(context)

    init {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = (48 * density).toInt()
        val pad = (10 * density).toInt()
        for (view in listOf(schemaButton, asciiButton, statusLabel, bufferButton, settingsButton)) {
            view.gravity = Gravity.CENTER
            view.setPadding(pad, 0, pad, 0)
            view.maxLines = 1
        }
        schemaButton.textSize = 14f
        asciiButton.textSize = 14f
        statusLabel.textSize = 11f
        bufferButton.textSize = 15f
        settingsButton.textSize = 18f
        settingsButton.text = "⚙"
        settingsButton.contentDescription = "设置"
        bufferButton.contentDescription = "Buffer 工作台"

        addView(schemaButton, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT))
        addView(asciiButton, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT))
        addView(statusLabel, LayoutParams(0, LayoutParams.MATCH_PARENT, 1f))
        addView(bufferButton, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT))
        addView(settingsButton, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT))

        schemaButton.setOnClickListener { listener?.onSchemaTap() }
        schemaButton.setOnLongClickListener { listener?.onSchemaLongPress(); true }
        asciiButton.setOnClickListener { listener?.onToggleAscii() }
        bufferButton.setOnClickListener { listener?.onToggleBuffer() }
        settingsButton.setOnClickListener { listener?.onOpenSettings() }
        applyPalette()
    }

    private fun applyPalette() {
        setBackgroundColor(palette.surfaceSecondary)
        schemaButton.setTextColor(palette.textPrimary)
        asciiButton.setTextColor(palette.textPrimary)
        statusLabel.setTextColor(palette.textMuted)
        bufferButton.setTextColor(palette.textSecondary)
        settingsButton.setTextColor(palette.textSecondary)
    }

    fun render(schemaName: String, asciiMode: Boolean, bufferEnabled: Boolean, captures: Boolean, status: String, statusIsWarning: Boolean) {
        schemaButton.text = schemaName.ifEmpty { "RIMES" }
        asciiButton.text = if (asciiMode) "英" else "中"
        bufferButton.text = if (captures) "▣" else if (bufferEnabled) "▢" else "▢"
        bufferButton.setTextColor(if (captures) palette.accentGreen else if (bufferEnabled) palette.textPrimary else palette.textMuted)
        statusLabel.text = status
        statusLabel.setTextColor(if (statusIsWarning) palette.warningText else palette.textMuted)
    }
}
