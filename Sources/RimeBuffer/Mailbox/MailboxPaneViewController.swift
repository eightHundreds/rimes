import Cocoa

extension Notification.Name {
    static let mailboxInboundReviewAssociationDidChange = Notification.Name(
        "MailboxInboundReviewAssociationDidChange"
    )
}

/// Provider continuations live outside the Mailbox UI. A coordinator accepts
/// the reply only after it has frozen the connector/model context and taken
/// ownership of the background job.
protocol MailboxAIReplyCoordinating: AnyObject {
    func sendMailboxReply(threadID: UUID,
                          body: String,
                          completion: @escaping (Result<Void, Error>) -> Void)
}

/// Loose coupling point between the reusable Mailbox surface and the provider
/// / inbound-review coordinators. Live associations are process-local; after a
/// restart InboundBus rebuilds them only from the Store's durable review message
/// identity, never from untrusted source display metadata.
final class MailboxInteractionBridge {
    static let shared = MailboxInteractionBridge()
    static let notificationThreadIDKey = "threadID"

    weak var aiReplyCoordinator: MailboxAIReplyCoordinating?

    private var inboundItemIDsByThreadID: [UUID: UUID] = [:]

    private init() {}

    func associateInboundReview(threadID: UUID, itemID: UUID) {
        guard inboundItemIDsByThreadID[threadID] != itemID else { return }
        inboundItemIDsByThreadID[threadID] = itemID
        notifyAssociationChanged(threadID: threadID)
    }

    func clearInboundReview(threadID: UUID) {
        inboundItemIDsByThreadID.removeValue(forKey: threadID)
        notifyAssociationChanged(threadID: threadID)
    }

    func pendingInboundItem(threadID: UUID) -> InboundItem? {
        let itemID = inboundItemIDsByThreadID[threadID]
        if let itemID,
           let item = InboundBus.shared.pending.first(where: { $0.id == itemID }) {
            return item
        }
        if itemID != nil {
            inboundItemIDsByThreadID.removeValue(forKey: threadID)
        }
        return InboundBus.shared.pendingItem(mailboxThreadID: threadID)
    }

    private func notifyAssociationChanged(threadID: UUID) {
        let post = { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(
                name: .mailboxInboundReviewAssociationDidChange,
                object: self,
                userInfo: [Self.notificationThreadIDKey: threadID]
            )
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }
}

/// Pure state rules used by the AppKit controller and smoke coverage. Store
/// revisions are monotonic; a pane may only render forward and may only clear
/// unread state for the exact snapshot it is currently displaying.
enum MailboxPaneStateRules {
    static func shouldApply(currentRevision: UInt64,
                            incomingRevision: UInt64) -> Bool {
        incomingRevision >= currentRevision
    }

    static func threadToMarkRead(
        renderedSnapshot: MailboxStoreSnapshot,
        storeSnapshot: MailboxStoreSnapshot,
        windowIsVisible: Bool,
        windowIsKey: Bool
    ) -> UUID? {
        guard windowIsVisible,
              windowIsKey,
              renderedSnapshot.revision == storeSnapshot.revision,
              let threadID = renderedSnapshot.selectedThreadID,
              storeSnapshot.selectedThreadID == threadID,
              storeSnapshot.thread(id: threadID)?.unread == true else {
            return nil
        }
        return threadID
    }

    /// A progress event normally changes only the process-local preview for one
    /// generation. If its snapshot also carries a newer durable/selection
    /// projection, the pane must apply that whole snapshot; advancing only its
    /// revision would otherwise cause the delayed durable event to be rejected
    /// as stale while leaving the thread index or selected conversation behind.
    static func generationProgressRequiresFullApply(
        current: MailboxStoreSnapshot,
        incoming: MailboxStoreSnapshot,
        progressedThreadID: UUID
    ) -> Bool {
        guard current.threads == incoming.threads,
              current.selectedThreadID == incoming.selectedThreadID,
              current.persistence == incoming.persistence else {
            return true
        }
        var currentOtherPreviews = current.generationPreviews
        var incomingOtherPreviews = incoming.generationPreviews
        currentOtherPreviews.removeValue(forKey: progressedThreadID)
        incomingOtherPreviews.removeValue(forKey: progressedThreadID)
        return currentOtherPreviews != incomingOtherPreviews
    }
}

/// Reusable two-column Mailbox surface. The standalone window and Settings
/// each own one controller/view instance, while selection and content are
/// shared through MailboxStore.
final class MailboxPaneViewController: NSViewController {
    private let store: MailboxStore
    private let interactionBridge: MailboxInteractionBridge
    private let threadIndexController: MailboxThreadIndexViewController
    private let conversationController: MailboxConversationViewController

    private var observation: MailboxStoreObservation?
    private var appearanceObserver: NSObjectProtocol?
    private var keyWindowObserver: NSObjectProtocol?
    private var reviewAssociationObserver: NSObjectProtocol?
    private var currentSnapshot: MailboxStoreSnapshot
    private var markReadScheduleGeneration: UInt64 = 0

    init(store: MailboxStore = .shared,
         interactionBridge: MailboxInteractionBridge = .shared) {
        self.store = store
        self.interactionBridge = interactionBridge
        currentSnapshot = store.snapshot
        threadIndexController = MailboxThreadIndexViewController()
        conversationController = MailboxConversationViewController(
            store: store,
            interactionBridge: interactionBridge
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        observation?.cancel()
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
        }
        if let reviewAssociationObserver {
            NotificationCenter.default.removeObserver(reviewAssociationObserver)
        }
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.translatesAutoresizingMaskIntoConstraints = false

        addChild(threadIndexController)
        addChild(conversationController)
        let threadView = threadIndexController.view
        let conversationView = conversationController.view
        threadView.translatesAutoresizingMaskIntoConstraints = false
        conversationView.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(threadView)
        root.addSubview(divider)
        root.addSubview(conversationView)
        NSLayoutConstraint.activate([
            threadView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            threadView.topAnchor.constraint(equalTo: root.topAnchor),
            threadView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            threadView.widthAnchor.constraint(equalToConstant: 212),

            divider.leadingAnchor.constraint(equalTo: threadView.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            conversationView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            conversationView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            conversationView.topAnchor.constraint(equalTo: root.topAnchor),
            conversationView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        root.layer?.cornerRadius = 6
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        divider.layer?.backgroundColor = RimeUI.border.cgColor
        view = root

        threadIndexController.onSelectThread = { [weak self] threadID in
            guard let self else { return }
            _ = self.store.selectThread(id: threadID)
            self.scheduleMarkSelectedThreadReadIfActive()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyAppearance()
        observation = store.observe { [weak self] event in
            self?.apply(event)
        }
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .rimeAppearanceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
        }
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let window = notification.object as? NSWindow,
                  window === self.view.window else { return }
            self.scheduleMarkSelectedThreadReadIfActive()
        }
        reviewAssociationObserver = NotificationCenter.default.addObserver(
            forName: .mailboxInboundReviewAssociationDidChange,
            object: interactionBridge,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let threadID = notification.userInfo?[
                    MailboxInteractionBridge.notificationThreadIDKey
                  ] as? UUID,
                  self.currentSnapshot.selectedThreadID == threadID else {
                return
            }
            self.conversationController.refreshReviewState()
        }
        ensureSelection()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        scheduleMarkSelectedThreadReadIfActive()
    }

    var selectedThreadID: UUID? { currentSnapshot.selectedThreadID }

    func reloadFromStore() {
        apply(store.snapshot)
        conversationController.refreshReviewState()
    }

    func windowBecameKey() {
        reloadFromStore()
        scheduleMarkSelectedThreadReadIfActive()
    }

    private func ensureSelection() {
        let snapshot = store.snapshot
        if snapshot.selectedThreadID == nil, !snapshot.threads.isEmpty {
            _ = store.selectLatestUnreadOrMostRecent()
        } else {
            apply(snapshot)
        }
    }

    private func apply(_ snapshot: MailboxStoreSnapshot) {
        guard MailboxPaneStateRules.shouldApply(
            currentRevision: currentSnapshot.revision,
            incomingRevision: snapshot.revision
        ) else {
            return
        }
        currentSnapshot = snapshot
        threadIndexController.apply(snapshot: snapshot)
        let selectedThread = snapshot.selectedThreadID.flatMap(snapshot.thread(id:))
        conversationController.apply(
            thread: selectedThread,
            persistence: snapshot.persistence,
            preview: snapshot.selectedThreadID.flatMap(
                snapshot.generationPreview(threadID:)
            )
        )
        if snapshot.selectedThreadID == nil, !snapshot.threads.isEmpty {
            // Do not emit a nested selection event while Store is still
            // delivering the content event to another pane. Otherwise that
            // pane could finish by rendering the older nil-selection snapshot.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.store.snapshot.selectedThreadID == nil,
                      !self.store.snapshot.threads.isEmpty else { return }
                _ = self.store.selectLatestUnreadOrMostRecent()
            }
            return
        }
        scheduleMarkSelectedThreadReadIfActive()
    }

    private func apply(_ event: MailboxStoreEvent) {
        guard case let .generationProgressed(threadID) = event.change else {
            apply(event.snapshot)
            return
        }
        let snapshot = event.snapshot
        guard MailboxPaneStateRules.shouldApply(
            currentRevision: currentSnapshot.revision,
            incomingRevision: snapshot.revision
        ) else {
            return
        }
        if MailboxPaneStateRules.generationProgressRequiresFullApply(
            current: currentSnapshot,
            incoming: snapshot,
            progressedThreadID: threadID
        ) {
            apply(snapshot)
            return
        }
        currentSnapshot = snapshot
        guard snapshot.selectedThreadID == threadID,
              let thread = snapshot.thread(id: threadID) else {
            return
        }
        conversationController.apply(
            thread: thread,
            persistence: snapshot.persistence,
            preview: snapshot.generationPreview(threadID: threadID)
        )
    }

    private func scheduleMarkSelectedThreadReadIfActive() {
        markReadScheduleGeneration &+= 1
        let generation = markReadScheduleGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.markReadScheduleGeneration == generation else { return }
            self.markSelectedThreadReadIfActiveNow()
        }
    }

    private func markSelectedThreadReadIfActiveNow() {
        guard isViewLoaded, let window = view.window else { return }
        let latestSnapshot = store.snapshot
        guard let threadID = MailboxPaneStateRules.threadToMarkRead(
            renderedSnapshot: currentSnapshot,
            storeSnapshot: latestSnapshot,
            windowIsVisible: window.isVisible,
            windowIsKey: window.isKeyWindow
        ) else {
            return
        }
        do {
            try store.markRead(threadID: threadID)
        } catch {
            IMELog.write("mailbox mark-read failed kind=ui")
        }
    }

    private func applyAppearance() {
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = RimeUI.surface2.cgColor
        view.layer?.borderColor = RimeUI.border.cgColor
        threadIndexController.applyAppearance()
        conversationController.applyAppearance()
        apply(store.snapshot)
    }
}

private enum MailboxThreadListRow {
    case dateHeader(String)
    case thread(UUID)
}

/// One shared terminal grid keeps transcript rows and the composer on the same
/// columns. AppKit's stack-view intrinsic sizes must not silently move one row
/// away from the rest when labels or placeholder text change.
private enum MailboxTerminalLayout {
    static let outerInset: CGFloat = 16
    static let timeWidth: CGFloat = 42
    static let gap: CGFloat = 8
    static let sourceWidth: CGFloat = 88
    static let markerWidth: CGFloat = 14

    static let markerLeading = outerInset + timeWidth + gap + sourceWidth + gap
    static let bodyLeading = markerLeading + markerWidth + gap
    static let bodyTrailing: CGFloat = 16
}

private enum MailboxTerminalGeometry {
    static func frame(of view: NSView, in ancestor: NSView) -> NSRect {
        ancestor.convert(view.bounds, from: view)
    }

    static func alignmentFrame(of view: NSView, in ancestor: NSView) -> NSRect {
        guard let superview = view.superview else { return frame(of: view, in: ancestor) }
        return ancestor.convert(view.alignmentRect(forFrame: view.frame), from: superview)
    }

    static func firstBaselineY(of view: NSView, in ancestor: NSView) -> CGFloat {
        let localY = view.isFlipped
            ? view.bounds.minY + view.firstBaselineOffsetFromTop
            : view.bounds.maxY - view.firstBaselineOffsetFromTop
        return ancestor.convert(NSPoint(x: view.bounds.minX, y: localY), from: view).y
    }

    static func containsButton(in view: NSView) -> Bool {
        view is NSButton || view.subviews.contains { containsButton(in: $0) }
    }
}

private enum MailboxThreadListLayout {
    static let rowHeight: CGFloat = 40
}

private final class MailboxThreadIndexViewController: NSViewController,
                                                      NSTableViewDataSource,
                                                      NSTableViewDelegate {
    var onSelectThread: ((UUID) -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var rows: [MailboxThreadListRow] = []
    private var threadsByID: [UUID: MailboxThread] = [:]
    private var selectedThreadID: UUID?
    private var applyingSelection = false

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mailbox-thread"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = .zero
        tableView.dataSource = self
        tableView.delegate = self
        tableView.focusRingType = .none
        tableView.autoresizingMask = [.width]
        tableView.setAccessibilityLabel("Mailbox 会话列表")

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    func apply(snapshot: MailboxStoreSnapshot) {
        selectedThreadID = snapshot.selectedThreadID
        threadsByID = Dictionary(uniqueKeysWithValues: snapshot.threads.map { ($0.id, $0) })
        rows.removeAll(keepingCapacity: true)
        var lastDateLabel: String?
        for thread in snapshot.threads {
            let dateLabel = MailboxPresentation.threadDateLabel(thread.updatedAt)
            if dateLabel != lastDateLabel {
                rows.append(.dateHeader(dateLabel))
                lastDateLabel = dateLabel
            }
            rows.append(.thread(thread.id))
        }
        tableView.reloadData()
        synchronizeSelection()
    }

    func applyAppearance() {
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = RimeUI.surface2.cgColor
        tableView.backgroundColor = .clear
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .dateHeader: return 28
        case .thread: return MailboxThreadListLayout.rowHeight
        }
    }

    func tableView(_ tableView: NSTableView,
                   shouldSelectRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .thread = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case let .dateHeader(title):
            let cell = MailboxDateHeaderCellView()
            cell.configure(title: title)
            return cell
        case let .thread(threadID):
            guard let thread = threadsByID[threadID] else { return nil }
            let cell = MailboxThreadCellView()
            cell.configure(thread: thread, selected: threadID == selectedThreadID)
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection else { return }
        let row = tableView.selectedRow
        guard rows.indices.contains(row), case let .thread(id) = rows[row] else { return }
        onSelectThread?(id)
    }

    private func synchronizeSelection() {
        applyingSelection = true
        defer { applyingSelection = false }
        guard let selectedThreadID,
              let row = rows.firstIndex(where: {
                  if case let .thread(id) = $0 { return id == selectedThreadID }
                  return false
              }) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }
}

private final class MailboxDateHeaderCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = MailboxTerminalTypography.font(ofSize: 9, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String) {
        titleLabel.stringValue = "// \(title)"
        titleLabel.textColor = RimeUI.textSecondary
    }
}

private final class MailboxThreadCellView: NSTableCellView {
    private let selectionRail = NSView()
    private let sequenceLabel = NSTextField(labelWithString: "")
    private let sourceLabel = NSTextField(labelWithString: "")
    private let unreadLabel = NSTextField(labelWithString: "NEW")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 0

        selectionRail.wantsLayer = true
        selectionRail.translatesAutoresizingMaskIntoConstraints = false
        sequenceLabel.font = MailboxTerminalTypography.font(ofSize: 10, weight: .semibold)
        sequenceLabel.alignment = .left
        sequenceLabel.setContentHuggingPriority(.required, for: .horizontal)
        sequenceLabel.translatesAutoresizingMaskIntoConstraints = false
        sequenceLabel.widthAnchor.constraint(equalToConstant: 34).isActive = true
        sourceLabel.font = MailboxTerminalTypography.font(ofSize: 11, weight: .semibold)
        sourceLabel.alignment = .left
        sourceLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        unreadLabel.font = MailboxTerminalTypography.font(ofSize: 8, weight: .bold)
        unreadLabel.alignment = .right
        unreadLabel.setContentHuggingPriority(.required, for: .horizontal)

        let heading = NSStackView(views: [
            sequenceLabel,
            sourceLabel,
            MailboxPresentation.spacer(),
            unreadLabel,
        ])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 6
        heading.translatesAutoresizingMaskIntoConstraints = false
        addSubview(selectionRail)
        addSubview(heading)
        NSLayoutConstraint.activate([
            selectionRail.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectionRail.topAnchor.constraint(equalTo: topAnchor),
            selectionRail.bottomAnchor.constraint(equalTo: bottomAnchor),
            selectionRail.widthAnchor.constraint(equalToConstant: 2),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            heading.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            heading.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(thread: MailboxThread, selected: Bool) {
        sequenceLabel.stringValue = thread.sequenceLabel
        sourceLabel.stringValue = thread.title?.isEmpty == false
            ? thread.title!
            : thread.source.displayName
        unreadLabel.isHidden = !thread.unread
        unreadLabel.textColor = RimeUI.accentTextColor
        selectionRail.layer?.backgroundColor = selected
            ? RimeUI.accentGreen.cgColor
            : NSColor.clear.cgColor
        sequenceLabel.textColor = selected ? RimeUI.accentTextColor : RimeUI.textSecondary
        sourceLabel.textColor = selected ? RimeUI.accentTextColor : RimeUI.textPrimary
        layer?.backgroundColor = selected
            ? RimeUI.accentGreen.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
        let unreadSummary = thread.unread ? "，未读" : ""
        setAccessibilityLabel(
            "\(thread.sequenceLabel)，\(sourceLabel.stringValue)\(unreadSummary)"
        )
    }

    fileprivate var accessibilitySummaryForSmoke: String? { accessibilityLabel() }
    fileprivate var contentRowCountForSmoke: Int {
        subviews.filter { $0 !== selectionRail }.count
    }
}

private final class MailboxConversationViewController: NSViewController {
    private let store: MailboxStore
    private let interactionBridge: MailboxInteractionBridge

    private let sourceLabel = NSTextField(labelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")
    private let headerStateLabel = NSTextField(labelWithString: "LOCAL · SAVED")
    private let headerSeparator = NSView()
    private let transcriptScrollView = NSScrollView()
    private let messageStack = MailboxFlippedStackView()
    private let reviewBar = NSView()
    private let reviewSeparator = NSView()
    private let reviewLabel = NSTextField(labelWithString: "")
    private let acceptButton = NSButton(title: "加入 Buffer", target: nil, action: nil)
    private let rejectButton = NSButton(title: "拒绝", target: nil, action: nil)
    private let composerContainer = NSView()
    private let composerSeparator = NSView()
    private let composerPromptLabel = NSTextField(labelWithString: ">")
    private let composerField = NSTextField()
    private let composerStatusLabel = NSTextField(labelWithString: "")
    private let composerStatusRow = NSStackView()

    private var currentThread: MailboxThread?
    private var currentPreview: MailboxGenerationPreview?
    private weak var streamingPreviewRow: MailboxMessageRowView?
    private weak var transcriptTailSpacer: NSView?
    private var drafts: [UUID: String] = [:]
    private var isSendingReply = false
    private var scheduledTailFollowGeneration: UInt64 = 0

    init(store: MailboxStore, interactionBridge: MailboxInteractionBridge) {
        self.store = store
        self.interactionBridge = interactionBridge
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        let header = makeHeader()
        configureTranscript()
        configureReviewBar()
        configureComposer()

        let vertical = NSStackView(views: [header, transcriptScrollView, reviewBar, composerContainer])
        vertical.orientation = .vertical
        vertical.alignment = .width
        vertical.spacing = 0
        vertical.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(vertical)
        NSLayoutConstraint.activate([
            vertical.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            vertical.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            vertical.topAnchor.constraint(equalTo: root.topAnchor),
            vertical.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            header.heightAnchor.constraint(equalToConstant: 48),
            transcriptScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        view = root
        reviewBar.isHidden = true
    }

    func apply(thread: MailboxThread?,
               persistence: MailboxPersistenceAvailability,
               preview: MailboxGenerationPreview? = nil) {
        let previousThread = currentThread
        let previousPreview = currentPreview
        let previousThreadID = currentThread?.id
        let changedThread = previousThreadID != thread?.id
        let shouldFollowTail = changedThread
            || isTranscriptPinnedToBottom()
        if let previousThreadID, previousThreadID != thread?.id {
            drafts[previousThreadID] = composerField.stringValue
        }
        currentThread = thread
        currentPreview = preview

        guard let thread else {
            sourceLabel.stringValue = "mailbox / select"
            metadataLabel.stringValue = "选择左侧会话"
            headerStateLabel.stringValue = MailboxPresentation.persistenceState(persistence)
            rebuildMessages([],
                            emptyTitle: "暂无会话",
                            emptyDetail: MailboxPresentation.persistenceDetail(persistence),
                            followTail: shouldFollowTail)
            composerField.stringValue = ""
            composerField.isEnabled = false
            composerField.setAccessibilityLabel("Mailbox 命令行输入")
            reviewBar.isHidden = true
            composerStatusLabel.stringValue = MailboxPresentation.persistenceDetail(persistence)
            composerStatusRow.isHidden = composerStatusLabel.stringValue.isEmpty
            return
        }

        sourceLabel.stringValue = "mailbox / \(MailboxPresentation.sourceSlug(thread.source.kind)) / \(thread.sequenceLabel)"
        let modelSuffix = thread.source.model.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
        metadataLabel.stringValue = "\(thread.source.displayName) · \(MailboxPresentation.headerDateLabel(thread.updatedAt))\(modelSuffix)"
        headerStateLabel.stringValue = preview == nil
            ? MailboxPresentation.persistenceState(persistence)
            : "LIVE · STREAMING"
        if previousThread?.id == thread.id,
           previousThread?.messages == thread.messages,
           updateStreamingPreview(
               from: previousPreview,
               to: preview,
               followTail: shouldFollowTail
           ) {
            // Durable rows keep their AppKit identity while only the active
            // process-local preview changes. This preserves selections and
            // avoids reparsing/re-laying out the whole transcript per token.
        } else {
            rebuildMessages(
                thread.messages,
                preview: preview,
                followTail: shouldFollowTail,
                preserveInterveningScroll: !changedThread
            )
        }
        if previousThreadID != thread.id {
            composerField.stringValue = drafts[thread.id] ?? ""
        }
        refreshReviewState()
        configureComposerState(for: thread, persistence: persistence)
    }

    func refreshReviewState() {
        guard isViewLoaded, let thread = currentThread,
              !thread.source.kind.isAIConnector,
              let pending = interactionBridge.pendingInboundItem(threadID: thread.id) else {
            reviewBar.isHidden = true
            return
        }
        reviewBar.isHidden = false
        if pending.streaming {
            reviewLabel.stringValue = "! review · 外部内容仍在接收，完成后才可加入 Buffer。"
        } else if pending.pluginMetadata?.stale == true {
            reviewLabel.stringValue = "! review · 原目标已变化；加入后将作为普通文本处理。"
        } else {
            reviewLabel.stringValue = "! review · 外部推送需要你明确审核。"
        }
        acceptButton.isEnabled = InboundBus.shared.canAccept(pending.id)
        acceptButton.toolTip = pending.streaming ? "等待外部来源结束推送" : nil
    }

    func applyAppearance() {
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = RimeUI.surface.cgColor
        sourceLabel.textColor = RimeUI.textPrimary
        metadataLabel.textColor = RimeUI.textMuted
        headerStateLabel.textColor = RimeUI.accentTextColor
        headerSeparator.layer?.backgroundColor = RimeUI.border.cgColor
        transcriptScrollView.backgroundColor = RimeUI.surface
        reviewBar.layer?.backgroundColor = RimeUI.surface2.cgColor
        reviewSeparator.layer?.backgroundColor = RimeUI.border.cgColor
        reviewLabel.textColor = RimeUI.textSecondary
        composerContainer.layer?.backgroundColor = RimeUI.surface2.cgColor
        composerSeparator.layer?.backgroundColor = RimeUI.border.cgColor
        composerPromptLabel.textColor = RimeUI.accentTextColor
        composerField.backgroundColor = .clear
        composerField.textColor = RimeUI.textPrimary
        acceptButton.bezelColor = RimeUI.accentGreen
        acceptButton.contentTintColor = RimeUI.accentForegroundColor
        rebuildMessages(
            currentThread?.messages ?? [],
            preview: currentPreview,
            followTail: isTranscriptPinnedToBottom()
        )
    }

    private func makeHeader() -> NSView {
        sourceLabel.font = MailboxTerminalTypography.font(ofSize: 13, weight: .semibold)
        metadataLabel.font = MailboxTerminalTypography.font(ofSize: 9)
        let copy = NSStackView(views: [sourceLabel, metadataLabel])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 2

        headerStateLabel.font = MailboxTerminalTypography.font(ofSize: 9, weight: .medium)
        headerStateLabel.alignment = .right
        headerStateLabel.setContentHuggingPriority(.required, for: .horizontal)

        let header = NSView()
        header.wantsLayer = true
        headerSeparator.wantsLayer = true
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [copy, MailboxPresentation.spacer(), headerStateLabel])
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(row)
        header.addSubview(headerSeparator)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerSeparator.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerSeparator.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            headerSeparator.heightAnchor.constraint(equalToConstant: 1),
        ])
        return header
    }

    private func configureTranscript() {
        transcriptScrollView.drawsBackground = true
        transcriptScrollView.hasVerticalScroller = true
        transcriptScrollView.autohidesScrollers = true
        transcriptScrollView.setAccessibilityLabel("Mailbox 会话内容")

        Self.configureMessageStack(messageStack)
        transcriptScrollView.documentView = messageStack
        NSLayoutConstraint.activate([
            messageStack.widthAnchor.constraint(equalTo: transcriptScrollView.contentView.widthAnchor),
            messageStack.heightAnchor.constraint(greaterThanOrEqualTo: transcriptScrollView.contentView.heightAnchor),
        ])
    }

    private func configureReviewBar() {
        reviewBar.wantsLayer = true
        reviewSeparator.wantsLayer = true
        reviewSeparator.translatesAutoresizingMaskIntoConstraints = false
        reviewLabel.font = MailboxTerminalTypography.font(ofSize: 10)
        reviewLabel.lineBreakMode = .byTruncatingTail
        acceptButton.target = self
        acceptButton.action = #selector(acceptInboundTapped)
        acceptButton.bezelStyle = .rounded
        acceptButton.font = MailboxTerminalTypography.font(ofSize: 10, weight: .medium)
        acceptButton.setAccessibilityLabel("接受外部推送并加入 Buffer")
        rejectButton.target = self
        rejectButton.action = #selector(rejectInboundTapped)
        rejectButton.bezelStyle = .inline
        rejectButton.font = MailboxTerminalTypography.font(ofSize: 10, weight: .medium)
        rejectButton.setAccessibilityLabel("拒绝外部推送")

        let row = NSStackView(views: [reviewLabel, MailboxPresentation.spacer(), rejectButton, acceptButton])
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        reviewBar.addSubview(reviewSeparator)
        reviewBar.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: reviewBar.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: reviewBar.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: reviewBar.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: reviewBar.bottomAnchor, constant: -8),
            reviewSeparator.leadingAnchor.constraint(equalTo: reviewBar.leadingAnchor),
            reviewSeparator.trailingAnchor.constraint(equalTo: reviewBar.trailingAnchor),
            reviewSeparator.topAnchor.constraint(equalTo: reviewBar.topAnchor),
            reviewSeparator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func configureComposer() {
        composerContainer.wantsLayer = true
        composerSeparator.wantsLayer = true
        composerSeparator.translatesAutoresizingMaskIntoConstraints = false

        composerPromptLabel.font = MailboxTerminalTypography.font(ofSize: 13, weight: .semibold)
        composerPromptLabel.alignment = .center
        composerPromptLabel.setContentHuggingPriority(.required, for: .horizontal)
        composerPromptLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        composerPromptLabel.translatesAutoresizingMaskIntoConstraints = false
        composerField.font = MailboxTerminalTypography.font(ofSize: 12)
        composerField.isBezeled = false
        composerField.drawsBackground = false
        composerField.focusRingType = .none
        composerField.isEditable = true
        composerField.isSelectable = true
        composerField.usesSingleLineMode = true
        composerField.target = self
        composerField.action = #selector(sendTapped)
        composerField.setAccessibilityLabel("Mailbox 命令行输入，按 Return 提交")
        composerField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        composerField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        composerField.translatesAutoresizingMaskIntoConstraints = false

        composerStatusLabel.font = MailboxTerminalTypography.font(ofSize: 9)
        composerStatusLabel.textColor = RimeUI.textMuted
        composerStatusLabel.lineBreakMode = .byTruncatingTail
        composerStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let statusGutter = NSView()
        statusGutter.translatesAutoresizingMaskIntoConstraints = false
        statusGutter.widthAnchor.constraint(
            equalToConstant: MailboxTerminalLayout.bodyLeading
                - MailboxTerminalLayout.outerInset
        ).isActive = true
        composerStatusRow.addArrangedSubview(statusGutter)
        composerStatusRow.addArrangedSubview(composerStatusLabel)
        composerStatusRow.orientation = .horizontal
        composerStatusRow.alignment = .firstBaseline
        composerStatusRow.spacing = 0
        composerStatusRow.isHidden = true

        let inputRow = NSView()
        inputRow.translatesAutoresizingMaskIntoConstraints = false
        inputRow.addSubview(composerPromptLabel)
        inputRow.addSubview(composerField)

        let stack = NSStackView(views: [composerStatusRow, inputRow])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        composerContainer.addSubview(composerSeparator)
        composerContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: composerContainer.leadingAnchor,
                constant: MailboxTerminalLayout.outerInset
            ),
            stack.trailingAnchor.constraint(
                equalTo: composerContainer.trailingAnchor,
                constant: -MailboxTerminalLayout.bodyTrailing
            ),
            stack.topAnchor.constraint(equalTo: composerContainer.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: composerContainer.bottomAnchor, constant: -8),

            inputRow.heightAnchor.constraint(equalToConstant: 28),
            composerPromptLabel.leadingAnchor.constraint(
                equalTo: composerContainer.leadingAnchor,
                constant: MailboxTerminalLayout.markerLeading
            ),
            composerPromptLabel.widthAnchor.constraint(
                equalToConstant: MailboxTerminalLayout.markerWidth
            ),
            composerPromptLabel.firstBaselineAnchor.constraint(
                equalTo: composerField.firstBaselineAnchor
            ),
            composerField.leadingAnchor.constraint(
                equalTo: composerPromptLabel.trailingAnchor,
                constant: MailboxTerminalLayout.gap
            ),
            composerField.heightAnchor.constraint(equalToConstant: 28),
            composerField.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),
            composerField.trailingAnchor.constraint(
                equalTo: composerContainer.trailingAnchor,
                constant: -MailboxTerminalLayout.bodyTrailing
            ),
            composerSeparator.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor),
            composerSeparator.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor),
            composerSeparator.topAnchor.constraint(equalTo: composerContainer.topAnchor),
            composerSeparator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func configureComposerState(for thread: MailboxThread,
                                        persistence: MailboxPersistenceAvailability) {
        let persistenceAvailable: Bool
        switch persistence {
        case .available:
            persistenceAvailable = true
        case let .unavailable(reason):
            persistenceAvailable = false
            composerStatusLabel.stringValue = reason
            composerStatusLabel.textColor = .systemRed
            composerStatusRow.isHidden = false
        }

        if persistenceAvailable {
            composerStatusRow.isHidden = true
        }
        switch thread.source.replyCapability {
        case .localNotesOnly:
            composerPromptLabel.stringValue = "#"
            composerField.placeholderString = "local note… · Return 保存"
            composerField.toolTip = "备注只保存在本机，不会回传给外部来源。"
            composerField.setAccessibilityLabel("本地备注，按 Return 保存")
            composerField.isEnabled = persistenceAvailable
        case .aiContinuation:
            let coordinatorAvailable = interactionBridge.aiReplyCoordinator != nil
            let generating = thread.generation?.phase == .generating
            composerPromptLabel.stringValue = ">"
            composerField.placeholderString = generating
                ? "waiting for response…"
                : "reply to \(MailboxPresentation.sourceSlug(thread.source.kind))… · Return 发送"
            composerField.toolTip = coordinatorAvailable
                ? "发送后会真正回传给当前 AI 连接器。"
                : "AI 连接器尚未接入 Mailbox 续问。"
            composerField.setAccessibilityLabel(
                generating
                    ? "正在等待 AI 返回"
                    : "回复 \(MailboxPresentation.sourceSlug(thread.source.kind))，按 Return 发送"
            )
            composerField.isEnabled = persistenceAvailable && coordinatorAvailable && !generating && !isSendingReply
            if persistenceAvailable,
               thread.generation?.phase == .failed,
               let failure = thread.generation?.failureMessage,
               !failure.isEmpty {
                composerStatusLabel.stringValue = "上次生成失败：\(failure)"
                composerStatusLabel.textColor = .systemRed
                composerStatusRow.isHidden = false
            }
        }
    }

    /// Updates only the process-local row when durable transcript content is
    /// unchanged. Returning false asks the caller for a full rebuild because
    /// the current view tree cannot safely represent the requested transition.
    private func updateStreamingPreview(
        from previous: MailboxGenerationPreview?,
        to preview: MailboxGenerationPreview?,
        followTail: Bool
    ) -> Bool {
        guard isViewLoaded, transcriptTailSpacer != nil else { return false }

        switch (previous, preview) {
        case let (.some(old), .some(new)):
            guard old.threadID == new.threadID,
                  old.generationID == new.generationID,
                  let row = streamingPreviewRow,
                  row.updateStreamingMessage(new.message) else {
                return false
            }
        case let (.none, .some(new)):
            guard streamingPreviewRow == nil,
                  let tail = transcriptTailSpacer,
                  let tailIndex = messageStack.arrangedSubviews.firstIndex(
                    where: { $0 === tail }
                  ) else {
                return false
            }
            let row = MailboxMessageRowView(
                message: new.message,
                streaming: true
            )
            messageStack.insertArrangedSubview(row, at: tailIndex)
            streamingPreviewRow = row
        case (.some, .none):
            guard let row = streamingPreviewRow else { return false }
            messageStack.removeArrangedSubview(row)
            row.removeFromSuperview()
            streamingPreviewRow = nil
        case (.none, .none):
            guard streamingPreviewRow == nil else { return false }
        }

        messageStack.needsLayout = true
        scheduleTailFollow(
            followTail,
            preserveInterveningScroll: true
        )
        return true
    }

    private func rebuildMessages(_ messages: [MailboxMessage],
                                 preview: MailboxGenerationPreview? = nil,
                                 emptyTitle: String = "暂无消息",
                                 emptyDetail: String = "这个会话还没有内容。",
                                 followTail: Bool = true,
                                 preserveInterveningScroll: Bool = true) {
        guard isViewLoaded else { return }
        streamingPreviewRow = nil
        transcriptTailSpacer = nil
        messageStack.arrangedSubviews.forEach { child in
            messageStack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        if messages.isEmpty, preview == nil {
            let title = NSTextField(labelWithString: "> \(emptyTitle)")
            title.font = MailboxTerminalTypography.font(ofSize: 12, weight: .semibold)
            title.textColor = RimeUI.textSecondary
            let detail = NSTextField(wrappingLabelWithString: emptyDetail)
            detail.font = MailboxTerminalTypography.font(ofSize: 10)
            detail.textColor = RimeUI.textMuted
            let empty = NSStackView(views: [title, detail, MailboxPresentation.verticalSpacer()])
            empty.orientation = .vertical
            empty.alignment = .leading
            empty.spacing = 6
            empty.edgeInsets = NSEdgeInsets(top: 18, left: 16, bottom: 16, right: 16)
            messageStack.addArrangedSubview(empty)
        } else {
            for message in messages {
                messageStack.addArrangedSubview(MailboxMessageRowView(message: message))
            }
            if let preview {
                let row = MailboxMessageRowView(
                    message: preview.message,
                    streaming: true
                )
                messageStack.addArrangedSubview(row)
                streamingPreviewRow = row
            }
            // The transcript is pinned to at least the viewport height. Give
            // its unused height to an explicit tail spacer so AppKit never
            // stretches the first message row (most visibly a status card).
            let tail = Self.makeTranscriptTailSpacer()
            messageStack.addArrangedSubview(tail)
            transcriptTailSpacer = tail
        }
        scheduleTailFollow(
            followTail,
            preserveInterveningScroll: preserveInterveningScroll
        )
    }

    /// AppKit may need one run-loop turn to resolve the new intrinsic height.
    /// A monotonically increasing token rejects older queued follows, while the
    /// clip-origin check respects a user who scrolls between update and layout.
    private func scheduleTailFollow(
        _ followTail: Bool,
        preserveInterveningScroll: Bool
    ) {
        scheduledTailFollowGeneration &+= 1
        guard followTail else { return }
        let generation = scheduledTailFollowGeneration
        let scheduledOrigin = transcriptScrollView.contentView.bounds.origin
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.scheduledTailFollowGeneration == generation else {
                return
            }
            if preserveInterveningScroll {
                let currentOrigin = self.transcriptScrollView.contentView.bounds.origin
                guard abs(currentOrigin.x - scheduledOrigin.x) <= 0.5,
                      abs(currentOrigin.y - scheduledOrigin.y) <= 0.5 else {
                    return
                }
            }
            self.scrollToBottom()
        }
    }

    private func isTranscriptPinnedToBottom(tolerance: CGFloat = 24) -> Bool {
        guard isViewLoaded else { return true }
        messageStack.layoutSubtreeIfNeeded()
        let visibleHeight = transcriptScrollView.contentView.bounds.height
        guard visibleHeight > 0 else { return true }
        let bottomOffset = max(0, messageStack.bounds.height - visibleHeight)
        return bottomOffset - transcriptScrollView.contentView.bounds.origin.y
            <= tolerance
    }

    private static func configureMessageStack(_ stack: MailboxFlippedStackView) {
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
    }

    private static func makeTranscriptTailSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        spacer.setContentCompressionResistancePriority(.init(1), for: .vertical)
        return spacer
    }

    fileprivate static func validateTranscriptLayoutForSmoke() -> Bool {
        validateTranscriptLayoutForSmoke(width: 600)
            && validateTranscriptLayoutForSmoke(width: 360)
            && validateLongLineLayoutForSmoke()
    }

    fileprivate static func validateComposerLayoutForSmoke() -> Bool {
        validateComposerLayoutForSmoke(width: 600)
            && validateComposerLayoutForSmoke(width: 360)
    }

    fileprivate static func validateStreamingPreviewForSmoke() -> Bool {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let generation = MailboxGeneration.generating(at: now)
        let previewMessageID = UUID()
        let thread = MailboxThread(
            id: UUID(),
            sequence: 8,
            title: nil,
            source: .codexCLI(),
            messages: [MailboxMessage(
                role: .user,
                author: "你",
                body: "继续",
                createdAt: now
            )],
            generation: generation,
            unread: false,
            createdAt: now,
            updatedAt: now
        )
        let preview = MailboxGenerationPreview(
            threadID: thread.id,
            generationID: generation.id,
            message: MailboxMessage(
                id: previewMessageID,
                role: .inbound,
                author: "Codex",
                body: "streaming partial",
                createdAt: now
            )
        )
        let controller = MailboxConversationViewController(
            store: .shared,
            interactionBridge: .shared
        )
        let host = controller.view
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 450)
        controller.apply(
            thread: thread,
            persistence: .available,
            preview: preview
        )
        host.layoutSubtreeIfNeeded()
        let rows = controller.messageStack.arrangedSubviews.compactMap {
            $0 as? MailboxMessageRowView
        }
        guard rows.count == 2,
              let durableRow = rows.first,
              let firstPreviewRow = rows.last else {
            return false
        }
        let updatedPreview = MailboxGenerationPreview(
            threadID: thread.id,
            generationID: generation.id,
            message: MailboxMessage(
                id: previewMessageID,
                role: .inbound,
                author: "Codex",
                body: "streaming partial, then a longer second snapshot",
                createdAt: now
            )
        )
        controller.apply(
            thread: thread,
            persistence: .available,
            preview: updatedPreview
        )
        host.layoutSubtreeIfNeeded()
        let updatedRows = controller.messageStack.arrangedSubviews.compactMap {
            $0 as? MailboxMessageRowView
        }
        return updatedRows.count == 2
            && updatedRows.first === durableRow
            && updatedRows.last === firstPreviewRow
            && updatedRows.last?.transcriptIsStreamingForSmoke == true
            && updatedRows.last?.transcriptBodyString
                == "streaming partial, then a longer second snapshot"
            && controller.headerStateLabel.stringValue == "LIVE · STREAMING"
            && thread.messages.count == 1
    }

    private static func validateComposerLayoutForSmoke(width: CGFloat) -> Bool {
        let controller = MailboxConversationViewController(
            store: .shared,
            interactionBridge: .shared
        )
        let host = controller.view
        host.frame = NSRect(x: 0, y: 0, width: width, height: 450)
        controller.composerStatusRow.isHidden = true
        host.layoutSubtreeIfNeeded()
        controller.composerContainer.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        let composer = controller.composerContainer
        let promptAlignmentFrame = MailboxTerminalGeometry.alignmentFrame(
            of: controller.composerPromptLabel,
            in: composer
        )
        let fieldFrame = MailboxTerminalGeometry.frame(
            of: controller.composerField,
            in: composer
        )
        let fieldAlignmentFrame = MailboxTerminalGeometry.alignmentFrame(
            of: controller.composerField,
            in: composer
        )
        let promptBaseline = MailboxTerminalGeometry.firstBaselineY(
            of: controller.composerPromptLabel,
            in: composer
        )
        let fieldBaseline = MailboxTerminalGeometry.firstBaselineY(
            of: controller.composerField,
            in: composer
        )

        let valid = abs(composer.frame.width - width) < 0.5
            && abs(promptAlignmentFrame.minX - MailboxTerminalLayout.markerLeading) < 0.5
            && abs(fieldAlignmentFrame.minX - MailboxTerminalLayout.bodyLeading) < 0.5
            && abs(promptBaseline - fieldBaseline) < 0.5
            && abs(fieldFrame.height - 28) < 0.5
            && abs(
                fieldAlignmentFrame.maxX
                    - (width - MailboxTerminalLayout.bodyTrailing)
            ) < 0.5
            && abs(
                fieldAlignmentFrame.width
                    - (width
                        - MailboxTerminalLayout.bodyLeading
                        - MailboxTerminalLayout.bodyTrailing)
            ) < 0.5
            && controller.composerField.focusRingType == .none
            && !controller.composerField.isBezeled
            && !controller.composerField.drawsBackground
            && controller.composerField.isEditable
            && controller.composerField.isSelectable
            && controller.composerField.usesSingleLineMode
            && controller.composerField.target === controller
            && controller.composerField.action == #selector(sendTapped)
            && !MailboxTerminalGeometry.containsButton(in: composer)
            && !host.hasAmbiguousLayout
            && !composer.hasAmbiguousLayout
            && !controller.composerPromptLabel.hasAmbiguousLayout
            && !controller.composerField.hasAmbiguousLayout
        if !valid {
            fputs(
                "mailbox composer width=\(width) container=\(composer.frame.width) "
                    + "promptX=\(promptAlignmentFrame.minX) "
                    + "fieldX=\(fieldAlignmentFrame.minX) "
                    + "baselines=\(promptBaseline)/\(fieldBaseline) "
                    + "field=\(fieldFrame)/\(fieldAlignmentFrame) "
                    + "containsButton=\(MailboxTerminalGeometry.containsButton(in: composer)) "
                    + "ambiguous=\(host.hasAmbiguousLayout)/\(composer.hasAmbiguousLayout)\n",
                stderr
            )
        }
        return valid
    }

    private static func validateTranscriptLayoutForSmoke(width: CGFloat) -> Bool {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 450))
        let stack = MailboxFlippedStackView()
        configureMessageStack(stack)
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])

        let messages = [
            MailboxMessage(
                role: .system,
                kind: .status,
                author: "Mailbox",
                body: "完整返回已进入 Mailbox。"
            ),
            MailboxMessage(
                role: .inbound,
                author: "Claude Code",
                body: "  (\\ /)\n  (.. )\n  (\") (\")"
            ),
            MailboxMessage(
                role: .user,
                author: "你",
                body: "继续处理。"
            ),
        ]
        let rows = messages.map { MailboxMessageRowView(message: $0) }
        rows.forEach(stack.addArrangedSubview)
        let tail = makeTranscriptTailSpacer()
        stack.addArrangedSubview(tail)

        host.layoutSubtreeIfNeeded()
        stack.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        let rowHeights = rows.map(\.frame.height)
        let bodyLeading = rows.map(\.transcriptBodyLeading)
        let bodyWidths = rows.map(\.transcriptBodyWidth)
        let expectedBodyWidth = width
            - MailboxTerminalLayout.bodyLeading
            - MailboxTerminalLayout.bodyTrailing
        let baselinesAligned = rows.allSatisfy { row in
            guard let minimum = row.transcriptFirstBaselines.min(),
                  let maximum = row.transcriptFirstBaselines.max() else {
                return false
            }
            return maximum - minimum <= 0.5
        }
        return rowHeights.allSatisfy { $0 > 20 && $0 < 120 }
            && rows.allSatisfy { abs($0.frame.width - width) < 0.5 }
            && bodyLeading.allSatisfy {
                abs($0 - MailboxTerminalLayout.bodyLeading) < 0.5
            }
            && bodyWidths.allSatisfy { abs($0 - expectedBodyWidth) < 0.5 }
            && baselinesAligned
            && rows.allSatisfy { !$0.transcriptHasAmbiguousLayout }
            && rows[1].transcriptUsesFixedPitchFont
            && rows[1].transcriptBodyString == messages[1].body
            && tail.frame.height > 80
    }

    private static func validateLongLineLayoutForSmoke() -> Bool {
        let width: CGFloat = 360
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 450))
        let stack = MailboxFlippedStackView()
        configureMessageStack(stack)
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])

        let rawBody = String(repeating: "abcdefghij", count: 410)
        let row = MailboxMessageRowView(message: MailboxMessage(
            role: .inbound,
            author: "Codex",
            body: rawBody
        ))
        stack.addArrangedSubview(row)
        stack.addArrangedSubview(makeTranscriptTailSpacer())
        host.layoutSubtreeIfNeeded()
        stack.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        let expectedBodyWidth = width
            - MailboxTerminalLayout.bodyLeading
            - MailboxTerminalLayout.bodyTrailing
        return abs(row.frame.width - width) < 0.5
            && abs(row.transcriptBodyWidth - expectedBodyWidth) < 0.5
            && abs(row.transcriptContainerWidth - row.transcriptBodyWidth) < 0.5
            && row.frame.height > 100
            && row.frame.height < 10_000
            && row.transcriptBodyString == rawBody
            && !row.transcriptHasAmbiguousLayout
    }

    private func scrollToBottom() {
        messageStack.layoutSubtreeIfNeeded()
        let visibleHeight = transcriptScrollView.contentView.bounds.height
        let targetY = max(0, messageStack.bounds.height - visibleHeight)
        transcriptScrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        transcriptScrollView.reflectScrolledClipView(transcriptScrollView.contentView)
    }

    @objc private func sendTapped() {
        guard let thread = currentThread else { return }
        let body = composerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            NSSound.beep()
            return
        }
        hideComposerError()
        switch thread.source.replyCapability {
        case .localNotesOnly:
            do {
                _ = try store.addLocalNote(threadID: thread.id, body: body)
                drafts.removeValue(forKey: thread.id)
                composerField.stringValue = ""
            } catch {
                showComposerError(error.localizedDescription)
            }
        case .aiContinuation:
            guard let coordinator = interactionBridge.aiReplyCoordinator else {
                showComposerError("AI 连接器尚未接入 Mailbox 续问。")
                return
            }
            isSendingReply = true
            configureComposerState(for: thread, persistence: store.snapshot.persistence)
            coordinator.sendMailboxReply(threadID: thread.id, body: body) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isSendingReply = false
                    switch result {
                    case .success:
                        self.drafts.removeValue(forKey: thread.id)
                        if self.currentThread?.id == thread.id {
                            self.composerField.stringValue = ""
                        }
                    case let .failure(error):
                        self.showComposerError(error.localizedDescription)
                    }
                    let snapshot = self.store.snapshot
                    self.apply(
                        thread: snapshot.selectedThreadID.flatMap(snapshot.thread(id:)),
                        persistence: snapshot.persistence,
                        preview: snapshot.selectedThreadID.flatMap(
                            snapshot.generationPreview(threadID:)
                        )
                    )
                }
            }
        }
    }

    @objc private func acceptInboundTapped() {
        guard let thread = currentThread,
              let pending = interactionBridge.pendingInboundItem(threadID: thread.id),
              InboundBus.shared.canAccept(pending.id),
              InboundBus.shared.accept(pending.id) else {
            refreshReviewState()
            NSSound.beep()
            return
        }
        refreshReviewState()
    }

    @objc private func rejectInboundTapped() {
        guard let thread = currentThread,
              let pending = interactionBridge.pendingInboundItem(threadID: thread.id) else {
            refreshReviewState()
            return
        }
        guard InboundBus.shared.reject(pending.id) else {
            refreshReviewState()
            NSSound.beep()
            return
        }
        refreshReviewState()
    }

    private func showComposerError(_ message: String) {
        composerStatusLabel.stringValue = message
        composerStatusLabel.textColor = .systemRed
        composerStatusRow.isHidden = false
        NSSound.beep()
    }

    private func hideComposerError() {
        composerStatusLabel.stringValue = ""
        composerStatusRow.isHidden = true
    }
}

private final class MailboxMessageRowView: NSView {
    private let bodyView: MailboxMessageTextView
    private let timeLabel: NSTextField
    private let sourceLabel: NSTextField
    private let markerLabel: NSTextField
    private let messageID: UUID
    private let bodyStyle: MailboxBodyStyle

    private let streaming: Bool

    init(message: MailboxMessage, streaming: Bool = false) {
        self.streaming = streaming
        let authorText: String
        if message.kind == .localNote {
            authorText = message.author ?? "你"
        } else {
            authorText = message.author ?? MailboxPresentation.defaultAuthor(for: message.role)
        }

        let style: MailboxBodyStyle
        switch message.role {
        case .inbound, .user:
            style = MailboxBodyStyle(
                textColor: RimeUI.textPrimary,
                secondaryTextColor: RimeUI.textSecondary,
                codeTextColor: RimeUI.textPrimary,
                codeBackgroundColor: RimeUI.surface2,
                linkColor: RimeUI.accentTextColor
            )
        case .system:
            style = MailboxBodyStyle(
                textColor: RimeUI.textSecondary,
                secondaryTextColor: RimeUI.textMuted,
                codeTextColor: RimeUI.textSecondary,
                codeBackgroundColor: RimeUI.surface2,
                linkColor: RimeUI.accentTextColor
            )
        }
        messageID = message.id
        bodyStyle = style
        let presentation = MailboxMessageFormatting.presentation(for: message, style: style)
        bodyView = MailboxMessageTextView(presentation: presentation)
        timeLabel = NSTextField(labelWithString: MailboxPresentation.timeLabel(message.createdAt))
        sourceLabel = NSTextField(labelWithString: authorText.uppercased())
        markerLabel = NSTextField(labelWithString: MailboxPresentation.promptMarker(for: message.role))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        timeLabel.font = MailboxTerminalTypography.font(ofSize: 9)
        timeLabel.textColor = RimeUI.textMuted
        timeLabel.alignment = .left
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        sourceLabel.font = MailboxTerminalTypography.font(ofSize: 10, weight: .medium)
        sourceLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.translatesAutoresizingMaskIntoConstraints = false

        markerLabel.font = MailboxTerminalTypography.font(ofSize: 12, weight: .semibold)
        markerLabel.alignment = .center
        markerLabel.translatesAutoresizingMaskIntoConstraints = false

        let formatTitle = streaming
            ? "[live]"
            : MailboxPresentation.terminalFormatLabel(
                for: message,
                presentation: presentation
            )
        let sourceViews: [NSView]
        if let formatTitle {
            let formatLabel = NSTextField(labelWithString: formatTitle)
            formatLabel.font = MailboxTerminalTypography.font(ofSize: 8, weight: .medium)
            formatLabel.textColor = style.secondaryTextColor
            formatLabel.lineBreakMode = .byTruncatingTail
            sourceViews = [sourceLabel, formatLabel]
        } else {
            sourceViews = [sourceLabel]
        }
        let sourceStack = NSStackView(views: sourceViews)
        sourceStack.orientation = .vertical
        sourceStack.alignment = .leading
        sourceStack.spacing = 2
        sourceStack.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = RimeUI.border.withAlphaComponent(0.72).cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(timeLabel)
        addSubview(sourceStack)
        addSubview(markerLabel)
        addSubview(bodyView)
        addSubview(separator)
        NSLayoutConstraint.activate([
            timeLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: MailboxTerminalLayout.outerInset
            ),
            timeLabel.widthAnchor.constraint(equalToConstant: MailboxTerminalLayout.timeWidth),
            timeLabel.firstBaselineAnchor.constraint(equalTo: bodyView.firstBaselineAnchor),

            sourceStack.leadingAnchor.constraint(
                equalTo: timeLabel.trailingAnchor,
                constant: MailboxTerminalLayout.gap
            ),
            sourceStack.widthAnchor.constraint(equalToConstant: MailboxTerminalLayout.sourceWidth),
            sourceStack.bottomAnchor.constraint(lessThanOrEqualTo: separator.topAnchor, constant: -10),
            sourceLabel.firstBaselineAnchor.constraint(equalTo: bodyView.firstBaselineAnchor),

            markerLabel.leadingAnchor.constraint(
                equalTo: sourceStack.trailingAnchor,
                constant: MailboxTerminalLayout.gap
            ),
            markerLabel.widthAnchor.constraint(equalToConstant: MailboxTerminalLayout.markerWidth),
            markerLabel.firstBaselineAnchor.constraint(equalTo: bodyView.firstBaselineAnchor),

            bodyView.leadingAnchor.constraint(
                equalTo: markerLabel.trailingAnchor,
                constant: MailboxTerminalLayout.gap
            ),
            bodyView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -MailboxTerminalLayout.bodyTrailing
            ),
            bodyView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            bodyView.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -11),
            bodyView.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),

            separator.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: MailboxTerminalLayout.outerInset
            ),
            separator.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -MailboxTerminalLayout.bodyTrailing
            ),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])

        switch message.role {
        case .user:
            sourceLabel.textColor = RimeUI.accentTextColor
            markerLabel.textColor = RimeUI.accentTextColor
        case .inbound:
            sourceLabel.textColor = RimeUI.textSecondary
            markerLabel.textColor = RimeUI.accentTextColor
        case .system:
            sourceLabel.textColor = RimeUI.textMuted
            markerLabel.textColor = RimeUI.textMuted
        }
        setAccessibilityRole(.group)
        let formatDescription = formatTitle.map { "，\($0)" } ?? ""
        let streamingDescription = streaming ? "，正在流式返回" : ""
        setAccessibilityLabel(
            "\(authorText)，\(MailboxPresentation.timeLabel(message.createdAt))\(formatDescription)\(streamingDescription)"
        )
        bodyView.setAccessibilityLabel("消息正文")
        bodyView.setAccessibilityValue(message.body)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Streaming previews retain one row and replace only its public body
    /// snapshot. Durable rows are therefore not recreated on every provider
    /// event, preserving text selection and keeping AppKit layout work bounded.
    @discardableResult
    func updateStreamingMessage(_ message: MailboxMessage) -> Bool {
        guard streaming, message.id == messageID else { return false }
        let presentation = MailboxMessageFormatting.presentation(
            for: message,
            style: bodyStyle
        )
        bodyView.textStorage?.setAttributedString(presentation.attributedText)
        bodyView.invalidateIntrinsicContentSize()
        bodyView.needsLayout = true
        needsLayout = true
        bodyView.setAccessibilityValue(message.body)
        return true
    }

    fileprivate var transcriptBodyLeading: CGFloat { bodyView.frame.minX }
    fileprivate var transcriptBodyWidth: CGFloat { bodyView.frame.width }
    fileprivate var transcriptContainerWidth: CGFloat {
        bodyView.textContainer?.containerSize.width ?? 0
    }
    fileprivate var transcriptBodyString: String { bodyView.string }
    fileprivate var transcriptIsStreamingForSmoke: Bool { streaming }
    fileprivate var transcriptFirstBaselines: [CGFloat] {
        [timeLabel, sourceLabel, markerLabel, bodyView].map {
            MailboxTerminalGeometry.firstBaselineY(of: $0, in: self)
        }
    }
    fileprivate var transcriptHasAmbiguousLayout: Bool {
        hasAmbiguousLayout || bodyView.hasAmbiguousLayout
    }
    fileprivate var transcriptUsesFixedPitchFont: Bool {
        guard let storage = bodyView.textStorage, storage.length > 0,
              let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else {
            return false
        }
        return font.isFixedPitch
    }
}

private final class MailboxFlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private enum MailboxPresentation {
    private static let calendar = Calendar.autoupdatingCurrent
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func threadDateLabel(_ date: Date, now: Date = Date()) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "今天" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "昨天" }
        return dayFormatter.string(from: date)
    }

    static func headerDateLabel(_ date: Date, now: Date = Date()) -> String {
        threadDateLabel(date, now: now)
    }

    static func timeLabel(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func defaultAuthor(for role: MailboxMessageRole) -> String {
        switch role {
        case .inbound: return "外部来源"
        case .user: return "你"
        case .system: return "Mailbox"
        }
    }

    static func promptMarker(for role: MailboxMessageRole) -> String {
        switch role {
        case .user: return ">"
        case .inbound: return "|"
        case .system: return "!"
        }
    }

    static func sourceSlug(_ kind: MailboxSourceKind) -> String {
        switch kind {
        case .codexCLI: return "codex"
        case .claudeCodeCLI: return "claude-code"
        case .openAICompatible: return "openai"
        case .mcp: return "mcp"
        case .http: return "http"
        case .sse: return "sse"
        case .ssh: return "ssh"
        case .plugin: return "plugin"
        case .other: return "external"
        }
    }

    static func terminalFormatLabel(for message: MailboxMessage,
                                    presentation: MailboxBodyPresentation) -> String? {
        if message.kind == .localNote { return "[local]" }
        if message.kind == .status { return "[event]" }
        switch presentation.kind {
        case .prose: return nil
        case .preformatted: return "[pre]"
        case .markdown: return "[md]"
        case .json: return "[json]"
        }
    }

    static func persistenceDetail(_ availability: MailboxPersistenceAvailability) -> String {
        switch availability {
        case .available:
            return "完成的会话会保存在本机。"
        case let .unavailable(reason):
            return reason
        }
    }

    static func persistenceState(_ availability: MailboxPersistenceAvailability) -> String {
        switch availability {
        case .available: return "LOCAL · SAVED"
        case .unavailable: return "LOCAL · ERROR"
        }
    }

    static func spacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    static func verticalSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        spacer.setContentCompressionResistancePriority(.init(1), for: .vertical)
        return spacer
    }
}

enum MailboxPaneVisualSmoke {
    static func validate() -> Bool {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldDate = Date(timeIntervalSince1970: 0)
        let transcript = MailboxConversationViewController
            .validateTranscriptLayoutForSmoke()
        let composer = MailboxConversationViewController
            .validateComposerLayoutForSmoke()
        let streaming = MailboxConversationViewController
            .validateStreamingPreviewForSmoke()
        let compactThreads = validateCompactThreadRows(now: now)
        let progressProjection = validateProgressProjectionRules(now: now)
        let formatting = validateMessageFormatting()
        let relativeDate = MailboxPresentation.headerDateLabel(now, now: now) == "今天"
            && MailboxPresentation.headerDateLabel(oldDate, now: now).contains("月")
        if !transcript { fputs("mailbox visual smoke: transcript layout\n", stderr) }
        if !composer { fputs("mailbox visual smoke: composer layout\n", stderr) }
        if !streaming { fputs("mailbox visual smoke: streaming preview\n", stderr) }
        if !compactThreads { fputs("mailbox visual smoke: compact thread rows\n", stderr) }
        if !progressProjection { fputs("mailbox visual smoke: progress projection\n", stderr) }
        if !formatting { fputs("mailbox visual smoke: message formatting\n", stderr) }
        if !relativeDate { fputs("mailbox visual smoke: relative date\n", stderr) }
        return transcript && composer && streaming && compactThreads
            && progressProjection
            && formatting && relativeDate
    }

    private static func validateProgressProjectionRules(now: Date) -> Bool {
        let generation = MailboxGeneration.generating(at: now)
        let active = MailboxThread(
            id: UUID(),
            sequence: 1,
            title: nil,
            source: .codexCLI(),
            messages: [MailboxMessage(
                role: .user,
                author: "你",
                body: "prompt",
                createdAt: now
            )],
            generation: generation,
            unread: false,
            createdAt: now,
            updatedAt: now
        )
        let current = MailboxStoreSnapshot(
            revision: 1,
            threads: [active],
            selectedThreadID: active.id,
            persistence: .available
        )
        let preview = MailboxGenerationPreview(
            threadID: active.id,
            generationID: generation.id,
            message: MailboxMessage(
                role: .inbound,
                author: "Codex",
                body: "partial",
                createdAt: now
            )
        )
        let previewOnly = MailboxStoreSnapshot(
            revision: 2,
            threads: [active],
            selectedThreadID: active.id,
            persistence: .available,
            generationPreviews: [active.id: preview]
        )
        guard !MailboxPaneStateRules.generationProgressRequiresFullApply(
            current: current,
            incoming: previewOnly,
            progressedThreadID: active.id
        ) else {
            return false
        }

        let inbound = MailboxThread(
            id: UUID(),
            sequence: 2,
            title: nil,
            source: .http(source: "HTTP Push"),
            messages: [MailboxMessage(
                role: .inbound,
                author: "HTTP Push",
                body: "new durable message",
                createdAt: now
            )],
            generation: nil,
            unread: true,
            createdAt: now,
            updatedAt: now
        )
        let carriesDurableChange = MailboxStoreSnapshot(
            revision: 3,
            threads: [inbound, active],
            selectedThreadID: active.id,
            persistence: .available,
            generationPreviews: [active.id: preview]
        )
        return MailboxPaneStateRules.generationProgressRequiresFullApply(
            current: current,
            incoming: carriesDurableChange,
            progressedThreadID: active.id
        )
    }

    private static func validateCompactThreadRows(now: Date) -> Bool {
        let thread = MailboxThread(
            id: UUID(),
            sequence: 5,
            title: nil,
            source: .codexCLI(),
            messages: [MailboxMessage(
                role: .inbound,
                author: "Codex",
                body: "右侧已经完整展示的回复摘要",
                createdAt: now
            )],
            generation: nil,
            review: nil,
            unread: true,
            createdAt: now,
            updatedAt: now
        )
        let selected = MailboxThreadCellView()
        selected.configure(thread: thread, selected: true)
        let standard = MailboxThreadCellView()
        standard.configure(thread: thread, selected: false)
        let expectedAccessibility = "#05，Codex，未读"
        return MailboxThreadListLayout.rowHeight == 40
            && selected.contentRowCountForSmoke == 1
            && standard.contentRowCountForSmoke == 1
            && selected.accessibilitySummaryForSmoke == expectedAccessibility
            && standard.accessibilitySummaryForSmoke == expectedAccessibility
    }

    private static func validateMessageFormatting() -> Bool {
        let style = MailboxBodyStyle(
            textColor: .labelColor,
            secondaryTextColor: .secondaryLabelColor,
            codeTextColor: .labelColor,
            codeBackgroundColor: .quaternaryLabelColor,
            linkColor: .linkColor
        )
        let ascii = MailboxMessage(
            role: .inbound,
            body: "(\\ /)\n(.. )\n(\") (\")"
        )
        let markdown = MailboxMessage(
            role: .inbound,
            format: .markdown,
            body: "# 标题\n\n- 第一项\n- `second()`\n\n```swift\nlet answer = 42\n```"
        )
        let json = MailboxMessage(
            role: .inbound,
            format: .json,
            body: #"{"ok":true,"items":[1,2]}"#
        )
        let asciiPresentation = MailboxMessageFormatting.presentation(for: ascii, style: style)
        let markdownPresentation = MailboxMessageFormatting.presentation(for: markdown, style: style)
        let jsonPresentation = MailboxMessageFormatting.presentation(for: json, style: style)

        let markdownCodeRange = (markdownPresentation.attributedText.string as NSString)
            .range(of: "second()")
        let markdownHeadingRange = (markdownPresentation.attributedText.string as NSString)
            .range(of: "标题")
        let markdownCodeFont = markdownCodeRange.location == NSNotFound
            ? nil
            : markdownPresentation.attributedText.attribute(
                .font,
                at: markdownCodeRange.location,
                effectiveRange: nil
            ) as? NSFont
        let markdownHeadingFont = markdownHeadingRange.location == NSNotFound
            ? nil
            : markdownPresentation.attributedText.attribute(
                .font,
                at: markdownHeadingRange.location,
                effectiveRange: nil
            ) as? NSFont
        let jsonFont = jsonPresentation.attributedText.length == 0
            ? nil
            : jsonPresentation.attributedText.attribute(
                .font,
                at: 0,
                effectiveRange: nil
            ) as? NSFont

        return asciiPresentation.kind == .preformatted
            && markdownPresentation.kind == .markdown
            && markdownPresentation.formatBadgeTitle == "Markdown"
            && markdownPresentation.attributedText.string.contains("标题")
            && !markdownPresentation.attributedText.string.contains("```")
            && markdownCodeFont?.isFixedPitch == true
            && markdownHeadingFont?.isFixedPitch == true
            && jsonPresentation.kind == .json
            && jsonPresentation.formatBadgeTitle == "JSON"
            && jsonFont?.isFixedPitch == true
            && jsonPresentation.attributedText.string.contains("\n  \"items\"")
            && MailboxMessageFormatting.collapseWhitespace("  a\n\t b  ") == "a b"
    }
}
