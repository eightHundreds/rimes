import AppKit
import CryptoKit
import Foundation

extension Notification.Name {
    static let capsuleStoreDidChange = Notification.Name(
        "CapsuleStoreDidChange"
    )
}

enum CapsuleWindowToggleAction: Equatable {
    case show
    case close
}

enum CapsuleWindowVisibilityRules {
    static func action(isVisible: Bool) -> CapsuleWindowToggleAction {
        isVisible ? .close : .show
    }

    /// Keep the shortcut/menu toggle on the same AppKit close route as the
    /// title-bar close button. `NSWindow.close()` skips `windowShouldClose(_:)`
    /// and would therefore discard a Capsule draft without confirmation.
    static func perform(
        _ action: CapsuleWindowToggleAction,
        show: () -> Void,
        performClose: () -> Void
    ) {
        switch action {
        case .show:
            show()
        case .close:
            performClose()
        }
    }
}

enum CapsuleWindowSelectionRules {
    /// A password row is never decrypted just because its type became visible.
    /// Only a user-selected row, or a refresh of that already-selected ID, may
    /// enter the password editor.
    static func allowsAutomaticFirstSelection(
        kind: CapsuleEntryKind
    ) -> Bool {
        kind != .password
    }
}

struct CapsulePaneLayoutSnapshot {
    let subtitleToTabsGap: CGFloat
    let formTopGap: CGFloat
    let tabsTop: CGFloat
    let editorTop: CGFloat
    let kindControlFrame: NSRect
    let editorFrame: NSRect
    let hasAmbiguousLayout: Bool
}

struct CapsulePasswordEditorSnapshot: Equatable {
    let revealButtonTitle: String
    let urlUsesSecureControl: Bool
    let appUsesSecureControl: Bool
    let usernameUsesSecureControl: Bool
    let passwordUsesSecureControl: Bool
    let previousPasswordsUseSecureControls: Bool
    let plaintextAllowsSelection: Bool
    let plaintextIsAccessibilityElement: Bool
    let plaintextHasToolTip: Bool
    let hasUnsavedChanges: Bool
}

/// Password details remain outside list/search projections. A row is safe to
/// render, log in a smoke failure, or expose as an accessibility label.
struct CapsuleWindowEntryRow: Equatable, Identifiable {
    let id: UUID
    let kind: CapsuleEntryKind
    let title: String
    let preview: String
    let updatedAt: Date
    let revision: String
    let fileURL: URL

    var accessibilitySummary: String {
        if kind == .password {
            return "Password · \(title) · 已脱敏"
        }
        return "\(kind.displayName) · \(title) · \(preview)"
    }
}

enum CapsulePasswordEditorField: CaseIterable {
    case title
    case url
    case app
    case username
    case password
    case previousPassword
}

enum CapsulePasswordEditorSecurityPolicy {
    static let revealDuration: TimeInterval = 15

    static func mayReveal(_ field: CapsulePasswordEditorField) -> Bool {
        field == .password || field == .previousPassword
    }

    static func usesSecureControl(
        _ field: CapsulePasswordEditorField,
        plaintextVisible: Bool = false
    ) -> Bool {
        switch field {
        case .title:
            return false
        case .url, .app, .username:
            return true
        case .password, .previousPassword:
            return !plaintextVisible
        }
    }
}

struct CapsulePasswordRevealState: Equatable {
    private(set) var concealAt: Date?

    var isPlaintextVisible: Bool { concealAt != nil }

    func remainingDuration(now: Date) -> TimeInterval? {
        concealAt.map { max(0, $0.timeIntervalSince(now)) }
    }

    mutating func reveal(now: Date) {
        concealAt = now.addingTimeInterval(
            CapsulePasswordEditorSecurityPolicy.revealDuration
        )
    }

    mutating func conceal() {
        concealAt = nil
    }

    @discardableResult
    mutating func concealIfExpired(now: Date) -> Bool {
        guard let concealAt, now >= concealAt else { return false }
        self.concealAt = nil
        return true
    }
}

enum CapsuleWindowDraftError: LocalizedError, Equatable {
    case missingTitle
    case missingContent
    case missingPassword
    case relativeSkillPath

    var errorDescription: String? {
        switch self {
        case .missingTitle:
            return "请填写标题"
        case .missingContent:
            return "请填写内容"
        case .missingPassword:
            return "请填写密码"
        case .relativeSkillPath:
            return "Skill 必须使用电脑中的绝对路径"
        }
    }
}

enum CapsuleWindowRepositoryError: LocalizedError, Equatable {
    case staleRecord

    var errorDescription: String? {
        switch self {
        case .staleRecord:
            return "该条目已在另一窗口或 Obsidian 中更新；请重新载入后再编辑"
        }
    }
}

struct CapsuleWindowDraft: Equatable {
    var id: UUID?
    var kind: CapsuleEntryKind
    var title: String
    var content: String
    var url: String
    var app: String
    var username: String
    var password: String
    var previousPasswords: [String]
    var loadedRevision: String?

    init(id: UUID? = nil,
         kind: CapsuleEntryKind,
         title: String,
         content: String,
         url: String,
         app: String,
         username: String,
         password: String,
         previousPasswords: [String],
         loadedRevision: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.content = content
        self.url = url
        self.app = app
        self.username = username
        self.password = password
        self.previousPasswords = previousPasswords
        self.loadedRevision = loadedRevision
    }

    static func empty(kind: CapsuleEntryKind) -> CapsuleWindowDraft {
        CapsuleWindowDraft(
            id: nil,
            kind: kind,
            title: "",
            content: "",
            url: "",
            app: "",
            username: "",
            password: "",
            previousPasswords: [],
            loadedRevision: nil
        )
    }

    func validated() throws -> CapsuleWindowDraft {
        var normalized = self
        normalized.title = title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.title.isEmpty else {
            throw CapsuleWindowDraftError.missingTitle
        }
        switch kind {
        case .prompt, .memory:
            guard !content.isEmpty else {
                throw CapsuleWindowDraftError.missingContent
            }
        case .skill:
            guard !content.isEmpty else {
                throw CapsuleWindowDraftError.missingContent
            }
            guard NSString(string: content).isAbsolutePath else {
                throw CapsuleWindowDraftError.relativeSkillPath
            }
        case .password:
            guard !password.isEmpty else {
                throw CapsuleWindowDraftError.missingPassword
            }
            guard previousPasswords.allSatisfy({ !$0.isEmpty }) else {
                throw CapsuleWindowDraftError.missingPassword
            }
        }
        return normalized
    }
}

/// Synchronous local repository used only by the explicit management window.
/// It deliberately has no dependency on BufferModel or Delivery.
final class CapsuleWindowRepository {
    private let contentStore: CapsuleContentStore
    private let passwordStore: CapsulePasswordStore

    init(contentStore: CapsuleContentStore = .shared,
         passwordStore: CapsulePasswordStore = .shared) {
        self.contentStore = contentStore
        self.passwordStore = passwordStore
    }

    func list(kind: CapsuleEntryKind, query: String = "") throws
        -> [CapsuleWindowEntryRow] {
        let terms = Self.searchTerms(query)
        switch kind {
        case .password:
            return try passwordStore.listSummaries().filter { summary in
                Self.matches(terms: terms, text: summary.title)
            }.map { summary in
                CapsuleWindowEntryRow(
                    id: summary.id,
                    kind: .password,
                    title: summary.title,
                    preview: summary.maskedPassword,
                    updatedAt: summary.updatedAt,
                    revision: try Self.fileRevision(summary.fileURL),
                    fileURL: summary.fileURL
                )
            }
        case .prompt, .memory, .skill:
            return try contentStore.listRecords().filter { record in
                record.summary.type == kind
                    && Self.matches(
                        terms: terms,
                        text: record.summary.title + "\n" + record.content
                    )
            }.map { record in
                CapsuleWindowEntryRow(
                    id: record.summary.id,
                    kind: record.summary.type,
                    title: record.summary.title,
                    preview: record.snippet,
                    updatedAt: record.summary.updatedAt,
                    revision: try Self.fileRevision(record.summary.fileURL),
                    fileURL: record.summary.fileURL
                )
            }
        }
    }

    func draft(for row: CapsuleWindowEntryRow) throws -> CapsuleWindowDraft {
        switch row.kind {
        case .password:
            let before = try Self.fileRevision(row.fileURL)
            let record = try passwordStore.record(id: row.id)
            let after = try Self.fileRevision(record.summary.fileURL)
            guard before == after else {
                throw CapsuleWindowRepositoryError.staleRecord
            }
            return CapsuleWindowDraft(
                id: record.summary.id,
                kind: .password,
                title: record.summary.title,
                content: "",
                url: record.secret.url ?? "",
                app: record.secret.app ?? "",
                username: record.secret.username ?? "",
                password: record.secret.password,
                previousPasswords: record.secret.previousPasswords,
                loadedRevision: after
            )
        case .prompt, .memory, .skill:
            let before = try Self.fileRevision(row.fileURL)
            let record = try contentStore.record(id: row.id)
            let after = try Self.fileRevision(record.summary.fileURL)
            guard record.summary.type == row.kind else {
                throw CapsuleContentStoreError.recordNotFound
            }
            guard before == after else {
                throw CapsuleWindowRepositoryError.staleRecord
            }
            return CapsuleWindowDraft(
                id: record.summary.id,
                kind: record.summary.type,
                title: record.summary.title,
                content: record.content,
                url: "",
                app: "",
                username: "",
                password: "",
                previousPasswords: [],
                loadedRevision: after
            )
        }
    }

    @discardableResult
    func save(_ draft: CapsuleWindowDraft) throws -> CapsuleWindowEntryRow {
        let draft = try draft.validated()
        if draft.id != nil, draft.loadedRevision == nil {
            throw CapsuleWindowRepositoryError.staleRecord
        }
        let row: CapsuleWindowEntryRow
        switch draft.kind {
        case .password:
            let summary: CapsulePasswordSummary
            do {
                summary = try passwordStore.put(
                    CapsulePasswordWriteRequest(
                        id: draft.id,
                        title: draft.title,
                        url: draft.url,
                        app: draft.app,
                        username: draft.username,
                        password: draft.password,
                        previousPasswords: draft.previousPasswords
                    ),
                    expectedRevision: draft.loadedRevision
                )
            } catch CapsulePasswordStoreError.revisionConflict {
                throw CapsuleWindowRepositoryError.staleRecord
            }
            row = CapsuleWindowEntryRow(
                id: summary.id,
                kind: .password,
                title: summary.title,
                preview: summary.maskedPassword,
                updatedAt: summary.updatedAt,
                revision: try Self.fileRevision(summary.fileURL),
                fileURL: summary.fileURL
            )
        case .prompt, .memory, .skill:
            let summary: CapsuleContentSummary
            do {
                summary = try contentStore.put(
                    CapsuleContentWriteRequest(
                        id: draft.id,
                        type: draft.kind,
                        title: draft.title,
                        content: draft.content
                    ),
                    expectedRevision: draft.loadedRevision
                )
            } catch CapsuleContentStoreError.revisionConflict {
                throw CapsuleWindowRepositoryError.staleRecord
            }
            let record = try contentStore.record(id: summary.id)
            row = CapsuleWindowEntryRow(
                id: summary.id,
                kind: summary.type,
                title: summary.title,
                preview: record.snippet,
                updatedAt: summary.updatedAt,
                revision: try Self.fileRevision(summary.fileURL),
                fileURL: summary.fileURL
            )
        }
        publishChange()
        return row
    }

    func remove(_ row: CapsuleWindowEntryRow,
                expectedRevision: String?) throws {
        guard let expectedRevision else {
            throw CapsuleWindowRepositoryError.staleRecord
        }
        do {
            switch row.kind {
            case .password:
                try passwordStore.remove(
                    id: row.id,
                    expectedRevision: expectedRevision
                )
            case .prompt, .memory, .skill:
                try contentStore.remove(
                    id: row.id,
                    expectedRevision: expectedRevision
                )
            }
        } catch CapsulePasswordStoreError.revisionConflict {
            throw CapsuleWindowRepositoryError.staleRecord
        } catch CapsuleContentStoreError.revisionConflict {
            throw CapsuleWindowRepositoryError.staleRecord
        }
        publishChange()
    }

    private static func fileRevision(_ fileURL: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw CapsuleWindowRepositoryError.staleRecord
        }
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func publishChange() {
        let publish = { [self] in
            NotificationCenter.default.post(
                name: .capsuleStoreDidChange,
                object: self
            )
        }
        if Thread.isMainThread {
            publish()
        } else {
            DispatchQueue.main.async(execute: publish)
        }
    }

    private static func searchTerms(_ query: String) -> [String] {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
    }

    private static func matches(terms: [String], text: String) -> Bool {
        guard !terms.isEmpty else { return true }
        let text = text.lowercased()
        return terms.allSatisfy(text.contains)
    }
}

/// Standalone, key-capable Capsule manager. This window owns CRUD only; it is
/// never an implicit Buffer destination and never performs paste/AX delivery.
final class CapsuleWindowController: NSObject, NSWindowDelegate {
    static let shared = CapsuleWindowController()

    private static let frameAutosaveName = "RIMES.CapsuleWindow"

    private var window: NSWindow?
    private var contentController: CapsulePaneViewController?
    private var appearanceObserver: NSObjectProtocol?

    deinit {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }

    static var isVisible: Bool { shared.window?.isVisible == true }

    /// Input/focus routing may use this to reject the management window as a
    /// host delivery target while still letting AppKit fields become key.
    static var isKeyAndVisible: Bool {
        shared.window?.isVisible == true && shared.window?.isKeyWindow == true
    }

    @discardableResult
    func toggleVisibility() -> CapsuleWindowToggleAction {
        let action = CapsuleWindowVisibilityRules.action(
            isVisible: window?.isVisible == true
        )
        CapsuleWindowVisibilityRules.perform(
            action,
            show: { [weak self] in self?.show() },
            performClose: { [weak self] in self?.window?.performClose(nil) }
        )
        return action
    }

    func show() {
        if window == nil { build() }
        applyAppearance()
        contentController?.reloadFromStore()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.contentController?.windowBecameKey()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        contentController?.windowBecameKey()
    }

    func windowDidResignKey(_ notification: Notification) {
        contentController?.concealPasswordPlaintext()
    }

    func windowWillClose(_ notification: Notification) {
        contentController?.discardEditorForClose()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        contentController?.concealPasswordPlaintext()
        return contentController?.confirmDiscardChangesIfNeeded() ?? true
    }

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RIMES Capsule"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 560)
        window.appearance = RimeUI.appKitAppearance
        window.animationBehavior = .documentWindow
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self

        let contentController = CapsulePaneViewController()
        window.contentViewController = contentController

        let restored = window.setFrameUsingName(Self.frameAutosaveName)
        _ = window.setFrameAutosaveName(Self.frameAutosaveName)
        if !restored { window.center() }

        self.window = window
        self.contentController = contentController
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .rimeAppearanceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
        }
    }

    private func applyAppearance() {
        window?.appearance = RimeUI.appKitAppearance
        contentController?.applyAppearance()
    }
}

/// Reusable Capsule management surface. Settings and the standalone window
/// each create their own view instance while sharing the same local stores.
final class CapsulePaneViewController: NSViewController,
                                       NSTableViewDataSource,
                                       NSTableViewDelegate,
                                       NSTextFieldDelegate,
                                       NSTextViewDelegate {
    private static let searchDebounce: TimeInterval = 0.150

    private let repository: CapsuleWindowRepository
    private let reloadQueue = DispatchQueue(
        label: "RIMES.CapsuleWindow.reload",
        qos: .userInitiated
    )

    private let titleLabel = NSTextField(labelWithString: "$ rimes capsule")
    private let subtitleLabel = NSTextField(
        labelWithString: "local knowledge manager · Markdown + encrypted secrets"
    )
    private lazy var kindControl = RimePointingHandSegmentedControl(
        labels: CapsuleEntryKind.allCases.map(\.displayName),
        trackingMode: .selectOne,
        target: self,
        action: #selector(kindChanged)
    )
    private let searchField = NSSearchField()
    private let newButton = RimePointingHandButton(
        title: "＋ 新建",
        target: nil,
        action: nil
    )
    private let tableView = NSTableView()
    private let listScrollView = NSScrollView()
    private let listContainer = NSView()
    private let editorContainer = NSView()
    private let editorScrollView = NSScrollView()
    private let formStack = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = RimePointingHandButton(
        title: "保存",
        target: nil,
        action: nil
    )
    private let deleteButton = RimePointingHandButton(
        title: "删除",
        target: nil,
        action: nil
    )

    private var rows: [CapsuleWindowEntryRow] = []
    private var selectedKind: CapsuleEntryKind = .memory
    private var draft = CapsuleWindowDraft.empty(kind: .memory)
    private var titleField: NSTextField?
    private var contentTextView: NSTextView?
    private var skillPathField: NSTextField?
    private var passwordURLField: NSSecureTextField?
    private var passwordAppField: NSSecureTextField?
    private var passwordUsernameField: NSSecureTextField?
    private var passwordField: NSTextField?
    private var previousPasswordFields: [NSTextField] = []
    private var passwordRevealButton: NSButton?
    private var passwordRevealState = CapsulePasswordRevealState()
    private var passwordRevealTimer: Timer?
    private var searchReloadTimer: Timer?
    private var reloadGeneration: UInt64 = 0
    private var applyingSelection = false
    private var editorDirty = false
    private var storeObserver: NSObjectProtocol?
    private var applicationPrivacyObservers: [NSObjectProtocol] = []
    private var workspacePrivacyObservers: [NSObjectProtocol] = []
    private var distributedPrivacyObservers: [NSObjectProtocol] = []

    init(repository: CapsuleWindowRepository = CapsuleWindowRepository()) {
        self.repository = repository
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        searchReloadTimer?.invalidate()
        passwordRevealTimer?.invalidate()
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
        }
        let center = NotificationCenter.default
        applicationPrivacyObservers.forEach(center.removeObserver)
        let workspace = NSWorkspace.shared.notificationCenter
        workspacePrivacyObservers.forEach(workspace.removeObserver)
        let distributed = DistributedNotificationCenter.default()
        distributedPrivacyObservers.forEach(distributed.removeObserver)
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        titleLabel.font = MailboxTerminalTypography.font(
            ofSize: 15,
            weight: .semibold
        )
        subtitleLabel.font = MailboxTerminalTypography.font(ofSize: 10)
        let heading = NSStackView(views: [titleLabel, subtitleLabel])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 2

        kindControl.selectedSegment = CapsuleEntryKind.allCases.firstIndex(
            of: selectedKind
        ) ?? 0
        kindControl.font = MailboxTerminalTypography.font(
            ofSize: 10,
            weight: .semibold
        )
        kindControl.setAccessibilityLabel("Capsule 类型")

        searchField.placeholderString = "搜索标题或内容"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.font = MailboxTerminalTypography.font(ofSize: 11)
        searchField.setAccessibilityLabel("搜索 Capsule")

        newButton.target = self
        newButton.action = #selector(createNew)
        newButton.bezelStyle = .rounded
        newButton.font = MailboxTerminalTypography.font(
            ofSize: 10,
            weight: .semibold
        )
        newButton.setContentHuggingPriority(.required, for: .horizontal)

        let searchRow = NSStackView(views: [searchField, newButton])
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.spacing = 8

        let toolbar = NSStackView(views: [kindControl, searchRow])
        toolbar.orientation = .vertical
        toolbar.alignment = .leading
        toolbar.spacing = 10

        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("capsule-entry")
        )
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 56
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.focusRingType = .none
        tableView.setAccessibilityLabel("Capsule 条目列表")

        listScrollView.documentView = tableView
        listScrollView.drawsBackground = false
        listScrollView.hasVerticalScroller = true
        listScrollView.autohidesScrollers = true
        listScrollView.translatesAutoresizingMaskIntoConstraints = false
        listContainer.wantsLayer = true
        listContainer.layer?.cornerRadius = 6
        listContainer.layer?.borderWidth = 1
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(listScrollView)
        NSLayoutConstraint.activate([
            listScrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            listScrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            listScrollView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            listScrollView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
        ])

        configureEditor()

        let divider = NSView()
        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.identifier = NSUserInterfaceItemIdentifier("capsule-divider")

        heading.translatesAutoresizingMaskIntoConstraints = false
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(heading)
        root.addSubview(toolbar)
        root.addSubview(listContainer)
        root.addSubview(divider)
        root.addSubview(editorContainer)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            // NSStackView has no intrinsic height of its own. Pin its bottom to
            // the last arranged label so short Skill/Password forms cannot
            // absorb the window's free height and push the whole pane down.
            heading.bottomAnchor.constraint(equalTo: subtitleLabel.bottomAnchor),

            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            toolbar.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14),
            toolbar.widthAnchor.constraint(equalToConstant: 286),
            kindControl.widthAnchor.constraint(equalTo: toolbar.widthAnchor),
            searchRow.widthAnchor.constraint(equalTo: toolbar.widthAnchor),

            listContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            listContainer.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            listContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            listContainer.widthAnchor.constraint(equalToConstant: 286),

            divider.leadingAnchor.constraint(equalTo: listContainer.trailingAnchor, constant: 12),
            divider.topAnchor.constraint(equalTo: toolbar.topAnchor),
            divider.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            editorContainer.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 14),
            editorContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            editorContainer.topAnchor.constraint(equalTo: toolbar.topAnchor),
            editorContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        view = root
        renderEditor()
        applyAppearance()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        storeObserver = NotificationCenter.default.addObserver(
            forName: .capsuleStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  (notification.object as AnyObject?) !== self.repository else {
                return
            }
            self.reloadFromStore()
        }
        installPrivacyObservers()
        reloadFromStore()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reloadFromStore()
    }

    override func viewWillDisappear() {
        concealPasswordPlaintext()
        super.viewWillDisappear()
    }

    func reloadFromStore() {
        guard isViewLoaded else { return }
        concealPasswordPlaintext()
        scheduleReload(after: 0)
    }

    func windowBecameKey() {
        view.window?.makeFirstResponder(searchField)
    }

    var hasUnsavedChanges: Bool { editorDirty }

    /// Reveal is deliberately ephemeral. Rebuilding the editor preserves an
    /// unsaved password draft but never extends the original 15-second lease.
    func concealPasswordPlaintext() {
        passwordRevealTimer?.invalidate()
        passwordRevealTimer = nil
        guard passwordRevealState.isPlaintextVisible else { return }
        captureDraftFromFields()
        passwordRevealState.conceal()
        renderEditor()
    }

    /// Remove decrypted credential values when a reusable pane leaves its
    /// surface. Password always fails closed.
    func scrubSensitiveEditor() {
        guard draft.kind == .password else { return }
        cancelPendingReload()
        concealPasswordPlaintext()
        draft = .empty(kind: .password)
        editorDirty = false
        renderEditor()
    }

    /// A retained standalone NSWindow must never reopen with a discarded draft
    /// still present in its controls, even when the next store reload fails.
    func discardEditorForClose() {
        guard isViewLoaded else { return }
        cancelPendingReload()
        concealPasswordPlaintext()
        applyingSelection = true
        tableView.deselectAll(nil)
        applyingSelection = false
        draft = .empty(kind: selectedKind)
        editorDirty = false
        renderEditor()
    }

    /// Any navigation that replaces the editor must be explicit about an
    /// unsaved draft. This is synchronous because AppKit selection and window
    /// close delegate callbacks need an immediate allow/deny answer.
    func confirmDiscardChangesIfNeeded() -> Bool {
        captureDraftFromFields()
        guard editorDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "放弃未保存的更改？"
        alert.informativeText = "当前 Capsule 条目尚未保存。放弃后无法恢复这些修改。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "放弃更改")
        alert.addButton(withTitle: "继续编辑")
        guard alert.runModal() == .alertFirstButtonReturn else {
            setStatus("当前更改尚未保存")
            return false
        }
        editorDirty = false
        return true
    }

    func applyAppearance() {
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = RimeUI.surface.cgColor
        titleLabel.textColor = RimeUI.textPrimary
        subtitleLabel.textColor = RimeUI.textSecondary
        statusLabel.textColor = RimeUI.textSecondary
        listContainer.layer?.backgroundColor = RimeUI.surface2.cgColor
        listContainer.layer?.borderColor = RimeUI.border.cgColor
        editorContainer.layer?.backgroundColor = RimeUI.surface2.cgColor
        editorContainer.layer?.borderColor = RimeUI.border.cgColor
        view.subviews.first(where: {
            $0.identifier?.rawValue == "capsule-divider"
        })?.layer?.backgroundColor = RimeUI.border.cgColor
        tableView.reloadData()
    }

    /// Native smoke hook: render the real AppKit pane at a deterministic size
    /// and expose only geometry, never draft contents or password controls.
    func layoutSnapshotForSmoke(
        kind: CapsuleEntryKind,
        size: NSSize
    ) -> CapsulePaneLayoutSnapshot {
        _ = view
        cancelPendingReload()
        passwordRevealTimer?.invalidate()
        passwordRevealTimer = nil
        passwordRevealState.conceal()
        selectedKind = kind
        kindControl.selectedSegment = CapsuleEntryKind.allCases.firstIndex(
            of: kind
        ) ?? 0
        draft = .empty(kind: kind)
        editorDirty = false
        renderEditor()

        view.frame = NSRect(origin: .zero, size: size)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        editorScrollView.layoutSubtreeIfNeeded()
        formStack.layoutSubtreeIfNeeded()

        let subtitleFrame = subtitleLabel.convert(subtitleLabel.bounds, to: view)
        let kindFrame = kindControl.convert(kindControl.bounds, to: view)
        let editorFrame = editorContainer.convert(editorContainer.bounds, to: view)
        let subtitleToTabsGap: CGFloat
        let tabsTop: CGFloat
        let editorTop: CGFloat
        if view.isFlipped {
            subtitleToTabsGap = kindFrame.minY - subtitleFrame.maxY
            tabsTop = kindFrame.minY
            editorTop = editorFrame.minY
        } else {
            subtitleToTabsGap = subtitleFrame.minY - kindFrame.maxY
            tabsTop = kindFrame.maxY
            editorTop = editorFrame.maxY
        }

        let clip = editorScrollView.contentView
        let formTopGap: CGFloat
        if let firstRow = formStack.arrangedSubviews.first {
            let firstFrame = firstRow.convert(firstRow.bounds, to: clip)
            formTopGap = clip.isFlipped
                ? firstFrame.minY - clip.bounds.minY
                : clip.bounds.maxY - firstFrame.maxY
        } else {
            formTopGap = .infinity
        }

        return CapsulePaneLayoutSnapshot(
            subtitleToTabsGap: subtitleToTabsGap,
            formTopGap: formTopGap,
            tabsTop: tabsTop,
            editorTop: editorTop,
            kindControlFrame: kindFrame,
            editorFrame: editorFrame,
            hasAmbiguousLayout: view.hasAmbiguousLayout
                || editorContainer.hasAmbiguousLayout
                || listContainer.hasAmbiguousLayout
        )
    }

    /// Native smoke hook that inspects control classes and labels only. It
    /// intentionally uses empty values so no credential can enter failure text.
    func passwordEditorSnapshotForSmoke(
        plaintextVisible: Bool
    ) -> CapsulePasswordEditorSnapshot {
        _ = view
        passwordRevealTimer?.invalidate()
        passwordRevealTimer = nil
        selectedKind = .password
        kindControl.selectedSegment = CapsuleEntryKind.allCases.firstIndex(
            of: .password
        ) ?? 0
        draft = .empty(kind: .password)
        draft.previousPasswords = [""]
        editorDirty = false
        passwordRevealState.conceal()
        if plaintextVisible {
            passwordRevealState.reveal(now: Date())
        }
        renderEditor()
        let snapshot = CapsulePasswordEditorSnapshot(
            revealButtonTitle: passwordRevealButton?.title ?? "",
            urlUsesSecureControl: passwordURLField != nil,
            appUsesSecureControl: passwordAppField != nil,
            usernameUsesSecureControl: passwordUsernameField != nil,
            passwordUsesSecureControl: passwordField is NSSecureTextField,
            previousPasswordsUseSecureControls: previousPasswordFields.allSatisfy {
                $0 is NSSecureTextField
            },
            plaintextAllowsSelection: passwordField?.isSelectable ?? false,
            plaintextIsAccessibilityElement: passwordField?
                .isAccessibilityElement() ?? false,
            plaintextHasToolTip: passwordField?.toolTip != nil,
            hasUnsavedChanges: editorDirty
        )
        passwordRevealState.conceal()
        renderEditor()
        return snapshot
    }

    func validatesEntryRowPointerForSmoke() -> Bool {
        let cell = CapsuleWindowEntryCell()
        let enabled = cell.pointingHandCursorKindForSmoke
        cell.isPointingHandEnabled = false
        return enabled == .pointingHand
            && cell.pointingHandCursorKindForSmoke == .arrow
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("capsule-entry-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? CapsuleWindowEntryCell ?? CapsuleWindowEntryCell()
        cell.identifier = identifier
        cell.configure(row: rows[row], selected: tableView.selectedRow == row)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection else { return }
        let requestedRow = tableView.selectedRow
        guard confirmDiscardChangesIfNeeded() else {
            restoreTableSelectionForDraft()
            return
        }
        cancelPendingReload()
        selectRow(at: requestedRow)
        tableView.reloadData()
    }

    func controlTextDidChange(_ notification: Notification) {
        editorDirty = true
    }

    func textDidChange(_ notification: Notification) {
        editorDirty = true
    }

    private func scheduleReload(after delay: TimeInterval) {
        searchReloadTimer?.invalidate()
        searchReloadTimer = nil
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let kind = selectedKind
        let query = searchField.stringValue
        let preferredID = draft.id
        let begin = { [weak self] in
            self?.performReload(
                generation: generation,
                kind: kind,
                query: query,
                preferredID: preferredID
            )
        }
        if delay > 0 {
            searchReloadTimer = Timer.scheduledTimer(
                withTimeInterval: delay,
                repeats: false
            ) { _ in begin() }
        } else {
            begin()
        }
    }

    private func performReload(
        generation: UInt64,
        kind: CapsuleEntryKind,
        query: String,
        preferredID: UUID?
    ) {
        setStatus(query.isEmpty ? "正在读取本地 Capsule" : "正在本地搜索")
        let repository = self.repository
        reloadQueue.async { [weak self] in
            let result = Result {
                try repository.list(kind: kind, query: query)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.reloadGeneration == generation else { return }
                self.applyReloadResult(
                    result,
                    kind: kind,
                    preferredID: preferredID
                )
            }
        }
    }

    private func applyReloadResult(
        _ result: Result<[CapsuleWindowEntryRow], Error>,
        kind: CapsuleEntryKind,
        preferredID: UUID?
    ) {
        switch result {
        case let .success(rows):
            self.rows = rows
            tableView.reloadData()
            if editorDirty, draft.kind == kind {
                if let id = draft.id,
                   let index = rows.firstIndex(where: { $0.id == id }) {
                    selectTableRow(index)
                } else {
                    applyingSelection = true
                    tableView.deselectAll(nil)
                    applyingSelection = false
                }
                setStatus("本地列表已变化；当前编辑尚未保存")
                return
            }
            if let preferredID,
               let index = rows.firstIndex(where: { $0.id == preferredID }) {
                selectTableRow(index)
                // Refresh the exact record, not only the list projection. Two
                // visible panes must never overwrite a newer external edit
                // with a stale draft.
                guard selectRow(at: index) else { return }
            } else if CapsuleWindowSelectionRules
                .allowsAutomaticFirstSelection(kind: kind), !rows.isEmpty {
                selectTableRow(0)
                guard selectRow(at: 0) else { return }
            } else {
                applyingSelection = true
                tableView.deselectAll(nil)
                applyingSelection = false
                draft = .empty(kind: kind)
                editorDirty = false
                renderEditor()
            }
            setStatus(
                rows.isEmpty
                    ? "暂无 \(kind.displayName) 条目"
                    : "\(rows.count) 条本地记录"
            )
        case let .failure(error):
            rows = []
            tableView.reloadData()
            setStatus(error.localizedDescription, isError: true)
        }
    }

    private func selectTableRow(_ index: Int) {
        applyingSelection = true
        tableView.selectRowIndexes(
            IndexSet(integer: index),
            byExtendingSelection: false
        )
        applyingSelection = false
        tableView.scrollRowToVisible(index)
        tableView.reloadData()
    }

    private func restoreTableSelectionForDraft() {
        applyingSelection = true
        if let id = draft.id,
           let index = rows.firstIndex(where: { $0.id == id }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        applyingSelection = false
        tableView.reloadData()
    }

    private func cancelPendingReload() {
        searchReloadTimer?.invalidate()
        searchReloadTimer = nil
        reloadGeneration &+= 1
    }

    private func configureEditor() {
        editorContainer.wantsLayer = true
        editorContainer.layer?.cornerRadius = 6
        editorContainer.layer?.borderWidth = 1

        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 10
        formStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        formStack.translatesAutoresizingMaskIntoConstraints = false

        // NSStackView can be the scroll document directly. Binding both width
        // and minimum height to the clip view keeps the form top-aligned while
        // still allowing Password fields to grow and scroll.
        editorScrollView.documentView = formStack
        NSLayoutConstraint.activate([
            formStack.widthAnchor.constraint(equalTo: editorScrollView.contentView.widthAnchor),
            formStack.heightAnchor.constraint(
                greaterThanOrEqualTo: editorScrollView.contentView.heightAnchor
            ),
        ])
        editorScrollView.drawsBackground = false
        editorScrollView.hasVerticalScroller = true
        editorScrollView.autohidesScrollers = true
        editorScrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = MailboxTerminalTypography.font(ofSize: 9)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        deleteButton.target = self
        deleteButton.action = #selector(deleteCurrent)
        deleteButton.bezelStyle = .inline
        deleteButton.font = MailboxTerminalTypography.font(ofSize: 10)
        saveButton.target = self
        saveButton.action = #selector(saveCurrent)
        saveButton.bezelStyle = .rounded
        saveButton.font = MailboxTerminalTypography.font(
            ofSize: 10,
            weight: .semibold
        )
        let actions = NSStackView(views: [statusLabel, deleteButton, saveButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false

        editorContainer.addSubview(editorScrollView)
        editorContainer.addSubview(actions)
        NSLayoutConstraint.activate([
            editorScrollView.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            editorScrollView.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            editorScrollView.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            editorScrollView.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -8),

            actions.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor, constant: 16),
            actions.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor, constant: -16),
            actions.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor, constant: -12),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
    }

    private func renderEditor() {
        guard isViewLoaded else { return }
        for view in formStack.arrangedSubviews {
            formStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        titleField = nil
        contentTextView = nil
        skillPathField = nil
        passwordURLField = nil
        passwordAppField = nil
        passwordUsernameField = nil
        passwordField = nil
        previousPasswordFields = []
        passwordRevealButton = nil

        let mode = draft.id == nil ? "NEW" : "EDIT"
        let heading = NSTextField(
            labelWithString: "// \(mode) \(draft.kind.displayName.uppercased())"
        )
        heading.font = MailboxTerminalTypography.font(
            ofSize: 10,
            weight: .semibold
        )
        heading.textColor = RimeUI.accentTextColor
        if draft.kind == .password {
            let revealButton = RimePointingHandButton(
                title: passwordRevealState.isPlaintextVisible
                    ? "隐藏明文"
                    : "查看明文",
                target: self,
                action: #selector(togglePasswordPlaintext)
            )
            revealButton.bezelStyle = .inline
            revealButton.font = MailboxTerminalTypography.font(
                ofSize: 9,
                weight: .semibold
            )
            revealButton.setAccessibilityLabel(
                passwordRevealState.isPlaintextVisible
                    ? "隐藏密码明文"
                    : "查看密码明文"
            )
            revealButton.setContentHuggingPriority(.required, for: .horizontal)
            passwordRevealButton = revealButton

            let headingRow = NSStackView(views: [
                heading,
                NSView(),
                revealButton,
            ])
            headingRow.orientation = .horizontal
            headingRow.alignment = .centerY
            headingRow.spacing = 8
            addFormRow(headingRow)
        } else {
            addFormRow(heading)
        }

        let title = NSTextField(string: draft.title)
        title.placeholderString = "标题"
        title.font = MailboxTerminalTypography.font(ofSize: 12)
        title.setAccessibilityLabel("标题")
        title.delegate = self
        titleField = title
        addField(label: "TITLE", field: title)

        switch draft.kind {
        case .prompt, .memory:
            let textView = makeContentTextView(text: draft.content)
            contentTextView = textView
            addTextArea(label: "CONTENT", textView: textView)
        case .skill:
            let pathField = NSTextField(string: draft.content)
            pathField.placeholderString = "/Users/name/path/to/skill"
            pathField.font = MailboxTerminalTypography.font(ofSize: 11)
            pathField.setAccessibilityLabel("Skill 绝对路径")
            pathField.delegate = self
            skillPathField = pathField
            let chooseButton = RimePointingHandButton(
                title: "选择文件夹…",
                target: self,
                action: #selector(chooseSkillFolder)
            )
            chooseButton.bezelStyle = .rounded
            chooseButton.font = MailboxTerminalTypography.font(ofSize: 10)
            let row = NSStackView(views: [pathField, chooseButton])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            addField(label: "ABSOLUTE PATH", field: row)
        case .password:
            addPasswordFields()
        }

        deleteButton.isEnabled = draft.id != nil
        saveButton.title = draft.id == nil ? "创建" : "保存"
    }

    private func addPasswordFields() {
        let url = makeSecureField(
            value: draft.url,
            label: "网址",
            policyField: .url
        )
        let app = makeSecureField(
            value: draft.app,
            label: "App",
            policyField: .app
        )
        let username = makeSecureField(
            value: draft.username,
            label: "用户名",
            policyField: .username
        )
        let password = makePasswordEditorField(
            value: draft.password,
            label: "密码",
            policyField: .password
        )
        passwordURLField = url
        passwordAppField = app
        passwordUsernameField = username
        passwordField = password
        addField(label: "URL · SECURE", field: url)
        addField(label: "APP · SECURE", field: app)
        addField(label: "USERNAME · SECURE", field: username)
        addField(label: "PASSWORD · SECURE", field: password)

        let previousHeading = NSStackView()
        previousHeading.orientation = .horizontal
        previousHeading.alignment = .centerY
        let label = fieldLabel("PREVIOUS PASSWORDS · SECURE")
        let add = RimePointingHandButton(
            title: "＋ 添加",
            target: self,
            action: #selector(addPreviousPassword)
        )
        add.bezelStyle = .inline
        add.font = MailboxTerminalTypography.font(ofSize: 9)
        previousHeading.addArrangedSubview(label)
        previousHeading.addArrangedSubview(NSView())
        previousHeading.addArrangedSubview(add)
        addFormRow(previousHeading)

        for (index, value) in draft.previousPasswords.enumerated() {
            let field = makePasswordEditorField(
                value: value,
                label: "曾用密码 \(index + 1)",
                policyField: .previousPassword
            )
            previousPasswordFields.append(field)
            let remove = RimePointingHandButton(
                title: "−",
                target: self,
                action: #selector(removePreviousPassword(_:))
            )
            remove.tag = index
            remove.bezelStyle = .inline
            remove.setAccessibilityLabel("删除曾用密码 \(index + 1)")
            let row = NSStackView(views: [field, remove])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            addFormRow(row)
        }
    }

    private func addField(label: String, field: NSView) {
        let stack = NSStackView(views: [fieldLabel(label), field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        addFormRow(stack)
    }

    private func addFormRow(_ row: NSView) {
        row.translatesAutoresizingMaskIntoConstraints = false
        formStack.addArrangedSubview(row)
        row.widthAnchor.constraint(
            equalTo: formStack.widthAnchor,
            constant: -(formStack.edgeInsets.left + formStack.edgeInsets.right)
        ).isActive = true
    }

    private func addTextArea(label: String, textView: NSTextView) {
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = true
        scroll.backgroundColor = RimeUI.surface3
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        addField(label: label, field: scroll)
    }

    private func fieldLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = MailboxTerminalTypography.font(
            ofSize: 9,
            weight: .semibold
        )
        label.textColor = RimeUI.textSecondary
        label.alignment = .left
        return label
    }

    private func makeSecureField(
        value: String,
        label: String,
        policyField: CapsulePasswordEditorField
    ) -> NSSecureTextField {
        precondition(
            CapsulePasswordEditorSecurityPolicy.usesSecureControl(policyField)
        )
        let field = NSSecureTextField(string: value)
        field.placeholderString = label
        field.font = MailboxTerminalTypography.font(ofSize: 11)
        field.setAccessibilityLabel(label + "，安全输入")
        field.delegate = self
        return field
    }

    private func makePasswordEditorField(
        value: String,
        label: String,
        policyField: CapsulePasswordEditorField
    ) -> NSTextField {
        precondition(CapsulePasswordEditorSecurityPolicy.mayReveal(policyField))
        if CapsulePasswordEditorSecurityPolicy.usesSecureControl(
            policyField,
            plaintextVisible: passwordRevealState.isPlaintextVisible
        ) {
            return makeSecureField(
                value: value,
                label: label,
                policyField: policyField
            )
        }

        // Plaintext reveal is view-only. Keeping this field non-selectable
        // prevents an accidental copy/cut from placing the credential on the
        // general pasteboard. Hiding it restores the editable secure control.
        let field = NSTextField(string: value)
        field.placeholderString = label
        field.font = MailboxTerminalTypography.font(ofSize: 11)
        field.isEditable = false
        field.isSelectable = false
        field.setAccessibilityElement(false)
        return field
    }

    private func makeContentTextView(text: String) -> NSTextView {
        let textView = NSTextView(frame: .zero)
        textView.string = text
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = MailboxTerminalTypography.font(ofSize: 12)
        textView.textColor = RimeUI.textPrimary
        textView.backgroundColor = RimeUI.surface3
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.setAccessibilityLabel("Capsule 内容")
        textView.delegate = self
        return textView
    }

    private func captureDraftFromFields() {
        draft.title = titleField?.stringValue ?? draft.title
        switch draft.kind {
        case .prompt, .memory:
            draft.content = contentTextView?.string ?? draft.content
        case .skill:
            draft.content = skillPathField?.stringValue ?? draft.content
        case .password:
            draft.url = passwordURLField?.stringValue ?? draft.url
            draft.app = passwordAppField?.stringValue ?? draft.app
            draft.username = passwordUsernameField?.stringValue ?? draft.username
            draft.password = passwordField?.stringValue ?? draft.password
            draft.previousPasswords = previousPasswordFields.map(\.stringValue)
        }
    }

    private func schedulePasswordAutoConceal() {
        passwordRevealTimer?.invalidate()
        passwordRevealTimer = nil
        guard let delay = passwordRevealState.remainingDuration(now: Date()) else {
            return
        }
        passwordRevealTimer = Timer.scheduledTimer(
            withTimeInterval: max(0.001, delay),
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            self.passwordRevealTimer = nil
            guard self.passwordRevealState.concealIfExpired(now: Date()) else {
                self.schedulePasswordAutoConceal()
                return
            }
            self.captureDraftFromFields()
            self.renderEditor()
        }
    }

    @discardableResult
    private func selectRow(at index: Int) -> Bool {
        guard rows.indices.contains(index) else { return false }
        concealPasswordPlaintext()
        do {
            let loadedDraft = try repository.draft(for: rows[index])
            draft = loadedDraft
            editorDirty = false
            renderEditor()
            setStatus("已加载本地条目")
            return true
        } catch {
            if draft.kind == .password,
               !rows.contains(where: { $0.id == draft.id }) {
                draft = .empty(kind: .password)
                editorDirty = false
                renderEditor()
            }
            restoreTableSelectionForDraft()
            setStatus(error.localizedDescription, isError: true)
            return false
        }
    }

    private func setStatus(_ value: String, isError: Bool = false) {
        statusLabel.stringValue = value
        statusLabel.textColor = isError ? .systemRed : RimeUI.textSecondary
    }

    @objc private func kindChanged() {
        let index = kindControl.selectedSegment
        guard CapsuleEntryKind.allCases.indices.contains(index) else { return }
        let requestedKind = CapsuleEntryKind.allCases[index]
        guard requestedKind != selectedKind else { return }
        concealPasswordPlaintext()
        guard confirmDiscardChangesIfNeeded() else {
            kindControl.selectedSegment = CapsuleEntryKind.allCases.firstIndex(
                of: selectedKind
            ) ?? 0
            return
        }
        selectedKind = requestedKind
        searchField.placeholderString = selectedKind == .password
            ? "仅搜索密码标题"
            : "搜索标题或内容"
        cancelPendingReload()
        draft = .empty(kind: selectedKind)
        editorDirty = false
        renderEditor()
        reloadFromStore()
    }

    @objc private func searchChanged() {
        concealPasswordPlaintext()
        scheduleReload(after: Self.searchDebounce)
    }

    @objc private func createNew() {
        concealPasswordPlaintext()
        guard confirmDiscardChangesIfNeeded() else { return }
        cancelPendingReload()
        tableView.deselectAll(nil)
        draft = .empty(kind: selectedKind)
        editorDirty = false
        renderEditor()
        setStatus("新建 \(selectedKind.displayName) 条目")
        view.window?.makeFirstResponder(titleField)
    }

    @objc private func saveCurrent() {
        concealPasswordPlaintext()
        captureDraftFromFields()
        if draft.kind == .password {
            draft.previousPasswords.removeAll(where: \.isEmpty)
        }
        do {
            let saved = try repository.save(draft)
            draft.id = saved.id
            draft.loadedRevision = saved.revision
            editorDirty = false
            if let index = rows.firstIndex(where: { $0.id == saved.id }) {
                rows[index] = saved
                tableView.reloadData()
                selectTableRow(index)
            }
            reloadFromStore()
            setStatus("已保存到本地 Capsule")
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    @objc private func deleteCurrent() {
        concealPasswordPlaintext()
        guard let id = draft.id,
              let expectedRevision = draft.loadedRevision,
              let row = rows.first(where: { $0.id == id }),
              let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "删除「\(row.title)」？"
        alert.informativeText = "该操作会删除本地 Capsule 文件。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try self.repository.remove(
                    row,
                    expectedRevision: expectedRevision
                )
                self.cancelPendingReload()
                self.rows.removeAll(where: { $0.id == row.id })
                self.applyingSelection = true
                self.tableView.deselectAll(nil)
                self.applyingSelection = false
                self.tableView.reloadData()
                self.draft = .empty(kind: self.selectedKind)
                self.editorDirty = false
                self.renderEditor()
                self.reloadFromStore()
                self.setStatus("已删除本地条目")
            } catch {
                self.setStatus(error.localizedDescription, isError: true)
            }
        }
    }

    @objc private func chooseSkillFolder() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 Skill 文件夹"
        panel.message = "Capsule 会保存该文件夹在当前电脑中的绝对路径。"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            self?.skillPathField?.stringValue = path
            self?.editorDirty = true
            self?.setStatus("Skill 路径尚未保存")
        }
    }

    @objc private func addPreviousPassword() {
        captureDraftFromFields()
        draft.previousPasswords.append("")
        editorDirty = true
        renderEditor()
        view.window?.makeFirstResponder(previousPasswordFields.last)
    }

    @objc private func removePreviousPassword(_ sender: NSButton) {
        captureDraftFromFields()
        guard draft.previousPasswords.indices.contains(sender.tag) else { return }
        draft.previousPasswords.remove(at: sender.tag)
        editorDirty = true
        renderEditor()
    }

    @objc private func togglePasswordPlaintext() {
        guard draft.kind == .password else { return }
        captureDraftFromFields()
        if passwordRevealState.isPlaintextVisible {
            passwordRevealState.conceal()
            passwordRevealTimer?.invalidate()
            passwordRevealTimer = nil
        } else {
            passwordRevealState.reveal(now: Date())
            schedulePasswordAutoConceal()
        }
        renderEditor()
    }

    private func installPrivacyObservers() {
        guard applicationPrivacyObservers.isEmpty,
              workspacePrivacyObservers.isEmpty,
              distributedPrivacyObservers.isEmpty else { return }

        let center = NotificationCenter.default
        for name in [
            NSApplication.didResignActiveNotification,
            NSWindow.didResignKeyNotification,
        ] {
            applicationPrivacyObservers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                if name == NSWindow.didResignKeyNotification,
                   (notification.object as? NSWindow) !== self.view.window {
                    return
                }
                self.concealPasswordPlaintext()
            })
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.willSleepNotification,
        ] {
            workspacePrivacyObservers.append(workspace.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.concealPasswordPlaintext()
            })
        }

        let distributed = DistributedNotificationCenter.default()
        distributedPrivacyObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.concealPasswordPlaintext()
        })
    }
}

private final class CapsuleWindowEntryCell: NSTableCellView {
    private var pointerTrackingArea: NSTrackingArea?
    private var pointerInside = false
    private let kindLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")

    var isPointingHandEnabled = true {
        didSet {
            RimePointingHandCursorRules.enabledDidChange(
                for: self,
                pointerInside: pointerInside,
                enabled: isPointingHandEnabled
            )
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        RimePointingHandCursorRules.updateTrackingArea(
            &pointerTrackingArea,
            for: self
        )
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        RimePointingHandCursorRules.resetCursorRect(
            for: self,
            enabled: isPointingHandEnabled
        )
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        pointerInside = true
        RimePointingHandCursorRules.mouseEntered(
            enabled: isPointingHandEnabled
        )
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        RimePointingHandCursorRules.mouseExited()
        super.mouseExited(with: event)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        kindLabel.font = MailboxTerminalTypography.font(
            ofSize: 8,
            weight: .semibold
        )
        kindLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.font = MailboxTerminalTypography.font(
            ofSize: 11,
            weight: .semibold
        )
        titleLabel.lineBreakMode = .byTruncatingTail
        previewLabel.font = MailboxTerminalTypography.font(ofSize: 9)
        previewLabel.lineBreakMode = .byTruncatingTail

        let heading = NSStackView(views: [kindLabel, titleLabel])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 7
        let stack = NSStackView(views: [heading, previewLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    fileprivate var pointingHandCursorKindForSmoke: RimePointingHandCursorKind {
        RimePointingHandCursorRules.kind(enabled: isPointingHandEnabled)
    }

    func configure(row: CapsuleWindowEntryRow, selected: Bool) {
        kindLabel.stringValue = row.kind.displayName.uppercased()
        titleLabel.stringValue = row.title
        previewLabel.stringValue = row.preview
        kindLabel.textColor = selected
            ? RimeUI.accentTextColor
            : RimeUI.textSecondary
        titleLabel.textColor = selected
            ? RimeUI.accentTextColor
            : RimeUI.textPrimary
        previewLabel.textColor = RimeUI.textSecondary
        layer?.backgroundColor = selected
            ? RimeUI.accentGreen.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
        setAccessibilityLabel(row.accessibilitySummary)
    }
}
