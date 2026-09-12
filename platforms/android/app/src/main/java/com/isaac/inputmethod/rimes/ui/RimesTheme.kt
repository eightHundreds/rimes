package com.isaac.inputmethod.rimes.ui

import android.content.SharedPreferences
import android.graphics.Color

/** Same appearance families and colorways as macOS (`RimeUI.swift`). */
enum class RimesAppearance(val key: String, val title: String, val family: String, val detail: String, val isDark: Boolean) {
    NIGHT("night", "墨竹", "经典", "经典深色配色，层级清晰，适合长时间输入。", true),
    DAY("day", "翡翠", "经典", "经典浅色配色，柔和边界与固定产品绿。", false),
    QUIET("quiet", "静谧", "经典", "经典去色配色，降低视觉刺激。", true),
    RASTA("rasta", "拉斯塔", "拉斯塔", "深色精致骨架，以红、黄、绿三色共同组织状态与操作。", true);

    val palette: RimesPalette
        get() = when (this) {
            NIGHT -> RimesPalettes.night
            DAY -> RimesPalettes.day
            QUIET -> RimesPalettes.quiet
            RASTA -> RimesPalettes.rasta
        }

    companion object {
        const val PREF_KEY = "appearance.theme.v1"

        fun fromKey(key: String?): RimesAppearance = entries.firstOrNull { it.key == key } ?: NIGHT

        fun current(prefs: SharedPreferences): RimesAppearance = fromKey(prefs.getString(PREF_KEY, null))
    }
}

/** sRGB values copied from the macOS palettes; accessed as opaque ARGB ints. */
data class RimesPalette(
    val accentGreen: Int,
    val accentSecondary: Int,
    val accentTertiary: Int,
    val brandRed: Int,
    val brandYellow: Int,
    val brandGreen: Int,
    val bufferBackground: Int,
    val bufferBorder: Int,
    val bufferSourceRail: Int,
    val bufferChip: Int,
    val bufferChipSelected: Int,
    val bufferPreedit: Int,
    val bufferMuted: Int,
    val surface: Int,
    val surfaceSecondary: Int,
    val surfaceTertiary: Int,
    val border: Int,
    val borderStrong: Int,
    val textPrimary: Int,
    val textSecondary: Int,
    val textMuted: Int,
    val selectedCandidateBackground: Int,
    val selectedCandidateText: Int,
    val candidateBackground: Int,
    val warningText: Int,
    val dangerText: Int,
) {
    val accentForeground: Int get() = if (luminance(accentGreen) > 0.5) Color.BLACK else Color.WHITE

    companion object {
        private fun luminance(color: Int): Double {
            fun channel(c: Int): Double {
                val v = c / 255.0
                return if (v <= 0.03928) v / 12.92 else Math.pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(Color.red(color)) + 0.7152 * channel(Color.green(color)) + 0.0722 * channel(Color.blue(color))
        }
    }
}

private fun rgb(value: Int): Int = (0xFF shl 24) or value

object RimesPalettes {
    private const val PRODUCT_GREEN = 0x22C55E

    val night = RimesPalette(
        accentGreen = rgb(PRODUCT_GREEN), accentSecondary = rgb(0xEAB308), accentTertiary = rgb(0xEF4444),
        brandRed = rgb(0xEF4444), brandYellow = rgb(0xEAB308), brandGreen = rgb(PRODUCT_GREEN),
        bufferBackground = rgb(0x0C1E33), bufferBorder = rgb(0x2C5A8C), bufferSourceRail = rgb(0x15191F),
        bufferChip = rgb(0x143A27), bufferChipSelected = rgb(0x165030), bufferPreedit = rgb(0x165030), bufferMuted = rgb(0x9AA2AE),
        surface = rgb(0x101318), surfaceSecondary = rgb(0x171B22), surfaceTertiary = rgb(0x1E232C),
        border = rgb(0x252A33), borderStrong = rgb(0x607080),
        textPrimary = rgb(0xF3F5F8), textSecondary = rgb(0x9AA2AE), textMuted = rgb(0x838B98),
        selectedCandidateBackground = rgb(0x15803D), selectedCandidateText = rgb(0xFFFFFF), candidateBackground = rgb(0x101318),
        warningText = rgb(0xFF9230), dangerText = rgb(0xFF4245),
    )

    val day = RimesPalette(
        accentGreen = rgb(PRODUCT_GREEN), accentSecondary = rgb(0xA16207), accentTertiary = rgb(0xB42318),
        brandRed = rgb(0xB42318), brandYellow = rgb(0xA16207), brandGreen = rgb(PRODUCT_GREEN),
        bufferBackground = rgb(0xF1F6FC), bufferBorder = rgb(0x8298B0), bufferSourceRail = rgb(0xF0F4F7),
        bufferChip = rgb(0xDAF3E6), bufferChipSelected = rgb(0xC5EDD6), bufferPreedit = rgb(0xC9EED9), bufferMuted = rgb(0x4B5563),
        surface = rgb(0xF5F7FA), surfaceSecondary = rgb(0xEEF2F6), surfaceTertiary = rgb(0xE7ECF2),
        border = rgb(0xC9D2DE), borderStrong = rgb(0x7C8797),
        textPrimary = rgb(0x17202B), textSecondary = rgb(0x334155), textMuted = rgb(0x4B5563),
        selectedCandidateBackground = rgb(0x0F6A3F), selectedCandidateText = rgb(0xFFFFFF), candidateBackground = rgb(0xF8FAFC),
        warningText = rgb(0x8A4B00), dangerText = rgb(0xB42318),
    )

    val quiet = RimesPalette(
        accentGreen = rgb(0xA3A3A3), accentSecondary = rgb(0xD4D4D4), accentTertiary = rgb(0x737373),
        brandRed = rgb(0x737373), brandYellow = rgb(0xD4D4D4), brandGreen = rgb(0xA3A3A3),
        bufferBackground = rgb(0x111111), bufferBorder = rgb(0x6B6B6B), bufferSourceRail = rgb(0x191919),
        bufferChip = rgb(0x333333), bufferChipSelected = rgb(0x454545), bufferPreedit = rgb(0x454545), bufferMuted = rgb(0xA3A3A3),
        surface = rgb(0x141414), surfaceSecondary = rgb(0x1B1B1B), surfaceTertiary = rgb(0x252525),
        border = rgb(0x3A3A3A), borderStrong = rgb(0x737373),
        textPrimary = rgb(0xF5F5F5), textSecondary = rgb(0xC7C7C7), textMuted = rgb(0xA3A3A3),
        selectedCandidateBackground = rgb(0x6B6B6B), selectedCandidateText = rgb(0xFFFFFF), candidateBackground = rgb(0x141414),
        warningText = rgb(0xFF9230), dangerText = rgb(0xFF4245),
    )

    val rasta = RimesPalette(
        accentGreen = rgb(0x35B85A), accentSecondary = rgb(0xF2C94C), accentTertiary = rgb(0xE5524A),
        brandRed = rgb(0xE5524A), brandYellow = rgb(0xF2C94C), brandGreen = rgb(0x35B85A),
        bufferBackground = rgb(0x171713), bufferBorder = rgb(0x6F653B), bufferSourceRail = rgb(0x1D211B),
        bufferChip = rgb(0x213A27), bufferChipSelected = rgb(0x2C5133), bufferPreedit = rgb(0x29472E), bufferMuted = rgb(0xB8AD91),
        surface = rgb(0x141511), surfaceSecondary = rgb(0x20211B), surfaceTertiary = rgb(0x2A2A21),
        border = rgb(0x3B3A2D), borderStrong = rgb(0x756E4F),
        textPrimary = rgb(0xF7F3E8), textSecondary = rgb(0xCEC7B2), textMuted = rgb(0xA79F88),
        selectedCandidateBackground = rgb(0x287F42), selectedCandidateText = rgb(0xFFFFFF), candidateBackground = rgb(0x151610),
        warningText = rgb(0xF2C94C), dangerText = rgb(0xFF766E),
    )
}
