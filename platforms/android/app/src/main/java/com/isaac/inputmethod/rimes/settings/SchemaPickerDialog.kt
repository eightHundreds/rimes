package com.isaac.inputmethod.rimes.settings

import android.app.AlertDialog
import android.content.Context
import android.os.IBinder
import android.view.WindowManager
import com.isaac.inputmethod.rimes.RimesApplication
import com.isaac.inputmethod.rimes.input.InputSchemaCatalog

/** The F4-style schema switcher, shown as a dialog attached to the IME window. */
object SchemaPickerDialog {
    fun show(context: Context, windowToken: IBinder, app: RimesApplication, onSelect: (String) -> Unit) {
        val deployed = app.engine.schemaList().map { it.id }.toSet()
        val options = InputSchemaCatalog.options.filter { option ->
            (!option.requiresChordExtension || app.chordExtensionStore.isEnabled) &&
                (deployed.isEmpty() || option.id in deployed)
        }
        val current = app.inputConfigurationStore.selectedSchemaId
        val labels = options.map { "${it.name}  ·  ${it.detail}" }.toTypedArray()
        val dialog = AlertDialog.Builder(context)
            .setTitle("方案选单")
            .setSingleChoiceItems(labels, options.indexOfFirst { it.id == current }) { dialog, which ->
                onSelect(options[which].id)
                dialog.dismiss()
            }
            .setNegativeButton("取消", null)
            .create()
        dialog.window?.let { window ->
            val params = window.attributes
            params.token = windowToken
            params.type = WindowManager.LayoutParams.TYPE_APPLICATION_ATTACHED_DIALOG
            window.attributes = params
            window.addFlags(WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM)
        }
        dialog.show()
    }
}
