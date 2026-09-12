package com.isaac.inputmethod.rimes.ui

import android.content.Context
import android.graphics.Typeface
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView
import com.isaac.inputmethod.rimes.buffer.BufferModel

/**
 * The Buffer workbench rail: pending blocks as passive chips in model order,
 * the insertion caret, the projected Rime preedit while the buffer captures
 * the field, and the single paper-plane primary action (tap = send next,
 * hold = send all). Blocks are never edited in place; there is no history.
 */
class BufferRailView(context: Context) : LinearLayout(context) {
    interface Listener {
        fun onSendNext()
        fun onSendAll()
        fun onToggleCapture()
        fun onSetInsertionPoint(index: Int)
        fun onClose()
    }

    var listener: Listener? = null
    var palette: RimesPalette = RimesPalettes.night
        set(value) {
            field = value
            applyPalette()
        }

    private val density = resources.displayMetrics.density
    private val statusLabel = TextView(context)
    private val chipsRow = LinearLayout(context).apply { orientation = HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
    private val scroller = HorizontalScrollView(context).apply {
        isHorizontalScrollBarEnabled = false
        addView(chipsRow, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT))
    }
    private val captureButton = TextView(context)
    private val sendButton = TextView(context)
    private val closeButton = TextView(context)
    private val placeholder = TextView(context)

    init {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        val pad = (6 * density).toInt()
        setPadding(pad, pad, pad, pad)
        minimumHeight = (44 * density).toInt()

        statusLabel.textSize = 11f
        statusLabel.setPadding(pad, 0, pad, 0)
        statusLabel.text = "Buffer"
        addView(statusLabel, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))

        placeholder.textSize = 12f
        placeholder.text = "先暂存，再分块投递"
        chipsRow.addView(placeholder)
        addView(scroller, LayoutParams(0, LayoutParams.MATCH_PARENT, 1f))

        for (button in listOf(captureButton, sendButton, closeButton)) {
            button.textSize = 16f
            button.gravity = Gravity.CENTER
            button.setPadding(pad * 2, pad, pad * 2, pad)
            button.minWidth = (40 * density).toInt()
            addView(button, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT))
        }
        captureButton.text = "⤓"
        captureButton.contentDescription = "切换缓冲/直输"
        captureButton.setOnClickListener { listener?.onToggleCapture() }
        sendButton.text = "➤"
        sendButton.contentDescription = "投递下一块（长按全部）"
        sendButton.setOnClickListener { listener?.onSendNext() }
        sendButton.setOnLongClickListener { listener?.onSendAll(); true }
        closeButton.text = "✕"
        closeButton.contentDescription = "关闭工作台"
        closeButton.setOnClickListener { listener?.onClose() }
        applyPalette()
    }

    private fun applyPalette() {
        setBackgroundColor(palette.bufferBackground)
        statusLabel.setTextColor(palette.bufferMuted)
        placeholder.setTextColor(palette.bufferMuted)
        captureButton.setTextColor(palette.textPrimary)
        sendButton.setTextColor(palette.accentGreen)
        closeButton.setTextColor(palette.textSecondary)
    }

    fun render(blocks: List<BufferModel.Block>, insertionIndex: Int, captures: Boolean, preedit: String, chordPending: Boolean) {
        chipsRow.removeAllViews()
        statusLabel.text = if (captures) "缓冲" else "直输"
        captureButton.text = if (captures) "⤓" else "⤒"
        captureButton.setTextColor(if (captures) palette.accentGreen else palette.textSecondary)
        sendButton.alpha = if (blocks.isEmpty()) 0.4f else 1f
        if (blocks.isEmpty() && preedit.isEmpty() && !chordPending) {
            placeholder.text = if (captures) "输入将先进入缓冲" else "先暂存，再分块投递"
            chipsRow.addView(placeholder)
            return
        }
        for ((index, block) in blocks.withIndex()) {
            if (index == insertionIndex && (preedit.isNotEmpty() || chordPending)) {
                chipsRow.addView(preeditChip(preedit, chordPending))
            }
            chipsRow.addView(caret(index == insertionIndex))
            chipsRow.addView(chip(block, index))
        }
        if (insertionIndex >= blocks.size && (preedit.isNotEmpty() || chordPending)) {
            chipsRow.addView(preeditChip(preedit, chordPending))
        }
        chipsRow.addView(caret(insertionIndex >= blocks.size))
        post { scroller.fullScroll(View.FOCUS_RIGHT) }
    }

    private fun chip(block: BufferModel.Block, index: Int): View {
        val view = TextView(context)
        view.text = block.origin.badge?.let { "$it · ${block.text}" } ?: block.text
        view.maxLines = 1
        view.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        view.setTextColor(palette.textPrimary)
        view.setBackgroundColor(palette.bufferChip)
        val h = (6 * density).toInt()
        view.setPadding(h, (2 * density).toInt(), h, (2 * density).toInt())
        view.setOnClickListener { listener?.onSetInsertionPoint(index + 1) }
        val params = LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT)
        params.marginEnd = (3 * density).toInt()
        view.layoutParams = params
        return view
    }

    private fun preeditChip(preedit: String, chordPending: Boolean): View {
        val view = TextView(context)
        view.text = if (preedit.isEmpty()) "…" else preedit
        view.setTypeface(null, Typeface.ITALIC)
        view.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        view.setTextColor(palette.textPrimary)
        view.setBackgroundColor(palette.bufferPreedit)
        val h = (6 * density).toInt()
        view.setPadding(h, (2 * density).toInt(), h, (2 * density).toInt())
        view.alpha = if (chordPending && preedit.isEmpty()) 0.6f else 1f
        val params = LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT)
        params.marginEnd = (3 * density).toInt()
        view.layoutParams = params
        return view
    }

    private fun caret(active: Boolean): View {
        val view = View(context)
        view.setBackgroundColor(if (active) palette.accentGreen else 0)
        view.layoutParams = LayoutParams((2 * density).toInt(), (20 * density).toInt()).apply {
            marginEnd = (3 * density).toInt()
        }
        return view
    }
}
