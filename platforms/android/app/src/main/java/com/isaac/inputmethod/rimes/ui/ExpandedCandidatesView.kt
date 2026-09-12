package com.isaac.inputmethod.rimes.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View
import com.isaac.inputmethod.rimes.rime.RimeContextModel

/**
 * The expanded candidate matrix: several Rime pages laid out as rows, the
 * Android counterpart of the macOS Down-arrow expansion. Replaces the keyboard
 * area while visible; a tap selects `(pageDelta, indexOnPage)`.
 */
class ExpandedCandidatesView(context: Context) : View(context) {
    interface Listener {
        fun onSelect(pageDelta: Int, indexOnPage: Int)
        fun onCollapse()
    }

    var listener: Listener? = null
    var palette: RimesPalette = RimesPalettes.night
        set(value) {
            field = value
            invalidate()
        }

    private var pages: List<RimeContextModel> = emptyList()
    private val cells = mutableListOf<Triple<RectF, Int, Int>>()
    private val collapseRect = RectF()
    private val density = resources.displayMetrics.density
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private var preferredHeight = 0

    fun render(pages: List<RimeContextModel>, heightPx: Int) {
        this.pages = pages
        preferredHeight = heightPx
        requestLayout()
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), preferredHeight)
    }

    override fun onDraw(canvas: Canvas) {
        canvas.drawColor(palette.surface)
        cells.clear()
        textPaint.textSize = 17f * density
        labelPaint.textSize = 10f * density
        val rowHeight = 44f * density
        val topBar = 30f * density
        collapseRect.set(0f, 0f, width.toFloat(), topBar)
        labelPaint.color = palette.textSecondary
        canvas.drawText("候选矩阵 · 点击收起", 12f * density, 20f * density, labelPaint)

        var y = topBar
        for ((pageDelta, page) in pages.withIndex()) {
            var x = 8f * density
            for ((index, candidate) in page.candidates.withIndex()) {
                val w = textPaint.measureText(candidate.text) + labelPaint.measureText(candidate.label) + 24f * density
                if (x + w > width - 8f * density) break
                val rect = RectF(x, y + 4f * density, x + w, y + rowHeight - 4f * density)
                val highlighted = pageDelta == 0 && index == page.highlightedIndex
                fillPaint.color = if (highlighted) palette.selectedCandidateBackground else palette.surfaceTertiary
                canvas.drawRoundRect(rect, 8f * density, 8f * density, fillPaint)
                val baseline = rect.centerY() - (textPaint.descent() + textPaint.ascent()) / 2
                labelPaint.color = if (highlighted) palette.selectedCandidateText else palette.textMuted
                canvas.drawText(candidate.label, rect.left + 8f * density, baseline, labelPaint)
                textPaint.color = if (highlighted) palette.selectedCandidateText else palette.textPrimary
                canvas.drawText(candidate.text, rect.left + 8f * density + labelPaint.measureText(candidate.label) + 4f * density, baseline, textPaint)
                cells += Triple(rect, pageDelta, index)
                x += w + 6f * density
            }
            y += rowHeight
            if (y + rowHeight > height) break
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked != MotionEvent.ACTION_UP) return true
        if (collapseRect.contains(event.x, event.y)) {
            listener?.onCollapse()
            return true
        }
        cells.firstOrNull { it.first.contains(event.x, event.y) }?.let { (_, pageDelta, index) ->
            listener?.onSelect(pageDelta, index)
        }
        return true
    }
}
