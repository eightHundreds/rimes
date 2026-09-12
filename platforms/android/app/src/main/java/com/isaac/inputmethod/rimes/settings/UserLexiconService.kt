package com.isaac.inputmethod.rimes.settings

import android.content.Context
import android.net.Uri
import com.isaac.inputmethod.rimes.IMELog
import com.isaac.inputmethod.rimes.input.LexiconFamily
import com.isaac.inputmethod.rimes.rime.RimeEngine
import java.io.File

/**
 * User-dictionary maintenance through librime's official `levers` module (the
 * same path as macOS `UserLexiconService`). Files cross the process boundary
 * through the Storage Access Framework; the LevelDB itself is never copied.
 */
class UserLexiconService(private val context: Context, private val engine: RimeEngine) {
    sealed class Result {
        data class Success(val entries: Int) : Result()
        data class Failure(val message: String) : Result()
    }

    /** Portable TSV export (`<text>\t<code>\t<weight>`), suitable for import on any RIMES platform. */
    fun export(family: LexiconFamily, destination: Uri): Result {
        if (!engine.started) return Result.Failure("引擎尚未启动")
        if (!engine.hasUserDictionary(family.dictName)) return Result.Failure("${family.title} 尚无学习词库")
        val temp = File(context.cacheDir, "${family.dictName}-export.txt")
        temp.delete()
        val count = engine.exportUserDictionary(family.dictName, temp)
        if (count < 0) return Result.Failure("导出失败：librime 拒绝了请求")
        return try {
            context.contentResolver.openOutputStream(destination, "wt")?.use { output ->
                temp.inputStream().use { it.copyTo(output) }
            } ?: return Result.Failure("无法写入所选文件")
            IMELog.write("user lexicon exported dict=${family.dictName} entries=$count")
            Result.Success(count)
        } catch (error: Exception) {
            Result.Failure("写入失败：${error.message}")
        } finally {
            temp.delete()
        }
    }

    /** Merge a portable TSV export. Frequencies follow librime's UserDbImporter rules. */
    fun import(family: LexiconFamily, source: Uri): Result {
        if (!engine.started) return Result.Failure("引擎尚未启动")
        val temp = File(context.cacheDir, "${family.dictName}-import.txt")
        try {
            context.contentResolver.openInputStream(source)?.use { input ->
                temp.outputStream().use { input.copyTo(it) }
            } ?: return Result.Failure("无法读取所选文件")
            if (!looksLikePortableTsv(temp)) return Result.Failure("文件不是 librime 词库导出格式")
            val count = engine.importUserDictionary(family.dictName, temp)
            if (count < 0) return Result.Failure("导入失败：librime 拒绝了请求")
            IMELog.write("user lexicon imported dict=${family.dictName} entries=$count")
            return Result.Success(count)
        } catch (error: Exception) {
            return Result.Failure("读取失败：${error.message}")
        } finally {
            temp.delete()
        }
    }

    /** Merge a lossless `<name>.userdb.txt` snapshot produced by librime's backup. */
    fun restoreSnapshot(source: Uri, displayName: String?): Result {
        if (!engine.started) return Result.Failure("引擎尚未启动")
        val name = displayName ?: "snapshot.userdb.txt"
        if (!name.endsWith(".userdb.txt")) return Result.Failure("快照文件名必须以 .userdb.txt 结尾")
        val temp = File(context.cacheDir, name)
        try {
            context.contentResolver.openInputStream(source)?.use { input ->
                temp.outputStream().use { input.copyTo(it) }
            } ?: return Result.Failure("无法读取所选文件")
            val declared = snapshotDbName(temp) ?: return Result.Failure("快照缺少 db_name 声明")
            if (LexiconFamily.entries.none { it.dictName == declared }) {
                return Result.Failure("快照属于未知词库：$declared")
            }
            return if (engine.restoreUserDictionarySnapshot(temp)) {
                IMELog.write("user lexicon snapshot restored dict=$declared")
                Result.Success(-1)
            } else {
                Result.Failure("恢复失败：librime 拒绝了请求")
            }
        } catch (error: Exception) {
            return Result.Failure("读取失败：${error.message}")
        } finally {
            temp.delete()
        }
    }

    companion object {
        /** librime TSV exports start with a `# Rime user dictionary export` header. */
        fun looksLikePortableTsv(file: File): Boolean {
            val head = file.bufferedReader().use { reader -> generateSequence { reader.readLine() }.take(20).toList() }
            if (head.isEmpty()) return false
            if (head.first().startsWith("# Rime user dictionary export")) return true
            return head.any { line -> !line.startsWith("#") && line.split('\t').size >= 2 }
        }

        /** TextDb metadata lines look like `#@/db_name<TAB>rime_ice` (older builds omit the slash). */
        fun snapshotDbName(file: File): String? {
            file.bufferedReader().use { reader ->
                for (line in generateSequence { reader.readLine() }.take(20)) {
                    if (!line.startsWith("#@")) continue
                    val parts = line.removePrefix("#@").split('\t', ' ', limit = 2)
                    if (parts.size == 2 && parts[0].trimStart('/') == "db_name") return parts[1].trim()
                }
            }
            return null
        }
    }
}
