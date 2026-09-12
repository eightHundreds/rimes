package com.isaac.inputmethod.rimes

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import com.isaac.inputmethod.rimes.buffer.BufferModel
import com.isaac.inputmethod.rimes.input.ChordExtensionStore
import com.isaac.inputmethod.rimes.input.InputConfigurationStore
import com.isaac.inputmethod.rimes.rime.RimeDataDeployer
import com.isaac.inputmethod.rimes.rime.RimeEngine
import com.isaac.inputmethod.rimes.settings.StatisticsStore
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future

/** Preference keys shared by the service and the settings screens. */
object RimesPreferences {
    const val FILE = "rimes"
    const val BUFFER_ENABLED = "buffer.enabled.v1"
    const val BUFFER_CLOSE_AFTER_LAST = "buffer.closeAfterLastDelivery.v1"
    const val BUFFER_RESET_ON_APP_SWITCH = "buffer.resetOnAppSwitch.v1"
    const val HARDWARE_SHIFT_TOGGLES_ASCII = "input.hardwareShiftTogglesAscii.v1"

    fun of(context: Context): SharedPreferences = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
}

/**
 * Process-wide singletons. The input method and the settings activity run in
 * the same process, so they share one engine, one buffer model and one set of
 * stores — the Android counterpart of the single-process macOS agent.
 */
class RimesApplication : Application() {
    lateinit var prefs: SharedPreferences
        private set
    lateinit var deployer: RimeDataDeployer
        private set
    lateinit var engine: RimeEngine
        private set
    lateinit var chordExtensionStore: ChordExtensionStore
        private set
    lateinit var inputConfigurationStore: InputConfigurationStore
        private set
    lateinit var statistics: StatisticsStore
        private set
    val bufferModel = BufferModel()
    val engineExecutor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "rime-engine").apply { isDaemon = true }
    }

    @Volatile
    private var startFuture: Future<Boolean>? = null

    override fun onCreate() {
        super.onCreate()
        prefs = RimesPreferences.of(this)
        deployer = RimeDataDeployer(this)
        IMELog.attach(deployer.logDir)
        engine = RimeEngine(deployer.sharedDir, deployer.userDir, deployer.logDir)
        chordExtensionStore = ChordExtensionStore(prefs)
        inputConfigurationStore = InputConfigurationStore(prefs, chordExtensionStore)
        statistics = StatisticsStore(prefs)
        bufferModel.enabled = prefs.getBoolean(RimesPreferences.BUFFER_ENABLED, false)
    }

    /**
     * Seeds data and starts librime on the engine thread exactly once per
     * process (later callers share the same future). First run deploys every
     * dictionary, which can take a while on slow devices.
     */
    @Synchronized
    fun startEngineAsync(): Future<Boolean> {
        startFuture?.let { return it }
        val future = engineExecutor.submit<Boolean> {
            try {
                val seeded = deployer.seedIfNeeded()
                syncSchemaListWithExtension()
                val ok = engine.start()
                if (ok && seeded) engine.deploy()
                ok
            } catch (error: Exception) {
                IMELog.write("engine bootstrap failed: ${error.javaClass.simpleName}: ${error.message}")
                false
            }
        }
        startFuture = future
        return future
    }

    /**
     * Keeps `default.custom.yaml` in the user directory consistent with the
     * chord extension so `my_combo` only enters the switcher when enabled.
     */
    fun syncSchemaListWithExtension(): Boolean {
        val file = java.io.File(deployer.userDir, "default.custom.yaml")
        val shared = java.io.File(deployer.sharedDir, "default.custom.yaml")
        if (!file.exists() && shared.isFile) {
            file.parentFile?.mkdirs()
            shared.copyTo(file)
        }
        val wanted = com.isaac.inputmethod.rimes.input.InputSchemaCatalog.enabledIds(chordExtensionStore.isEnabled)
        val current = com.isaac.inputmethod.rimes.input.SchemaListStore.enabledIds(file)
        if (current == wanted) return false
        com.isaac.inputmethod.rimes.input.SchemaListStore.writeEnabledIds(wanted, file)
        IMELog.write("schema_list rewritten chordExtension=${chordExtensionStore.isEnabled}")
        return true
    }

    companion object {
        fun of(context: Context): RimesApplication = context.applicationContext as RimesApplication
    }
}
