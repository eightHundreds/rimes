package com.isaac.inputmethod.rimes.rime

import com.isaac.inputmethod.rimes.IMELog
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Thin wrapper over the shared bridge, mirroring `RimeEngine.swift`.
 *
 * Deliberately holds NO shared session: the input method creates one session
 * per bound text field so composition never bleeds across fields. The librime
 * process state is global (guarded inside the bridge); session state is not.
 */
class RimeEngine(
    val sharedDataDir: File,
    val userDataDir: File,
    val logDir: File,
) : RimeEngineApi {
    interface MaintenanceObserver {
        /** Sent before librime closes every session; settle composition and drop cached ids. */
        fun rimeUserDictionaryMaintenanceWillBegin()

        /** Sent after the operation; recreate sessions lazily. */
        fun rimeUserDictionaryMaintenanceDidEnd(succeeded: Boolean)
    }

    @Volatile
    var started = false
        private set

    private val observers = CopyOnWriteArrayList<MaintenanceObserver>()

    @Volatile
    private var schemaListCache: List<RimeSchemaItem>? = null

    /**
     * setup + initialize + deploy + smoke session. Retries on a later call if it
     * failed, so a transient failure is not permanent. Blocking: the first run
     * compiles every dictionary, so callers run it off the main thread.
     */
    @Synchronized
    override fun start(): Boolean {
        if (started) return true
        if (!RimeBridge.ensureLoaded()) {
            IMELog.write("rime start FAILED: native library unavailable")
            return false
        }
        userDataDir.mkdirs()
        logDir.mkdirs()
        val t0 = System.currentTimeMillis()
        started = RimeBridge.start(sharedDataDir.absolutePath, userDataDir.absolutePath, logDir.absolutePath)
        val elapsed = System.currentTimeMillis() - t0
        if (started) {
            IMELog.write("rime start OK shared=${sharedDataDir.absolutePath} user=${userDataDir.absolutePath} ms=$elapsed")
        } else {
            IMELog.write("rime start FAILED after ${elapsed}ms: ${lastError()}")
        }
        return started
    }

    override val isHealthy: Boolean get() = started && RimeBridge.isHealthy()
    val hasOctagram: Boolean get() = started && RimeBridge.hasOctagram()

    override fun createSession(): Long = if (started) RimeBridge.createSession() else 0L

    override fun destroySession(session: Long) {
        if (session != 0L && started) RimeBridge.destroySession(session)
    }

    override fun sessionExists(session: Long): Boolean = session != 0L && started && RimeBridge.sessionExists(session)

    override fun processKey(keycode: Int, mask: Int, session: Long): Boolean =
        session != 0L && RimeBridge.processKey(session, keycode, mask)

    override fun commitComposition(session: Long): Boolean = session != 0L && RimeBridge.commitComposition(session)
    override fun clearComposition(session: Long) {
        if (session != 0L) RimeBridge.clearComposition(session)
    }

    override fun selectCandidate(onPageIndex: Int, session: Long): Boolean =
        session != 0L && RimeBridge.selectCandidateOnCurrentPage(session, onPageIndex)

    override fun getOption(name: String, session: Long): Boolean = session != 0L && RimeBridge.getOption(session, name)
    override fun setOption(name: String, value: Boolean, session: Long) {
        if (session != 0L) RimeBridge.setOption(session, name, value)
    }

    override fun selectSchema(id: String, session: Long): Boolean = session != 0L && RimeBridge.selectSchema(session, id)

    override fun takeCommit(session: Long): String? = if (session == 0L) null else RimeBridge.takeCommit(session)?.takeIf { it.isNotEmpty() }
    override fun currentSchema(session: Long): String? = if (session == 0L) null else RimeBridge.currentSchema(session)
    fun lastError(): String = if (RimeBridge.ensureLoaded()) RimeBridge.lastError() else "native library unavailable"

    override fun getContext(session: Long): RimeContextModel =
        if (session == 0L) RimeContextModel.EMPTY else RimeBridge.getContext(session) ?: RimeContextModel.EMPTY

    override fun getStatus(session: Long): RimeStatusModel =
        if (session == 0L) RimeStatusModel.EMPTY else RimeBridge.getStatus(session) ?: RimeStatusModel.EMPTY

    fun configDouble(configId: String, key: String): Double? {
        if (!started) return null
        val value = RimeBridge.configDouble(configId, key)
        return if (value.isNaN()) null else value
    }

    /**
     * Complete commit previews for a private inference session (one lock, no
     * bridge scratch string escapes). Returns null when unsupported.
     */
    fun decodeCandidateTexts(input: String, maximumCount: Int, session: Long): List<String>? {
        if (session == 0L) return null
        return RimeBridge.decodeCandidateTexts(session, input, maximumCount.coerceIn(1, 5))?.asList()
    }

    /**
     * Schemas Rime has actually deployed. librime reloads every listed schema
     * config on each call, so the copied list is cached until a deployment or
     * an explicit invalidation; sessions remain per field.
     */
    override fun schemaList(): List<RimeSchemaItem> {
        schemaListCache?.let { return it }
        if (!started) return emptyList()
        val loaded = RimeBridge.schemaList()
            ?.filter { it.id.isNotEmpty() }
            ?.map { if (it.name.isEmpty()) RimeSchemaItem(it.id, it.id) else it }
            ?: emptyList()
        if (loaded.isNotEmpty()) schemaListCache = loaded
        IMELog.write("rime schema list reload entries=${loaded.size}")
        return loaded
    }

    fun invalidateSchemaListCacheAfterDeployment() {
        schemaListCache = null
    }

    /** Re-run maintenance (after a data upgrade). Blocking. */
    fun deploy(): Boolean {
        if (!started) return false
        val ok = RimeBridge.deploy()
        invalidateSchemaListCacheAfterDeployment()
        IMELog.write("rime deploy ok=$ok")
        return ok
    }

    // MARK: User dictionary maintenance (levers)

    fun addMaintenanceObserver(observer: MaintenanceObserver) {
        observers.addIfAbsent(observer)
    }

    fun removeMaintenanceObserver(observer: MaintenanceObserver) {
        observers.remove(observer)
    }

    fun hasUserDictionary(name: String): Boolean = started && name.isNotEmpty() && RimeBridge.hasUserDictionary(name)

    /** Export learned entries in librime's portable TSV format. Closes every session. */
    fun exportUserDictionary(name: String, to: File): Int = performUserDictionaryMaintenance {
        RimeBridge.exportUserDictionary(name, to.absolutePath)
    }

    /** Merge portable TSV entries; existing frequencies follow librime's importer rules. */
    fun importUserDictionary(name: String, from: File): Int = performUserDictionaryMaintenance {
        RimeBridge.importUserDictionary(name, from.absolutePath)
    }

    /** Merge a lossless `*.userdb.txt` snapshot; the snapshot declares its own db name. */
    fun restoreUserDictionarySnapshot(from: File): Boolean = performUserDictionaryMaintenance {
        if (RimeBridge.restoreUserDictionarySnapshot(from.absolutePath)) 0 else -1
    } >= 0

    private fun performUserDictionaryMaintenance(operation: () -> Int): Int {
        if (!started) return -1
        observers.forEach { it.rimeUserDictionaryMaintenanceWillBegin() }
        val result = operation()
        observers.forEach { it.rimeUserDictionaryMaintenanceDidEnd(result >= 0) }
        return result
    }
}
