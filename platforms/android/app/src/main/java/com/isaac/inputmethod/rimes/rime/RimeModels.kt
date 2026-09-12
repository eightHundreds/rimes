package com.isaac.inputmethod.rimes.rime

/** One candidate on the current page, already stringified out of the C bridge. */
data class RimeCandidateModel(
    val text: String,
    val comment: String,
    val label: String,
)

/**
 * Native snapshot of the current-page Rime context. Mirrors `RimeContextModel`
 * in the macOS Swift layer; the JNI adapter constructs it directly from
 * `BBRimeContext`, so field order and types are part of the bridge contract.
 */
data class RimeContextModel(
    val active: Boolean = false,
    val preedit: String = "",
    val input: String = "",
    val cursorPos: Int = 0,
    val selStart: Int = 0,
    val selEnd: Int = 0,
    val pageSize: Int = 0,
    val pageNo: Int = 0,
    val isLastPage: Boolean = false,
    val highlightedIndex: Int = 0,
    val candidates: Array<RimeCandidateModel> = emptyArray(),
) {
    val candidateList: List<RimeCandidateModel> get() = candidates.asList()

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is RimeContextModel) return false
        return active == other.active &&
            preedit == other.preedit &&
            input == other.input &&
            cursorPos == other.cursorPos &&
            selStart == other.selStart &&
            selEnd == other.selEnd &&
            pageSize == other.pageSize &&
            pageNo == other.pageNo &&
            isLastPage == other.isLastPage &&
            highlightedIndex == other.highlightedIndex &&
            candidates.contentEquals(other.candidates)
    }

    override fun hashCode(): Int {
        var result = active.hashCode()
        result = 31 * result + preedit.hashCode()
        result = 31 * result + input.hashCode()
        result = 31 * result + cursorPos
        result = 31 * result + pageNo
        result = 31 * result + highlightedIndex
        result = 31 * result + candidates.contentHashCode()
        return result
    }

    companion object {
        val EMPTY = RimeContextModel()
    }
}

/**
 * Engine status. `schemaId` is load-bearing: it drives chord gating (chord
 * release-replay runs only for `my_combo`).
 */
data class RimeStatusModel(
    val schemaId: String = "",
    val schemaName: String = "",
    val asciiMode: Boolean = false,
    val fullShape: Boolean = false,
    val simplified: Boolean = false,
    val traditional: Boolean = false,
    val asciiPunct: Boolean = false,
    val composing: Boolean = false,
    val disabled: Boolean = false,
) {
    companion object {
        val EMPTY = RimeStatusModel()
    }
}

/** A deployed schema as reported by librime. */
data class RimeSchemaItem(val id: String, val name: String)
