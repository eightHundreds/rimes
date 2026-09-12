package com.isaac.inputmethod.rimes.rime

import android.content.Context
import android.content.res.AssetManager
import com.isaac.inputmethod.rimes.IMELog
import java.io.File

/**
 * Seeds the shared Rime data directory from the APK assets.
 *
 * Layout under `filesDir/rime` (kept isolated from any other Rime frontend on
 * the device, the Android analogue of `~/Library/RimeBuffer`):
 *
 *  - `shared/`  bundled schemas/dictionaries/lua/opencc (read-only product data)
 *  - `user/`    librime user_data_dir: compiled `build/`, userdb, user.yaml
 *  - `log/`     librime + IME behaviour logs
 *
 * Product data is replaced only when the bundled fingerprint changes; the user
 * directory is never touched, so learned words survive upgrades.
 */
class RimeDataDeployer(private val context: Context) {
    val rootDir: File get() = File(context.filesDir, "rime")
    val sharedDir: File get() = File(rootDir, "shared")
    val userDir: File get() = File(rootDir, "user")
    val logDir: File get() = File(rootDir, "log")

    private val stampFile: File get() = File(rootDir, "shared.version")

    fun bundledVersion(): String = context.assets.open(ASSET_VERSION).bufferedReader().use { it.readText().trim() }

    fun deployedVersion(): String? = stampFile.takeIf { it.isFile }?.readText()?.trim()

    fun needsSeeding(): Boolean = !sharedDir.isDirectory || deployedVersion() != bundledVersion()

    /** Copies assets when needed. Returns true when new product data was written. */
    fun seedIfNeeded(): Boolean {
        rootDir.mkdirs()
        userDir.mkdirs()
        logDir.mkdirs()
        if (!needsSeeding()) return false
        val version = bundledVersion()
        val staging = File(rootDir, "shared.staging")
        staging.deleteRecursively()
        copyAssetTree(context.assets, ASSET_ROOT, staging)
        val previous = File(rootDir, "shared.previous")
        previous.deleteRecursively()
        if (sharedDir.exists()) sharedDir.renameTo(previous)
        check(staging.renameTo(sharedDir)) { "cannot move staged Rime data into place" }
        previous.deleteRecursively()
        stampFile.writeText(version)
        IMELog.write("rime shared data seeded version=${version.take(12)}")
        return true
    }

    private fun copyAssetTree(assets: AssetManager, assetPath: String, target: File) {
        val children = assets.list(assetPath) ?: emptyArray()
        if (children.isEmpty()) {
            target.parentFile?.mkdirs()
            assets.open(assetPath).use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            }
            return
        }
        target.mkdirs()
        for (child in children) {
            copyAssetTree(assets, "$assetPath/$child", File(target, child))
        }
    }

    companion object {
        const val ASSET_ROOT = "rime"
        const val ASSET_VERSION = "rime-assets.version"
    }
}
