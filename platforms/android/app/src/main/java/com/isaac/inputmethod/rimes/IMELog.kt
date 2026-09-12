package com.isaac.inputmethod.rimes

import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Behaviour log, privacy-preserving by construction. Mirrors `Log.swift`:
 * user text never enters the log verbatim; callers pass [redact]ed values so a
 * log line records lengths and shapes, not content.
 */
object IMELog {
    private const val TAG = "RIMES"
    private const val MAX_BYTES = 2L * 1024 * 1024

    @Volatile
    private var file: File? = null
    private val stamp = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)

    fun attach(logDir: File) {
        logDir.mkdirs()
        file = File(logDir, "rimes.log")
    }

    fun write(message: String) {
        Log.i(TAG, message)
        val target = file ?: return
        synchronized(this) {
            try {
                if (target.exists() && target.length() > MAX_BYTES) {
                    val rotated = File(target.parentFile, "rimes.log.1")
                    rotated.delete()
                    target.renameTo(rotated)
                }
                target.appendText("${stamp.format(Date())} $message\n")
            } catch (_: Exception) {
                // Logging must never disturb typing.
            }
        }
    }

    /** Replace user text by a shape descriptor: character count and script class. */
    fun redact(text: String): String {
        if (text.isEmpty()) return "<empty>"
        val cjk = text.count { Character.UnicodeScript.of(it.code) == Character.UnicodeScript.HAN }
        val ascii = text.count { it.code in 0x20..0x7e }
        return "<len=${text.length} han=$cjk ascii=$ascii>"
    }

    fun logFile(): File? = file
}
