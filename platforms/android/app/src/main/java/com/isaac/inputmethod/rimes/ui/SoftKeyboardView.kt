package com.isaac.inputmethod.rimes.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.View
import com.isaac.inputmethod.rimes.rime.RimeKey

/**
 * Canvas-drawn QWERTY keyboard. Every letter/punctuation key emits the same
 * X11 keysym + Rime mask that a hardware key produces, so the controller has
 * exactly one routing path. Multi-touch is supported: each pointer down is a
 * press, which is what FlyYao chords need on a touchscreen.
 */
class SoftKeyboardView(context: Context) : View(context) {
    interface Listener {
        fun onKeyPress(keysym: Int, mask: Int)
        fun onKeyRelease(keysym: Int, mask: Int, heldMillis: Long)
        fun onShiftTap()
        fun onToggleAscii()
        fun onHideKeyboard()
    }

    enum class Layer { LETTERS, SYMBOLS }

    /** Special key roles rendered by the keyboard itself. */
    private enum class Role { CHAR, SHIFT, BACKSPACE, LAYER, ASCII, SPACE, RETURN, HIDE }

    private data class Key(
        val role: Role,
        val label: String,
        val keysym: Int = 0,
        val shiftedKeysym: Int = 0,
        val widthUnits: Float = 1f,
        val rect: RectF = RectF(),
    )

    var listener: Listener? = null
    var palette: RimesPalette = RimesPalettes.night
        set(value) {
            field = value
            invalidate()
        }
    var asciiMode: Boolean = false
        set(value) {
            field = value
            invalidate()
        }
    var schemaLabel: String = ""
        set(value) {
            field = value
            invalidate()
        }

    private var layer = Layer.LETTERS
    private var shifted = false
    private val rows: List<List<Key>> get() = if (layer == Layer.LETTERS) letterRows else symbolRows
    private val activePointers = mutableMapOf<Int, Pair<Key, Long>>()
    private val handler = Handler(Looper.getMainLooper())
    private var repeatRunnable: Runnable? = null

    private val keyPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }
    private val hintPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }

    private val letterRows: List<List<Key>> = listOf(
        "qwertyuiop".map { letterKey(it) },
        "asdfghjkl".map { letterKey(it) },
        listOf(Key(Role.SHIFT, "⇧", widthUnits = 1.5f)) + "zxcvbnm".map { letterKey(it) } + Key(Role.BACKSPACE, "⌫", widthUnits = 1.5f),
        listOf(
            Key(Role.LAYER, "123", widthUnits = 1.3f),
            Key(Role.CHAR, ",", ','.code, ','.code),
            Key(Role.ASCII, "中", widthUnits = 1.2f),
            Key(Role.SPACE, "", RimeKey.SPACE, RimeKey.SPACE, widthUnits = 3.5f),
            Key(Role.CHAR, ".", '.'.code, '.'.code),
            Key(Role.HIDE, "⌄", widthUnits = 1f),
            Key(Role.RETURN, "↵", RimeKey.RETURN, RimeKey.RETURN, widthUnits = 1.5f),
        ),
    )

    private val symbolRows: List<List<Key>> = listOf(
        "1234567890".map { Key(Role.CHAR, it.toString(), it.code, it.code) },
        "-/:;()$&@\"".map { Key(Role.CHAR, it.toString(), it.code, it.code) },
        listOf(Key(Role.SHIFT, "#+=", widthUnits = 1.5f)) + "?!'[]{}".map { Key(Role.CHAR, it.toString(), it.code, it.code) } + Key(Role.BACKSPACE, "⌫", widthUnits = 1.5f),
        listOf(
            Key(Role.LAYER, "abc", widthUnits = 1.3f),
            Key(Role.CHAR, "%", '%'.code, '%'.code),
            Key(Role.ASCII, "中", widthUnits = 1.2f),
            Key(Role.SPACE, "", RimeKey.SPACE, RimeKey.SPACE, widthUnits = 3.5f),
            Key(Role.CHAR, "=", '='.code, '='.code),
            Key(Role.HIDE, "⌄", widthUnits = 1f),
            Key(Role.RETURN, "↵", RimeKey.RETURN, RimeKey.RETURN, widthUnits = 1.5f),
        ),
    )

    private fun letterKey(char: Char) = Key(Role.CHAR, char.toString(), char.code, char.uppercaseChar().code)

    private val density = resources.displayMetrics.density
    private val rowHeightPx = 52f * density
    private val gapPx = 3f * density

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val height = (rowHeightPx * 4 + gapPx * 2).toInt()
        setMeasuredDimension(width, height)
        layoutKeys(width)
    }

    private fun layoutKeys(width: Int) {
        val horizontalInset = 4f * density
        for ((rowIndex, row) in rows.withIndex()) {
            val units = row.sumOf { it.widthUnits.toDouble() }.toFloat()
            val unitWidth = (width - horizontalInset * 2 - gapPx * (row.size - 1)) / units
            var x = horizontalInset
            val top = gapPx + rowIndex * rowHeightPx
            for (key in row) {
                val keyWidth = unitWidth * key.widthUnits
                key.rect.set(x, top + gapPx, x + keyWidth, top + rowHeightPx - gapPx)
                x += keyWidth + gapPx
            }
        }
    }

    override fun onDraw(canvas: Canvas) {
        canvas.drawColor(palette.surface)
        textPaint.textSize = 20f * density
        hintPaint.textSize = 10f * density
        hintPaint.color = palette.textMuted
        for (row in rows) {
            for (key in row) {
                val pressed = activePointers.values.any { it.first === key }
                keyPaint.color = when {
                    pressed -> palette.selectedCandidateBackground
                    key.role == Role.CHAR || key.role == Role.SPACE -> palette.surfaceTertiary
                    key.role == Role.RETURN -> palette.accentGreen
                    key.role == Role.ASCII && !asciiMode -> palette.bufferChipSelected
                    else -> palette.surfaceSecondary
                }
                canvas.drawRoundRect(key.rect, 6f * density, 6f * density, keyPaint)
                textPaint.color = when {
                    pressed -> palette.selectedCandidateText
                    key.role == Role.RETURN -> palette.accentForeground
                    else -> palette.textPrimary
                }
                val label = when (key.role) {
                    Role.CHAR -> if (shifted && layer == Layer.LETTERS) key.label.uppercase() else key.label
                    Role.ASCII -> if (asciiMode) "英" else "中"
                    Role.SPACE -> schemaLabel
                    else -> key.label
                }
                val paint = if (key.role == Role.SPACE) hintPaint.apply { color = palette.textSecondary } else textPaint
                val baseline = key.rect.centerY() - (paint.descent() + paint.ascent()) / 2
                canvas.drawText(label, key.rect.centerX(), baseline, paint)
            }
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val actionIndex = event.actionIndex
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                val key = keyAt(event.getX(actionIndex), event.getY(actionIndex)) ?: return true
                activePointers[event.getPointerId(actionIndex)] = key to System.currentTimeMillis()
                onPress(key)
                invalidate()
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                val pointerId = event.getPointerId(actionIndex)
                val (key, pressedAt) = activePointers.remove(pointerId) ?: return true
                onRelease(key, System.currentTimeMillis() - pressedAt)
                invalidate()
            }
            MotionEvent.ACTION_CANCEL -> {
                stopRepeat()
                activePointers.clear()
                invalidate()
            }
        }
        return true
    }

    private fun keyAt(x: Float, y: Float): Key? = rows.flatten().firstOrNull { it.rect.contains(x, y) }

    private fun currentKeysym(key: Key): Pair<Int, Int> {
        val useShift = shifted && layer == Layer.LETTERS && key.role == Role.CHAR
        return if (useShift) key.shiftedKeysym to RimeKey.SHIFT_MASK else key.keysym to 0
    }

    private fun onPress(key: Key) {
        when (key.role) {
            Role.CHAR, Role.SPACE, Role.RETURN -> {
                val (keysym, mask) = currentKeysym(key)
                listener?.onKeyPress(keysym, mask)
                if (shifted && key.role == Role.CHAR) {
                    shifted = false
                }
            }
            Role.BACKSPACE -> {
                listener?.onKeyPress(RimeKey.BACKSPACE, 0)
                startRepeat { listener?.onKeyPress(RimeKey.BACKSPACE, 0) }
            }
            Role.SHIFT -> {
                if (layer == Layer.LETTERS) {
                    shifted = !shifted
                    listener?.onShiftTap()
                } else {
                    shifted = !shifted
                }
            }
            Role.LAYER -> {
                layer = if (layer == Layer.LETTERS) Layer.SYMBOLS else Layer.LETTERS
                shifted = false
                requestLayout()
            }
            Role.ASCII -> listener?.onToggleAscii()
            Role.HIDE -> listener?.onHideKeyboard()
        }
    }

    private fun onRelease(key: Key, heldMillis: Long) {
        when (key.role) {
            Role.CHAR, Role.SPACE, Role.RETURN -> {
                val (keysym, mask) = currentKeysym(key)
                listener?.onKeyRelease(keysym, mask, heldMillis)
            }
            Role.BACKSPACE -> {
                stopRepeat()
                listener?.onKeyRelease(RimeKey.BACKSPACE, 0, heldMillis)
            }
            else -> Unit
        }
    }

    private fun startRepeat(action: () -> Unit) {
        stopRepeat()
        val runnable = object : Runnable {
            override fun run() {
                action()
                handler.postDelayed(this, 50)
            }
        }
        repeatRunnable = runnable
        handler.postDelayed(runnable, 400)
    }

    private fun stopRepeat() {
        repeatRunnable?.let { handler.removeCallbacks(it) }
        repeatRunnable = null
    }

    override fun onDetachedFromWindow() {
        stopRepeat()
        super.onDetachedFromWindow()
    }
}
