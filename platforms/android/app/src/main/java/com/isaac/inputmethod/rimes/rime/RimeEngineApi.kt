package com.isaac.inputmethod.rimes.rime

/**
 * The subset of [RimeEngine] the input controller depends on. Kept as an
 * interface so key routing can be unit-tested against a scripted engine.
 */
interface RimeEngineApi {
    val isHealthy: Boolean
    fun start(): Boolean
    fun createSession(): Long
    fun destroySession(session: Long)
    fun sessionExists(session: Long): Boolean
    fun processKey(keycode: Int, mask: Int = 0, session: Long): Boolean
    fun commitComposition(session: Long): Boolean
    fun clearComposition(session: Long)
    fun selectCandidate(onPageIndex: Int, session: Long): Boolean
    fun getOption(name: String, session: Long): Boolean
    fun setOption(name: String, value: Boolean, session: Long)
    fun selectSchema(id: String, session: Long): Boolean
    fun takeCommit(session: Long): String?
    fun currentSchema(session: Long): String?
    fun getContext(session: Long): RimeContextModel
    fun getStatus(session: Long): RimeStatusModel
    fun schemaList(): List<RimeSchemaItem>
}
