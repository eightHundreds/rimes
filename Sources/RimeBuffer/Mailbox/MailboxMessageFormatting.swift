import AppKit
import Foundation

enum MailboxBodyDisplayKind: Equatable {
    case prose
    case preformatted
    case markdown
    case json
}

struct MailboxBodyStyle {
    let textColor: NSColor
    let secondaryTextColor: NSColor
    let codeTextColor: NSColor
    let codeBackgroundColor: NSColor
    let linkColor: NSColor
}

struct MailboxBodyPresentation {
    let kind: MailboxBodyDisplayKind
    let attributedText: NSAttributedString
    let formatBadgeTitle: String?
    let linkTextColor: NSColor
}

/// Shared typography for the Mailbox terminal surface. Keeping the font
/// choice in one place prevents metadata, Markdown, JSON, and plain text from
/// drifting onto different baselines.
enum MailboxTerminalTypography {
    static func font(ofSize size: CGFloat,
                     weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}

/// Pure, display-only formatting for Mailbox messages. Message bodies remain
/// byte-for-byte durable in MailboxStore; this layer may reflow Markdown or
/// pretty-print valid JSON, but never writes the presentation back to disk.
enum MailboxMessageFormatting {
    private static let bodyFont = MailboxTerminalTypography.font(ofSize: 12)
    private static let codeFont = MailboxTerminalTypography.font(ofSize: 11.5)
    private static let maximumJSONFormattingBytes = 1_048_576

    static func presentation(for message: MailboxMessage,
                             style: MailboxBodyStyle) -> MailboxBodyPresentation {
        let kind = displayKind(format: message.format, body: message.body)
        let attributedText: NSAttributedString
        switch kind {
        case .prose:
            attributedText = attributedPlainText(
                message.body,
                font: bodyFont,
                color: style.textColor,
                preformatted: false
            )
        case .preformatted:
            attributedText = attributedPlainText(
                normalizedNewlines(message.body),
                font: codeFont,
                color: style.codeTextColor,
                preformatted: true
            )
        case .markdown:
            attributedText = attributedMarkdown(message.body, style: style)
        case .json:
            attributedText = attributedPlainText(
                prettyPrintedJSON(message.body) ?? normalizedNewlines(message.body),
                font: codeFont,
                color: style.codeTextColor,
                preformatted: true
            )
        }
        return MailboxBodyPresentation(
            kind: kind,
            attributedText: attributedText,
            formatBadgeTitle: formatBadgeTitle(for: message.format),
            linkTextColor: style.linkColor
        )
    }

    static func displayKind(format: AITextContentFormat,
                            body: String) -> MailboxBodyDisplayKind {
        switch format {
        case .plain:
            return usesPreformattedPlainText(body) ? .preformatted : .prose
        case .markdown:
            return .markdown
        case .json:
            return .json
        }
    }

    static func preview(for message: MailboxMessage?) -> String {
        guard let message else { return "暂无消息" }
        let kind = displayKind(format: message.format, body: message.body)
        if kind == .preformatted {
            let lineCount = normalizedNewlines(message.body)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .count
            return "PRE · \(lineCount) 行预格式文本"
        }
        if message.format == .json, let summary = jsonPreviewSummary(message.body) {
            return "JSON · \(summary)"
        }
        let source: String
        switch message.format {
        case .plain:
            source = message.body
        case .markdown:
            source = markdownPreviewText(message.body)
        case .json:
            source = message.body
        }
        let collapsed = collapseWhitespace(source)
        guard !collapsed.isEmpty else { return "暂无消息" }
        let bounded = collapsed.count > 240
            ? String(collapsed.prefix(240)) + "…"
            : collapsed
        switch message.format {
        case .plain:
            return bounded
        case .markdown:
            return "MD · \(bounded)"
        case .json:
            return "JSON · invalid · \(bounded)"
        }
    }

    private static func jsonPreviewSummary(_ text: String) -> String? {
        guard let source = text.data(using: .utf8),
              source.count <= maximumJSONFormattingBytes,
              let value = try? JSONSerialization.jsonObject(
                  with: source,
                  options: [.fragmentsAllowed]
              ) else { return nil }
        if let object = value as? [String: Any] {
            return "object · \(object.count) keys"
        }
        if let array = value as? [Any] {
            return "array · \(array.count) items"
        }
        return "value"
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func usesPreformattedPlainText(_ text: String) -> Bool {
        let normalized = normalizedNewlines(text)
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return false }

        if lines.contains(where: { $0.contains("\t") }) { return true }
        if lines.contains(where: { line in
            guard let first = line.first else { return false }
            return first == " " || first == "\t"
        }) { return true }

        let alignedColumns = lines.reduce(into: 0) { count, line in
            if line.range(of: #"\S {2,}\S"#, options: .regularExpression) != nil {
                count += 1
            }
        }
        if alignedColumns >= 2 { return true }

        let symbolicLines = lines.reduce(into: 0) { count, line in
            let visible = line.unicodeScalars.filter {
                !CharacterSet.whitespacesAndNewlines.contains($0)
            }
            guard visible.count >= 2 else { return }
            let symbols = visible.filter {
                !CharacterSet.alphanumerics.contains($0)
            }.count
            if symbols >= 2, Double(symbols) / Double(visible.count) >= 0.55 {
                count += 1
            }
        }
        return symbolicLines >= 2
    }

    static func prettyPrintedJSON(_ text: String) -> String? {
        guard let source = text.data(using: .utf8),
              source.count <= maximumJSONFormattingBytes,
              let value = try? JSONSerialization.jsonObject(
                  with: source,
                  options: [.fragmentsAllowed]
              ),
              let data = try? JSONSerialization.data(
                  withJSONObject: value,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
              ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func formatBadgeTitle(for format: AITextContentFormat) -> String? {
        switch format {
        case .plain: return nil
        case .markdown: return "Markdown"
        case .json: return "JSON"
        }
    }

    private static func normalizedNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func attributedPlainText(_ text: String,
                                            font: NSFont,
                                            color: NSColor,
                                            preformatted: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        let lineHeight: CGFloat = preformatted ? 17 : 18
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.lineSpacing = 0
        paragraph.paragraphSpacing = preformatted ? 0 : 4
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private static func attributedMarkdown(_ source: String,
                                           style: MailboxBodyStyle) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let lines = normalizedNewlines(source).split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = trimmed.hasPrefix("```") ? "```" : "~~~"
                let language = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index]
                        .trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence) {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                appendCodeBlock(
                    codeLines.joined(separator: "\n"),
                    language: language,
                    to: result,
                    style: style
                )
                continue
            }

            if trimmed.isEmpty {
                appendParagraphBreak(to: result)
                index += 1
                continue
            }

            if let heading = markdownHeading(trimmed) {
                let size: CGFloat = heading.level == 1 ? 13 : 12
                let paragraph = paragraphStyle(lineSpacing: 2, paragraphSpacing: 7)
                appendInlineMarkdown(
                    heading.text,
                    to: result,
                    attributes: [
                        .font: MailboxTerminalTypography.font(ofSize: size, weight: .semibold),
                        .foregroundColor: style.textColor,
                        .paragraphStyle: paragraph,
                    ],
                    style: style
                )
                appendLineBreak(to: result, paragraphStyle: paragraph)
                index += 1
                continue
            }

            if isHorizontalRule(trimmed) {
                let paragraph = paragraphStyle(lineSpacing: 0, paragraphSpacing: 6)
                result.append(NSAttributedString(
                    string: "────────────\n",
                    attributes: [
                        .font: MailboxTerminalTypography.font(ofSize: 10),
                        .foregroundColor: style.secondaryTextColor,
                        .paragraphStyle: paragraph,
                    ]
                ))
                index += 1
                continue
            }

            if let quote = markdownQuote(trimmed) {
                let paragraph = paragraphStyle(
                    lineSpacing: 2,
                    paragraphSpacing: 5,
                    headIndent: 14,
                    firstLineHeadIndent: 0
                )
                result.append(NSAttributedString(
                    string: "│ ",
                    attributes: [
                        .font: MailboxTerminalTypography.font(ofSize: 12, weight: .medium),
                        .foregroundColor: style.secondaryTextColor,
                        .paragraphStyle: paragraph,
                    ]
                ))
                appendInlineMarkdown(
                    quote,
                    to: result,
                    attributes: [
                        .font: MailboxTerminalTypography.font(ofSize: 12),
                        .foregroundColor: style.secondaryTextColor,
                        .paragraphStyle: paragraph,
                    ],
                    style: style
                )
                appendLineBreak(to: result, paragraphStyle: paragraph)
                index += 1
                continue
            }

            if let listItem = markdownListItem(trimmed) {
                let paragraph = paragraphStyle(
                    lineSpacing: 2,
                    paragraphSpacing: 3,
                    headIndent: 18,
                    firstLineHeadIndent: 0
                )
                result.append(NSAttributedString(
                    string: listItem.prefix,
                    attributes: [
                        .font: MailboxTerminalTypography.font(ofSize: 12, weight: .medium),
                        .foregroundColor: style.secondaryTextColor,
                        .paragraphStyle: paragraph,
                    ]
                ))
                appendInlineMarkdown(
                    listItem.text,
                    to: result,
                    attributes: [
                        .font: bodyFont,
                        .foregroundColor: style.textColor,
                        .paragraphStyle: paragraph,
                    ],
                    style: style
                )
                appendLineBreak(to: result, paragraphStyle: paragraph)
                index += 1
                continue
            }

            var paragraphLines = [trimmed]
            index += 1
            while index < lines.count {
                let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                if candidate.isEmpty || isMarkdownBlockStart(candidate) { break }
                paragraphLines.append(candidate)
                index += 1
            }
            let paragraph = paragraphStyle(lineSpacing: 2, paragraphSpacing: 5)
            appendInlineMarkdown(
                paragraphLines.joined(separator: " "),
                to: result,
                attributes: [
                    .font: bodyFont,
                    .foregroundColor: style.textColor,
                    .paragraphStyle: paragraph,
                ],
                style: style
            )
            appendLineBreak(to: result, paragraphStyle: paragraph)
        }

        while result.string.hasSuffix("\n\n") {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        if result.length == 0 {
            return attributedPlainText("", font: bodyFont, color: style.textColor, preformatted: false)
        }
        return result
    }

    private static func appendCodeBlock(_ code: String,
                                        language: String,
                                        to result: NSMutableAttributedString,
                                        style: MailboxBodyStyle) {
        let paragraph = paragraphStyle(
            lineSpacing: 1,
            paragraphSpacing: 8,
            headIndent: 7,
            firstLineHeadIndent: 7,
            tailIndent: -7
        )
        if !language.isEmpty {
            result.append(NSAttributedString(
                string: language.uppercased() + "\n",
                attributes: [
                    .font: MailboxTerminalTypography.font(ofSize: 9, weight: .semibold),
                    .foregroundColor: style.secondaryTextColor,
                    .backgroundColor: style.codeBackgroundColor,
                    .paragraphStyle: paragraph,
                ]
            ))
        }
        result.append(NSAttributedString(
            string: code.isEmpty ? " " : code,
            attributes: [
                .font: codeFont,
                .foregroundColor: style.codeTextColor,
                .backgroundColor: style.codeBackgroundColor,
                .paragraphStyle: paragraph,
            ]
        ))
        appendLineBreak(to: result, paragraphStyle: paragraph, background: style.codeBackgroundColor)
    }

    private static func appendInlineMarkdown(_ text: String,
                                             to result: NSMutableAttributedString,
                                             attributes: [NSAttributedString.Key: Any],
                                             style: MailboxBodyStyle) {
        var cursor = text.startIndex
        var plainStart = cursor

        func flushPlain(until end: String.Index) {
            guard plainStart < end else { return }
            result.append(NSAttributedString(
                string: String(text[plainStart..<end]),
                attributes: attributes
            ))
        }

        while cursor < text.endIndex {
            let remainder = text[cursor...]

            if remainder.hasPrefix("\\"),
               let escaped = text.index(cursor, offsetBy: 1, limitedBy: text.endIndex),
               escaped < text.endIndex {
                flushPlain(until: cursor)
                let next = text.index(after: escaped)
                result.append(NSAttributedString(
                    string: String(text[escaped..<next]),
                    attributes: attributes
                ))
                cursor = next
                plainStart = cursor
                continue
            }

            if remainder.hasPrefix("!["),
               let close = text[cursor...].firstIndex(of: "]") {
                let afterClose = text.index(after: close)
                if afterClose < text.endIndex, text[afterClose] == "(",
                   let end = text[afterClose...].firstIndex(of: ")") {
                    flushPlain(until: cursor)
                    let altStart = text.index(cursor, offsetBy: 2)
                    let alt = String(text[altStart..<close])
                    result.append(NSAttributedString(
                        string: alt.isEmpty ? "[图片]" : "[图片：\(alt)]",
                        attributes: merging(attributes, [
                            .foregroundColor: style.secondaryTextColor,
                        ])
                    ))
                    cursor = text.index(after: end)
                    plainStart = cursor
                    continue
                }
            }

            if remainder.hasPrefix("["),
               let close = text[cursor...].firstIndex(of: "]") {
                let afterClose = text.index(after: close)
                if afterClose < text.endIndex, text[afterClose] == "(",
                   let end = text[afterClose...].firstIndex(of: ")") {
                    flushPlain(until: cursor)
                    let labelStart = text.index(after: cursor)
                    let label = String(text[labelStart..<close])
                    let targetStart = text.index(after: afterClose)
                    let target = String(text[targetStart..<end])
                    var linkAttributes = merging(attributes, [
                        .foregroundColor: style.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ])
                    if let url = safeLinkURL(target) {
                        linkAttributes[.link] = url
                    }
                    result.append(NSAttributedString(
                        string: label.isEmpty ? target : label,
                        attributes: linkAttributes
                    ))
                    cursor = text.index(after: end)
                    plainStart = cursor
                    continue
                }
            }

            if remainder.hasPrefix("**") || remainder.hasPrefix("__") {
                let delimiter = String(remainder.prefix(2))
                let contentStart = text.index(cursor, offsetBy: 2)
                if let closing = text.range(
                    of: delimiter,
                    range: contentStart..<text.endIndex
                ) {
                    flushPlain(until: cursor)
                    let font = (attributes[.font] as? NSFont) ?? bodyFont
                    let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    result.append(NSAttributedString(
                        string: String(text[contentStart..<closing.lowerBound]),
                        attributes: merging(attributes, [.font: bold])
                    ))
                    cursor = closing.upperBound
                    plainStart = cursor
                    continue
                }
            }

            if remainder.hasPrefix("`") {
                let contentStart = text.index(after: cursor)
                if let closing = text[contentStart...].firstIndex(of: "`") {
                    flushPlain(until: cursor)
                    result.append(NSAttributedString(
                        string: String(text[contentStart..<closing]),
                        attributes: merging(attributes, [
                            .font: codeFont,
                            .foregroundColor: style.codeTextColor,
                            .backgroundColor: style.codeBackgroundColor,
                        ])
                    ))
                    cursor = text.index(after: closing)
                    plainStart = cursor
                    continue
                }
            }

            if remainder.hasPrefix("*") || remainder.hasPrefix("_") {
                let delimiter = text[cursor]
                let contentStart = text.index(after: cursor)
                if let closing = text[contentStart...].firstIndex(of: delimiter) {
                    flushPlain(until: cursor)
                    let font = (attributes[.font] as? NSFont) ?? bodyFont
                    let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    result.append(NSAttributedString(
                        string: String(text[contentStart..<closing]),
                        attributes: merging(attributes, [.font: italic])
                    ))
                    cursor = text.index(after: closing)
                    plainStart = cursor
                    continue
                }
            }

            cursor = text.index(after: cursor)
        }
        flushPlain(until: text.endIndex)
    }

    private static func safeLinkURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }

    private static func markdownPreviewText(_ text: String) -> String {
        var output = normalizedNewlines(text)
        output = output.replacingOccurrences(
            of: #"(?m)^\s{0,3}(?:#{1,6}|>|[-+*]|\d+[.)])\s*"#,
            with: "",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"!\[([^\]]*)\]\([^)]*\)"#,
            with: "$1",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]*\)"#,
            with: "$1",
            options: .regularExpression
        )
        for token in ["```", "~~~", "**", "__", "`"] {
            output = output.replacingOccurrences(of: token, with: "")
        }
        return output
    }

    private static func markdownHeading(_ text: String) -> (level: Int, text: String)? {
        let hashes = text.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), text.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(text.dropFirst(hashes + 1)))
    }

    private static func markdownQuote(_ text: String) -> String? {
        guard text.hasPrefix(">") else { return nil }
        return String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static func markdownListItem(_ text: String) -> (prefix: String, text: String)? {
        for marker in ["- ", "* ", "+ "] where text.hasPrefix(marker) {
            return ("•  ", String(text.dropFirst(marker.count)))
        }

        let digits = text.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let suffix = text.dropFirst(digits.count)
        guard suffix.hasPrefix(". ") || suffix.hasPrefix(") ") else { return nil }
        return ("\(digits).  ", String(suffix.dropFirst(2)))
    }

    private static func isHorizontalRule(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first,
              ["-", "*", "_"].contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isMarkdownBlockStart(_ text: String) -> Bool {
        text.hasPrefix("```")
            || text.hasPrefix("~~~")
            || markdownHeading(text) != nil
            || markdownQuote(text) != nil
            || markdownListItem(text) != nil
            || isHorizontalRule(text)
    }

    private static func appendParagraphBreak(to result: NSMutableAttributedString) {
        guard result.length > 0, !result.string.hasSuffix("\n\n") else { return }
        let paragraph = paragraphStyle(lineSpacing: 0, paragraphSpacing: 0)
        appendLineBreak(to: result, paragraphStyle: paragraph)
    }

    private static func appendLineBreak(to result: NSMutableAttributedString,
                                        paragraphStyle: NSParagraphStyle,
                                        background: NSColor? = nil) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .paragraphStyle: paragraphStyle,
        ]
        if let background { attributes[.backgroundColor] = background }
        result.append(NSAttributedString(string: "\n", attributes: attributes))
    }

    private static func paragraphStyle(lineSpacing: CGFloat,
                                       paragraphSpacing: CGFloat,
                                       headIndent: CGFloat = 0,
                                       firstLineHeadIndent: CGFloat = 0,
                                       tailIndent: CGFloat = 0) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacing = paragraphSpacing
        paragraph.minimumLineHeight = 18
        paragraph.maximumLineHeight = 18
        paragraph.headIndent = headIndent
        paragraph.firstLineHeadIndent = firstLineHeadIndent
        paragraph.tailIndent = tailIndent
        paragraph.lineBreakMode = .byWordWrapping
        return paragraph
    }

    private static func merging(_ base: [NSAttributedString.Key: Any],
                                _ additions: [NSAttributedString.Key: Any])
        -> [NSAttributedString.Key: Any] {
        var result = base
        additions.forEach { result[$0.key] = $0.value }
        return result
    }
}

/// NSTextView provides selection, links, Unicode shaping, and attributed text
/// without giving up Auto Layout. Its height follows the laid-out glyphs at
/// the width assigned by the transcript content column.
final class MailboxMessageTextView: NSTextView {
    private let preferredTextWidth: CGFloat
    private var measuredWidth: CGFloat = 0

    init(presentation: MailboxBodyPresentation) {
        let preferredWidth = Self.preferredWidth(for: presentation.attributedText)
        preferredTextWidth = preferredWidth
        let storage = NSTextStorage(attributedString: presentation.attributedText)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            containerSize: NSSize(width: preferredWidth, height: .greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        super.init(
            frame: NSRect(x: 0, y: 0, width: preferredWidth, height: 20),
            textContainer: container
        )

        drawsBackground = false
        backgroundColor = .clear
        isEditable = false
        isSelectable = true
        isRichText = true
        importsGraphics = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isHorizontallyResizable = false
        isVerticallyResizable = true
        textContainerInset = .zero
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        linkTextAttributes = [
            .foregroundColor: presentation.linkTextColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// NSTextView reports a zero first-baseline offset by default, which makes
    /// baseline constraints align neighboring labels with the top edge rather
    /// than the first rendered line. Expose the layout manager's real first
    /// glyph baseline so the terminal time/source/prompt columns line up with
    /// the message text for Plain, Markdown, JSON, and preformatted bodies.
    override var firstBaselineOffsetFromTop: CGFloat {
        guard string.isEmpty == false,
              let textContainer,
              let layoutManager else {
            return super.firstBaselineOffsetFromTop
        }
        layoutManager.ensureLayout(for: textContainer)
        guard layoutManager.numberOfGlyphs > 0 else {
            return super.firstBaselineOffsetFromTop
        }
        let firstGlyph = layoutManager.glyphIndexForCharacter(at: 0)
        return textContainerInset.height
            + layoutManager.location(forGlyphAt: firstGlyph).y
    }

    override var intrinsicContentSize: NSSize {
        let width = max(1, bounds.width > 1 ? bounds.width : preferredTextWidth)
        guard let textContainer, let layoutManager else {
            return NSSize(width: preferredTextWidth, height: 18)
        }
        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: max(18, ceil(used.height + textContainerInset.height * 2))
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - measuredWidth) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            measuredWidth = newSize.width
            invalidateIntrinsicContentSize()
        }
    }

    private static func preferredWidth(for attributedText: NSAttributedString) -> CGFloat {
        guard attributedText.length > 0 else { return 130 }
        let measured = attributedText.boundingRect(
            with: NSSize(width: 620, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return min(620, max(130, ceil(measured.width + 1)))
    }
}
