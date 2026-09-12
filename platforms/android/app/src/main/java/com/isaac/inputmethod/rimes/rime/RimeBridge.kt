package com.isaac.inputmethod.rimes.rime

/**
 * Raw JNI surface over the shared `CRimeBridge` C API (`Sources/CRimeBridge`).
 *
 * Every function maps 1:1 onto a `BBRime*` call; see `rime_jni.cpp`. Callers
 * should use [RimeEngine], which adds directory handling, logging and the
 * user-dictionary maintenance notifications, rather than this object.
 */
object RimeBridge {
    @Volatile
    private var loaded = false

    /** Loads `librimes_jni.so`. Safe to call repeatedly; returns false on failure. */
    fun ensureLoaded(): Boolean {
        if (loaded) return true
        synchronized(this) {
            if (loaded) return true
            return try {
                System.loadLibrary("rimes_jni")
                loaded = true
                true
            } catch (error: UnsatisfiedLinkError) {
                false
            }
        }
    }

    @JvmStatic external fun start(sharedDataDir: String, userDataDir: String, logDir: String): Boolean
    @JvmStatic external fun isHealthy(): Boolean
    @JvmStatic external fun hasOctagram(): Boolean

    @JvmStatic external fun createSession(): Long
    @JvmStatic external fun destroySession(session: Long)
    @JvmStatic external fun sessionExists(session: Long): Boolean

    @JvmStatic external fun processKey(session: Long, keycode: Int, mask: Int): Boolean
    @JvmStatic external fun commitComposition(session: Long): Boolean
    @JvmStatic external fun clearComposition(session: Long)
    @JvmStatic external fun selectCandidateOnCurrentPage(session: Long, index: Int): Boolean

    @JvmStatic external fun getOption(session: Long, option: String): Boolean
    @JvmStatic external fun setOption(session: Long, option: String, value: Boolean)
    @JvmStatic external fun selectSchema(session: Long, schemaId: String): Boolean
    @JvmStatic external fun deploy(): Boolean
    @JvmStatic external fun configDouble(configId: String, key: String): Double

    @JvmStatic external fun schemaList(): Array<RimeSchemaItem>?
    @JvmStatic external fun getContext(session: Long): RimeContextModel?
    @JvmStatic external fun getStatus(session: Long): RimeStatusModel?
    @JvmStatic external fun takeCommit(session: Long): String?
    @JvmStatic external fun currentSchema(session: Long): String?
    @JvmStatic external fun lastError(): String
    @JvmStatic external fun decodeCandidateTexts(session: Long, input: String, maxCount: Int): Array<String>?

    @JvmStatic external fun hasUserDictionary(dictName: String): Boolean
    @JvmStatic external fun exportUserDictionary(dictName: String, textFile: String): Int
    @JvmStatic external fun importUserDictionary(dictName: String, textFile: String): Int
    @JvmStatic external fun restoreUserDictionarySnapshot(snapshotFile: String): Boolean
}
