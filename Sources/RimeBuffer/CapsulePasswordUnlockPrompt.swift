import AppKit

private final class CapsuleUnlockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CapsuleUnlockCancelButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Passive prompt: the external text client keeps keyboard focus so the IME
/// can own the short authorization gesture without ever placing a secret in an
/// AppKit text field, pasteboard or ordinary Buffer delivery block.
final class CapsulePasswordUnlockPromptController: NSObject {
    static let shared = CapsulePasswordUnlockPromptController()

    private let panel: CapsuleUnlockPanel
    private let visual = NSVisualEffectView()
    private let progressLabel = NSTextField(labelWithString: "")
    private let cancelButton = CapsuleUnlockCancelButton(
        title: "取消",
        target: nil,
        action: nil
    )
    private var onCancel: (() -> Void)?

    override init() {
        panel = CapsuleUnlockPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 118),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        build()
    }

    var isVisible: Bool { panel.isVisible }

    func present(progress: Int,
                 stepCount: Int,
                 anchorFrame: NSRect,
                 level: NSWindow.Level,
                 onCancel: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.onCancel = onCancel
        updateProgress(progress, stepCount: stepCount)
        panel.level = NSWindow.Level(rawValue: level.rawValue + 1)
        panel.appearance = RimeUI.appKitAppearance
        position(relativeTo: anchorFrame)
        panel.orderFrontRegardless()
    }

    func dismiss() {
        dispatchPrecondition(condition: .onQueue(.main))
        onCancel = nil
        panel.orderOut(nil)
    }

    private func build() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        visual.material = .popover
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 13
        visual.layer?.masksToBounds = true
        visual.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "输入访问密钥")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.alignment = .center

        let detail = NSTextField(
            labelWithString: "完成本地验证后自动上屏"
        )
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center

        progressLabel.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        progressLabel.alignment = .center
        progressLabel.textColor = RimeUI.accentTextColor
        progressLabel.setAccessibilityLabel("访问密钥输入进度")

        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.bezelStyle = .inline
        cancelButton.controlSize = .small
        cancelButton.focusRingType = .none
        cancelButton.setAccessibilityLabel("取消访问密钥输入")

        let stack = NSStackView(
            views: [title, detail, progressLabel, cancelButton]
        )
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(visual)
        visual.addSubview(stack)
        panel.contentView = content
        NSLayoutConstraint.activate([
            visual.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            visual.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            visual.topAnchor.constraint(equalTo: content.topAnchor),
            visual.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: visual.leadingAnchor,
                                           constant: 20),
            stack.trailingAnchor.constraint(equalTo: visual.trailingAnchor,
                                            constant: -20),
            stack.centerYAnchor.constraint(equalTo: visual.centerYAnchor),
        ])
    }

    private func updateProgress(_ progress: Int, stepCount: Int) {
        let boundedCount = max(stepCount, 1)
        let boundedProgress = min(max(progress, 0), boundedCount)
        progressLabel.stringValue = (0..<boundedCount).map {
            $0 < boundedProgress ? "●" : "○"
        }.joined(separator: "  ")
        progressLabel.setAccessibilityValue(
            "已完成 \(boundedProgress) / \(boundedCount)"
        )
    }

    private func position(relativeTo anchor: NSRect) {
        let visible = NSScreen.screens.first(where: {
            $0.visibleFrame.intersects(anchor)
        })?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        var x = anchor.midX - size.width / 2
        var y = anchor.maxY + 10
        if y + size.height > visible.maxY {
            y = anchor.minY - size.height - 10
        }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func cancelTapped() {
        let callback = onCancel
        dismiss()
        callback?()
    }
}
