import Cocoa

enum MailboxToastStoreAction: Equatable {
    case present(threadID: UUID)
    case dismiss
    case keep
}

enum MailboxToastStateRules {
    /// Completion is a delivery receipt, not an unread-state projection. A
    /// visible Mailbox pane can mark the thread read immediately after the
    /// completion event; that must not suppress or retract its notification.
    static func action(for change: MailboxStoreChange,
                       targetThreadID: UUID?,
                       snapshot: MailboxStoreSnapshot)
        -> MailboxToastStoreAction {
        switch change {
        case let .completedMessage(threadID):
            guard snapshot.thread(id: threadID) != nil else { return .keep }
            return .present(threadID: threadID)
        case .contentChanged:
            guard let targetThreadID else { return .keep }
            return snapshot.thread(id: targetThreadID) == nil ? .dismiss : .keep
        case .initial, .generationProgressed, .generationFailed,
             .unreadChanged, .selectionChanged:
            return .keep
        }
    }

    static func completionLabel(threadID: UUID,
                                snapshot: MailboxStoreSnapshot) -> String {
        guard let thread = snapshot.thread(id: threadID) else {
            return "Mailbox 收到新消息 · 点击查看"
        }
        if snapshot.unreadCount > 1 {
            return "Mailbox 有 \(snapshot.unreadCount) 条新消息 · 点击查看"
        }
        if thread.source.kind.isAIConnector {
            return "\(thread.source.displayName) 已回复 · 点击查看"
        }
        return "\(thread.source.displayName) 发来新消息 · 点击查看"
    }
}

/// Non-activating Mailbox completion notification. It may observe transient
/// generation-progress events, but only committed completion events can
/// surface as a finished-message toast.
final class InboundToast: NSObject {
    static let shared = InboundToast()

    private var panel: NSPanel?
    private weak var toastButton: NSButton?
    private weak var accentDot: NSView?
    private let countLabel = NSTextField(labelWithString: "")
    private var hideTimer: Timer?
    private var appearanceObserver: NSObjectProtocol?
    private var storeObservation: MailboxStoreObservation?
    private var targetThreadID: UUID?

    private override init() {
        super.init()
        storeObservation = MailboxStore.shared.observe(deliverInitial: false) { [weak self] event in
            guard let self else { return }
            switch MailboxToastStateRules.action(
                for: event.change,
                targetThreadID: self.targetThreadID,
                snapshot: event.snapshot
            ) {
            case let .present(threadID):
                // MailboxStore delivers observers on the main thread. Present
                // synchronously so a pane's deferred markRead cannot win the
                // completion-to-toast race.
                self.presentCompletedMessage(
                    threadID: threadID,
                    snapshot: event.snapshot
                )
            case .dismiss:
                self.hide(reason: "target-removed")
            case .keep:
                break
            }
        }
    }

    deinit {
        storeObservation?.cancel()
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }

    /// Compatibility with the old InboundBus launch wiring. Raw pending-count
    /// changes intentionally do nothing; main now only needs to retain/access
    /// the singleton until its wiring is migrated to MailboxStore directly.
    func update(pendingCount: Int, trayVisible: Bool) {
        _ = pendingCount
        _ = trayVisible
    }

    func hide() {
        hide(reason: "requested")
    }

    private func hide(reason: String) {
        hideTimer?.invalidate()
        hideTimer = nil
        panel?.orderOut(nil)
        if targetThreadID != nil {
            IMELog.write("mailbox toast hidden reason=\(reason)")
        }
        targetThreadID = nil
    }

    private func presentCompletedMessage(
        threadID: UUID,
        snapshot: MailboxStoreSnapshot
    ) {
        guard let thread = snapshot.thread(id: threadID) else {
            IMELog.write("mailbox toast skipped reason=missing-thread")
            return
        }
        targetThreadID = threadID
        countLabel.stringValue = MailboxToastStateRules.completionLabel(
            threadID: threadID,
            snapshot: snapshot
        )
        show()
        IMELog.write(
            "mailbox toast shown sourceKind=\(thread.source.kind.rawValue) unreadCount=\(snapshot.unreadCount)"
        )
    }

    private func show() {
        if panel == nil { build() }
        applyAppearance()
        position()
        panel?.orderFrontRegardless()
        hideTimer?.invalidate()
        let timer = Timer(timeInterval: 8, repeats: false) { [weak self] _ in
            self?.hide(reason: "timeout")
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private func build() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 292, height: 48),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        // AppKit may reset a panel's level when `isFloatingPanel` changes.
        // Assign the notification level afterwards so it stays above the
        // current host and an already-open Mailbox window.
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.worksWhenModal = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.appearance = RimeUI.appKitAppearance

        let button = MailboxToastButton()
        button.title = ""
        button.isBordered = false
        button.target = self
        button.action = #selector(openMailbox)
        button.wantsLayer = true
        button.layer?.cornerRadius = 10
        button.layer?.borderWidth = 1
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityLabel("打开 Mailbox 查看新消息")
        toastButton = button

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        accentDot = dot

        countLabel.font = .systemFont(ofSize: 12, weight: .medium)
        countLabel.lineBreakMode = .byTruncatingTail
        let chevron = NSImageView()
        chevron.image = RimeUI.symbol("chevron.right", pointSize: 10, weight: .semibold)
        chevron.contentTintColor = RimeUI.textMuted

        let row = NSStackView(views: [dot, countLabel, chevron])
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])

        let content = NSView()
        content.addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            button.topAnchor.constraint(equalTo: content.topAnchor),
            button.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        p.contentView = content
        panel = p

        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .rimeAppearanceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
        }
    }

    private func applyAppearance() {
        panel?.appearance = RimeUI.appKitAppearance
        toastButton?.layer?.backgroundColor = RimeUI.surface2.cgColor
        toastButton?.layer?.borderColor = RimeUI.border.cgColor
        accentDot?.layer?.backgroundColor = RimeUI.accentGreen.cgColor
        countLabel.textColor = RimeUI.textPrimary
        toastButton?.needsDisplay = true
    }

    private func position() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: {
            NSMouseInRect(mouseLocation, $0.frame, false)
        }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let panel, let screen else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - size.width - 16,
            y: frame.maxY - size.height - 16
        ))
    }

    @objc private func openMailbox() {
        let threadID = targetThreadID
        hide(reason: "opened")
        MailboxWindowController.shared.show(selecting: threadID)
    }

    /// Receives clicks without activating the toast panel itself. Only opening
    /// the real Mailbox window activates RIMES and makes an editable key window.
    private final class MailboxToastButton: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

typealias MailboxNotificationToast = InboundToast

func runMailboxToastSmokeTest() -> Bool {
    let threadID = UUID()
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func snapshot(unread: Bool, includesThread: Bool = true)
        -> MailboxStoreSnapshot {
        let threads: [MailboxThread]
        if includesThread {
            threads = [MailboxThread(
                id: threadID,
                sequence: 1,
                title: nil,
                source: .codexCLI(model: "smoke"),
                messages: [MailboxMessage(
                    role: .inbound,
                    author: "Codex",
                    body: "complete",
                    createdAt: now
                )],
                generation: nil,
                unread: unread,
                createdAt: now,
                updatedAt: now
            )]
        } else {
            threads = []
        }
        return MailboxStoreSnapshot(
            revision: 1,
            threads: threads,
            selectedThreadID: includesThread ? threadID : nil,
            persistence: .available
        )
    }

    let alreadyRead = snapshot(unread: false)
    guard MailboxToastStateRules.action(
        for: .completedMessage(threadID: threadID),
        targetThreadID: nil,
        snapshot: alreadyRead
    ) == .present(threadID: threadID) else {
        fputs("mailbox-toast-smoke: read race suppressed completion\n", stderr)
        return false
    }
    guard MailboxToastStateRules.action(
        for: .unreadChanged,
        targetThreadID: threadID,
        snapshot: alreadyRead
    ) == .keep else {
        fputs("mailbox-toast-smoke: mark-read retracted receipt\n", stderr)
        return false
    }
    guard MailboxToastStateRules.action(
        for: .generationProgressed(threadID: threadID),
        targetThreadID: nil,
        snapshot: alreadyRead
    ) == .keep else {
        fputs("mailbox-toast-smoke: streaming preview created receipt\n", stderr)
        return false
    }
    guard MailboxToastStateRules.action(
        for: .contentChanged,
        targetThreadID: threadID,
        snapshot: alreadyRead
    ) == .keep else {
        fputs("mailbox-toast-smoke: retained thread dismissed receipt\n", stderr)
        return false
    }
    guard MailboxToastStateRules.action(
        for: .contentChanged,
        targetThreadID: threadID,
        snapshot: snapshot(unread: false, includesThread: false)
    ) == .dismiss else {
        fputs("mailbox-toast-smoke: removed target left stale receipt\n", stderr)
        return false
    }
    let label = MailboxToastStateRules.completionLabel(
        threadID: threadID,
        snapshot: alreadyRead
    )
    guard label == "Codex 已回复 · 点击查看" else {
        fputs("mailbox-toast-smoke: completion label mismatch\n", stderr)
        return false
    }

    print("mailbox-toast-smoke: ok")
    return true
}
