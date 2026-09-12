package com.isaac.inputmethod.rimes.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.View
import com.isaac.inputmethod.rimes.rime.RimeContextModel

/**
 * One regular candidate surface: the current Rime page with labels, comments
 * and the highlighted item, scrollable horizontally, plus paging arrows and an
 * expand toggle. Tapping a candidate is a token-owned selection routed back to
 * the controller (never a second selection authority).
 */
class CandidateBarView(context: Context) : View(context) {
    interface Listener {
        fun onCandidateTap(indexOnPage: Int)
        fun onPage(delta: Int)
        fun onToggleExpanded()
    }

    var listener: Listener? = null
    var palette: RimesPalette = RimesPalettes.night
        set(value) {
            field = value
            invalidate()
        }

    private var context_: RimeContextModel = RimeContextModel.EMPTY
    private var showPreedit = false
    private var scrollX_ = 0f
    private val itemRects = mutableListOf<RectF>()
    private val pagePrevRect = RectF()
    private val pageNextRect = RectF()
    private val expandRect = RectF()

    private val density = resources.displayMetrics.density
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val commentPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val arrowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }

    private val gestures = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent): Boolean = true

        override fun onScroll(e1: MotionEvent?, e2: MotionEvent, distanceX: Float, distanceY: Float): Boolean {
            scrollX_ = (scrollX_ + distanceX).coerceIn(0f, maxScroll())
            invalidate()
            return true
        }

        override fun onSingleTapUp(e: MotionEvent): Boolean {
            if (pagePrevRect.contains(e.x, e.y)) {
                listener?.onPage(-1)
                return true
            }
            if (pageNextRect.contains(e.x, e.y)) {
                listener?.onPage(1)
                return true
            }
            if (expandRect.contains(e.x, e.y)) {
                listener?.onToggleExpanded()
                return true
            }
            val x = e.x + scrollX_
            val index = itemRects.indexOfFirst { it.contains(x, e.y) }
            if (index >= 0) listener?.onCandidateTap(index)
            return true
        }
    })

    fun render(context: RimeContextModel, showPreeditInBar: Boolean) {
        val pageChanged = context.pageNo != context_.pageNo || context.input != context_.input
        context_ = context
        showPreedit = showPreeditInBar
        if (pageChanged) scrollX_ = 0f
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val height = (if (showPreedit) 68f else 48f) * density
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), height.toInt())
    }

    private fun maxScroll(): Float {
        val last = itemRects.lastOrNull() ?: return 0f
        val visible = pagePrevRect.left - 8f * density
        return (last.right - visible).coerceAtLeast(0f)
    }

    override fun onDraw(canvas: Canvas) {
        canvas.drawColor(palette.candidateBackground)
        val ctx = context_
        val rowTop = if (showPreedit) 20f * density else 0f
        val rowHeight = height - rowTop

        if (showPreedit && ctx.preedit.isNotEmpty()) {
            textPaint.textSize = 13f * density
            textPaint.color = palette.textSecondary
            canvas.drawText(ctx.preedit, 12f * density, 15f * density, textPaint)
        }

        // Right-side controls: prev, next, expand.
        val controlWidth = 36f * density
        expandRect.set(width - controlWidth, rowTop, width.toFloat(), height.toFloat())
        pageNextRect.set(expandRect.left - controlWidth, rowTop, expandRect.left, height.toFloat())
        pagePrevRect.set(pageNextRect.left - controlWidth, rowTop, pageNextRect.left, height.toFloat())
        arrowPaint.textSize = 16f * density
        val hasCandidates = ctx.candidates.isNotEmpty()
        arrowPaint.color = if (hasCandidates && ctx.pageNo > 0) palette.textPrimary else palette.textMuted
        drawCentered(canvas, "‹", pagePrevRect)
        arrowPaint.color = if (hasCandidates && !ctx.isLastPage) palette.textPrimary else palette.textMuted
        drawCentered(canvas, "›", pageNextRect)
        arrowPaint.color = if (hasCandidates) palette.textPrimary else palette.textMuted
        drawCentered(canvas, "⌵", expandRect)

        itemRects.clear()
        if (!hasCandidates) return

        textPaint.textSize = 18f * density
        labelPaint.textSize = 11f * density
        commentPaint.textSize = 11f * density
        val clipRight = pagePrevRect.left - 4f * density
        canvas.save()
        canvas.clipRect(0f, rowTop, clipRight, height.toFloat())
        var x = 8f * density - scrollX_
        val padding = 10f * density
        for ((index, candidate) in ctx.candidates.withIndex()) {
            val labelWidth = labelPaint.measureText(candidate.label)
            val textWidth = textPaint.measureText(candidate.text)
            val commentWidth = if (candidate.comment.isEmpty()) 0f else commentPaint.measureText(candidate.comment) + 4f * density
            val itemWidth = padding + labelWidth + 4f * density + textWidth + commentWidth + padding
            val rect = RectF(x, rowTop + 6f * density, x + itemWidth, height - 6f * density)
            itemRects += RectF(rect).apply { offset(scrollX_, 0f) }
            val highlighted = index == ctx.highlightedIndex
            if (highlighted) {
                fillPaint.color = palette.selectedCandidateBackground
                canvas.drawRoundRect(rect, 8f * density, 8f * density, fillPaint)
            }
            val baseline = rect.centerY() - (textPaint.descent() + textPaint.ascent()) / 2
            labelPaint.color = if (highlighted) palette.selectedCandidateText else palette.textMuted
            canvas.drawText(candidate.label, x + padding, baseline, labelPaint)
            textPaint.color = if (highlighted) palette.selectedCandidateText else palette.textPrimary
            canvas.drawText(candidate.text, x + padding + labelWidth + 4f * density, baseline, textPaint)
            if (candidate.comment.isNotEmpty()) {
                commentPaint.color = if (highlighted) palette.selectedCandidateText else palette.textSecondary
                canvas.drawText(candidate.comment, x + padding + labelWidth + 8f * density + textWidth, baseline, commentPaint)
            }
            x += itemWidth + 2f * density
        }
        canvas.restore()
    }

    private fun drawCentered(canvas: Canvas, text: String, rect: RectF) {
        val baseline = rect.centerY() - (arrowPaint.descent() + arrowPaint.ascent()) / 2
        canvas.drawText(text, rect.centerX(), baseline, arrowPaint)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        gestures.onTouchEvent(event)
        return true
    }
}
