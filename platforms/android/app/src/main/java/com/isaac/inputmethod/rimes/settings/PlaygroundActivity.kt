package com.isaac.inputmethod.rimes.settings

import android.os.Bundle
import android.text.InputType
import android.view.ViewGroup
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

/**
 * 键入测试: plain host fields for verifying commits end to end (also the
 * target of the emulator E2E script). Nothing here talks to the input method
 * directly; it is an ordinary client like any other app.
 */
class PlaygroundActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "键入测试"
        val density = resources.displayMetrics.density
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val pad = (16 * density).toInt()
            setPadding(pad, pad, pad, pad)
        }
        root.addView(TextView(this).apply { text = "普通文本框：使用 RIMES 输入，上屏内容显示在下方。" })
        root.addView(EditText(this).apply {
            id = FIELD_ID
            hint = "在这里输入"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            minLines = 3
            contentDescription = "playground-field"
        }, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        root.addView(TextView(this).apply { text = "密码框：RIMES 直接透传 ASCII，不经 Rime，不进入缓冲。" })
        root.addView(EditText(this).apply {
            id = PASSWORD_ID
            hint = "密码框"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            contentDescription = "playground-password"
        }, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        setContentView(root)
    }

    companion object {
        val FIELD_ID = com.isaac.inputmethod.rimes.R.id.playground_field
        val PASSWORD_ID = com.isaac.inputmethod.rimes.R.id.playground_password
    }
}
