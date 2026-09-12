package com.isaac.inputmethod.rimes.settings

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.preference.ListPreference
import androidx.preference.Preference
import androidx.preference.PreferenceCategory
import androidx.preference.PreferenceFragmentCompat
import androidx.preference.SeekBarPreference
import androidx.preference.SwitchPreferenceCompat
import com.isaac.inputmethod.rimes.BuildConfig
import com.isaac.inputmethod.rimes.IMELog
import com.isaac.inputmethod.rimes.RimesApplication
import com.isaac.inputmethod.rimes.RimesPreferences
import com.isaac.inputmethod.rimes.input.ChordExtensionMode
import com.isaac.inputmethod.rimes.input.ChordExtensionStore
import com.isaac.inputmethod.rimes.input.ChordSettings
import com.isaac.inputmethod.rimes.input.InputConfigurationStore
import com.isaac.inputmethod.rimes.input.InputSchemaCatalog
import com.isaac.inputmethod.rimes.input.LexiconFamily
import com.isaac.inputmethod.rimes.ui.RimesAppearance

/**
 * The settings surface (`⌘⇧S` on macOS): schema, chord extension, buffer,
 * appearance, statistics, user lexicon maintenance and maintenance actions.
 * Preferences are built in code against the shared `rimes` preference file so
 * the input method observes every change immediately.
 */
class SettingsActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "RIMES 设置"
        if (savedInstanceState == null) {
            supportFragmentManager.beginTransaction()
                .replace(android.R.id.content, SettingsFragment())
                .commit()
        }
    }
}

class SettingsFragment : PreferenceFragmentCompat() {
    private lateinit var app: RimesApplication
    private lateinit var lexicon: UserLexiconService
    private var pendingFamily: LexiconFamily? = null

    private val exportLauncher = registerForActivityResult(ActivityResultContracts.CreateDocument("text/plain")) { uri ->
        val family = pendingFamily ?: return@registerForActivityResult
        if (uri != null) report(lexicon.export(family, uri), "导出")
    }
    private val importLauncher = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        val family = pendingFamily ?: return@registerForActivityResult
        if (uri != null) report(lexicon.import(family, uri), "导入")
    }
    private val snapshotLauncher = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) report(lexicon.restoreSnapshot(uri, displayName(uri)), "恢复快照")
    }

    override fun onCreatePreferences(savedInstanceState: Bundle?, rootKey: String?) {
        app = RimesApplication.of(requireContext())
        lexicon = UserLexiconService(requireContext(), app.engine)
        preferenceManager.sharedPreferencesName = RimesPreferences.FILE
        preferenceManager.sharedPreferencesMode = Context.MODE_PRIVATE
        val screen = preferenceManager.createPreferenceScreen(requireContext())
        preferenceScreen = screen

        buildSetupSection(screen)
        buildSchemaSection(screen)
        buildChordSection(screen)
        buildBufferSection(screen)
        buildAppearanceSection(screen)
        buildLexiconSection(screen)
        buildStatisticsSection(screen)
        buildMaintenanceSection(screen)
    }

    private fun category(screen: androidx.preference.PreferenceScreen, title: String): PreferenceCategory {
        val category = PreferenceCategory(requireContext()).apply { this.title = title }
        screen.addPreference(category)
        return category
    }

    private fun action(category: PreferenceCategory, title: String, summary: String? = null, onClick: () -> Unit) {
        category.addPreference(Preference(requireContext()).apply {
            this.title = title
            this.summary = summary
            isIconSpaceReserved = false
            setOnPreferenceClickListener { onClick(); true }
        })
    }

    private fun buildSetupSection(screen: androidx.preference.PreferenceScreen) {
        val category = category(screen, "启用")
        val imm = requireContext().getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        val enabled = imm.enabledInputMethodList.any { it.packageName == requireContext().packageName }
        action(category, if (enabled) "RIMES 已启用" else "在系统中启用 RIMES", "打开系统“语言和输入法”设置") {
            startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
        }
        action(category, "切换到 RIMES", "显示系统输入法选择器") { imm.showInputMethodPicker() }
        action(category, "键入测试", "在应用内文本框中试打，验证上屏") {
            startActivity(Intent(requireContext(), PlaygroundActivity::class.java))
        }
    }

    private fun buildSchemaSection(screen: androidx.preference.PreferenceScreen) {
        val category = category(screen, "输入方案")
        val store = app.inputConfigurationStore
        val list = ListPreference(requireContext()).apply {
            key = InputConfigurationStore.KEY_SELECTED
            title = "当前方案"
            isIconSpaceReserved = false
            isPersistent = false
            refreshSchemaEntries(this)
            value = store.selectedSchemaId
            summaryProvider = ListPreference.SimpleSummaryProvider.getInstance()
            setOnPreferenceChangeListener { _, newValue ->
                store.select(newValue as String)
            }
        }
        category.addPreference(list)
        schemaPreference = list
    }

    private var schemaPreference: ListPreference? = null

    private fun refreshSchemaEntries(list: ListPreference) {
        val options = InputSchemaCatalog.options.filter { !it.requiresChordExtension || app.chordExtensionStore.isEnabled }
        list.entries = options.map { "${it.name} · ${it.detail}" }.toTypedArray()
        list.entryValues = options.map { it.id }.toTypedArray()
    }

    private fun buildChordSection(screen: androidx.preference.PreferenceScreen) {
        val category = category(screen, "扩展 · 并击")
        val store = app.chordExtensionStore
        category.addPreference(SwitchPreferenceCompat(requireContext()).apply {
            key = ChordExtensionStore.KEY_ENABLED
            title = "启用并击扩展"
            summary = "飞耀并击 / 互击输入（my_combo）。开启后方案选单加入“飞耀输入”，需要重新部署。"
            isIconSpaceReserved = false
            isPersistent = false
            isChecked = store.isEnabled
            setOnPreferenceChangeListener { _, newValue ->
                store.setEnabled(newValue as Boolean)
                schemaPreference?.let { refreshSchemaEntries(it); it.value = app.inputConfigurationStore.selectedSchemaId }
                true
            }
        })
        category.addPreference(ListPreference(requireContext()).apply {
            key = ChordExtensionStore.KEY_MODE
            title = "结算方式"
            isIconSpaceReserved = false
            isPersistent = false
            entries = ChordExtensionMode.entries.map { "${it.title} · ${it.implementationName}" }.toTypedArray()
            entryValues = ChordExtensionMode.entries.map { it.name }.toTypedArray()
            value = store.mode.name
            summaryProvider = ListPreference.SimpleSummaryProvider.getInstance()
            setOnPreferenceChangeListener { _, newValue ->
                store.setMode(ChordExtensionMode.valueOf(newValue as String))
                true
            }
        })
        category.addPreference(SeekBarPreference(requireContext()).apply {
            key = ChordExtensionStore.KEY_DURATION
            title = "组键间隔（毫秒）"
            isIconSpaceReserved = false
            isPersistent = false
            min = ChordSettings.RANGE_MS.first.toInt()
            max = ChordSettings.RANGE_MS.last.toInt()
            seekBarIncrement = 10
            showSeekBarValue = true
            value = store.durationMillis.toInt()
            setOnPreferenceChangeListener { _, newValue ->
                store.setDurationMillis((newValue as Int).toLong())
                true
            }
        })
    }

    private fun buildBufferSection(screen: androidx.preference.PreferenceScreen) {
        val category = category(screen, "缓冲工作台")
        category.addPreference(SwitchPreferenceCompat(requireContext()).apply {
            key = RimesPreferences.BUFFER_ENABLED
            title = "启用缓冲模式"
            summary = "中文、英文先进入缓冲，回车轻按投递下一块、长按投递全部"
            isIconSpaceReserved = false
            setDefaultValue(false)
        })
        category.addPreference(SwitchPreferenceCompat(requireContext()).apply {
            key = RimesPreferences.BUFFER_CLOSE_AFTER_LAST
            title = "最后一块上屏后回到直输"
            isIconSpaceReserved = false
            setDefaultValue(true)
        })
        category.addPreference(SwitchPreferenceCompat(requireContext()).apply {
            key = RimesPreferences.BUFFER_RESET_ON_APP_SWITCH
            title = "切换应用时清空本地缓冲"
            summary = "隐私保护：换到另一个应用时丢弃未投递的块"
            isIconSpaceReserved = false
            setDefaultValue(false)
        })
    }

    private fun buildAppearanceSection(screen: androidx.preference.PreferenceScreen) {
        val category = category(screen, "外观")
        category.addPreference(ListPreference(requireContext()).apply {
            key = RimesAppearance.PREF_KEY
            title = "主题"
            isIconSpaceReserved = false
            entries = RimesAppearance.entries.map { "${it.title}（${it.family}）· ${it.detail}" }.toTypedArray()
            entryValues = RimesAppearance.entries.map { it.key }.toTypedArray()
            setDefaultValue(RimesAppearance.NIGHT.key)
            summaryProvider = ListPreference.SimpleSummaryProvider.getInstance()
        })
        category.addPreference(SwitchPreferenceCompat(requireContext()).apply {
            key = RimesPreferences.HARDWARE_SHIFT_TOGGLES_ASCII
            title = "外接键盘：轻点 Shift 切换中英"
            summary = "短于 500 ms 且未与其他键组合的独立 Shift 才切换"
            isIconSpaceReserved = false
            setDefaultValue(true)
        })
    }

    private fun buildLexiconSection(screen: androidx.preference.PreferenceScreen) {
        val category = category(screen, "学习词库")
        for (family in LexiconFamily.entries) {
            action(category, "导出 ${family.title} 学习词…", "librime 可移植 TSV，可在 macOS / Windows 版导入") {
                pendingFamily = family
                exportLauncher.launch("${family.dictName}-userdict.txt")
            }
            action(category, "导入 ${family.title} 学习词…", "合并到本机词库，保留已有词频") {
                pendingFamily = family
                importLauncher.launch(arrayOf("text/*", "application/octet-stream"))
            }
        }
        action(category, "恢复 *.userdb.txt 快照…", "librime 备份快照，按快照声明的词库名合并") {
            snapshotLauncher.launch(arrayOf("*/*"))
        }
    }

    private fun buildStatisticsSection(screen: androidx.preference.PreferenceScreen) {
        val category = category(screen, "扩展 · 统计 / 打字测速")
        category.addPreference(SwitchPreferenceCompat(requireContext()).apply {
            key = com.isaac.inputmethod.rimes.settings.StatisticsStore.KEY_ENABLED
            title = "记录按键与上屏统计"
            summary = "只保存每日聚合计数，不保存文本"
            isIconSpaceReserved = false
            setDefaultValue(true)
        })
        val today = app.statistics.today()
        val totals = app.statistics.totals()
        action(
            category,
            "今日：${today.keys} 键 · ${today.chars} 字 · ${"%.1f".format(today.charsPerMinute)} 字/活跃分钟",
            "累计：${totals.keys} 键 · ${totals.chars} 字 · ${totals.commits} 次上屏 · ${totals.activeMinutes} 活跃分钟",
        ) { }
        action(category, "清除统计数据") {
            app.statistics.clear()
            Toast.makeText(requireContext(), "已清除", Toast.LENGTH_SHORT).show()
        }
    }

    private fun buildMaintenanceSection(screen: androidx.preference.PreferenceScreen) {
        val category = category(screen, "维护")
        action(category, "重新部署输入方案", "重新编译词库（修改配置后使用）") {
            Toast.makeText(requireContext(), "正在部署…", Toast.LENGTH_SHORT).show()
            app.engineExecutor.execute {
                val ok = app.engine.started && app.engine.deploy()
                activity?.runOnUiThread { Toast.makeText(requireContext(), if (ok) "部署完成" else "部署失败", Toast.LENGTH_SHORT).show() }
            }
        }
        action(category, "查看运行日志", IMELog.logFile()?.absolutePath) {
            val file = IMELog.logFile() ?: return@action
            val tail = runCatching { file.readLines().takeLast(200).joinToString("\n") }.getOrDefault("(无日志)")
            android.app.AlertDialog.Builder(requireContext()).setTitle("rimes.log").setMessage(tail).setPositiveButton("关闭", null).show()
        }
        action(category, "版本", "RIMES Android ${BuildConfig.VERSION_NAME} · librime 1.16.1（静态）· 数据版本 ${runCatching { app.deployer.bundledVersion().take(12) }.getOrDefault("?")}") { }
    }

    private fun report(result: UserLexiconService.Result, verb: String) {
        val message = when (result) {
            is UserLexiconService.Result.Success -> if (result.entries >= 0) "$verb 完成：${result.entries} 条" else "$verb 完成"
            is UserLexiconService.Result.Failure -> "$verb 失败：${result.message}"
        }
        Toast.makeText(requireContext(), message, Toast.LENGTH_LONG).show()
    }

    private fun displayName(uri: Uri): String? {
        requireContext().contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) return cursor.getString(0)
        }
        return uri.lastPathSegment
    }
}
