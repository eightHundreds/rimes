import AppKit
import Foundation

enum CapsulePasswordUnlockChord {
    /// The access contract is a sequence of separately settled chord batches.
    /// Its concrete shape is intentionally never included in UI, tooltips or
    /// runtime logs.
    private static let steps: [Set<Int32>] = [
        [0x72, 0x68],
        [0x77, 0x6f],
        [0x63, 0x76, 0x6e],
        [0x71, 0x75],
    ]
    static let stepCount = steps.count
    private static let keycodes = Set(steps.flatMap { $0 })

    static func accepts(keycode: Int32) -> Bool {
        keycodes.contains(keycode)
    }

    static func matches(_ keys: [(keycode: Int32, mask: Int32)],
                        step: Int) -> Bool {
        guard steps.indices.contains(step),
              keys.count == steps[step].count,
              keys.allSatisfy({ key in
                  key.mask & (
                    RimeKey.controlMask
                        | RimeKey.altMask
                        | RimeKey.superMask
                        | RimeKey.shiftMask
                        | RimeKey.releaseMask
                  ) == 0
              }) else { return false }
        return Set(keys.map(\.keycode)) == steps[step]
    }
}

private enum CapsuleKindSelectionStore {
    static let key = "capsule.selected-kind.v1"

    static var selected: CapsuleEntryKind {
        get {
            UserDefaults.standard.string(forKey: key)
                .flatMap(CapsuleEntryKind.init(rawValue:)) ?? .memory
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// Local-first Capsule workspace. Prompt, Memory and Skill entries are normal
/// reviewed text and use the shared Buffer delivery coordinator. Passwords are
/// the sole exception: only their title is searchable and an explicit local
/// authorization prompt may issue a target-bound, one-shot delivery permit.
final class CapsuleWorkspace: DerivedBufferWorkspace,
                              DerivedResultSelectionControls,
                              DerivedOptionPickerControls,
                              WorkbenchProtectedDeliveryControls {
    static let shared = CapsuleWorkspace()
    static let pluginKey = PluginKey(
        domain: .builtIn,
        rawID: BuiltInPluginID.capsule
    )
    static let processorID = "capsule"
    static let searchDebounce: TimeInterval = 0.060
    static let unlockLifetime: TimeInterval = 60

    struct Candidate: Equatable {
        let id: UUID
        let type: CapsuleEntryKind
        let title: String
        /// Plaintext delivery body for ordinary entries. Password candidates
        /// never carry a payload in the workspace.
        let payload: String?
        let snippet: String
    }

    struct QuerySignature: Equatable {
        let text: String
        let kind: CapsuleEntryKind
        let blockIDs: [UUID]
        let changeCount: Int
        let allowsRemoteMirror: Bool
    }

    struct Dependencies {
        let search: (String, CapsuleEntryKind, Int) throws -> [Candidate]
        let passwordRecord: (UUID) throws -> CapsulePasswordRecord
        let createContent: (CapsuleContentWriteRequest) throws
            -> CapsuleContentSummary
        let performBackground: (@escaping () -> Void) -> Void

        static let live = Dependencies(
            search: { query, kind, limit in
                let boundedLimit = min(max(limit, 1), 20)
                if kind == .password {
                    return try CapsulePasswordStore.shared.search(
                        query,
                        limit: boundedLimit
                    ).map { summary in
                        Candidate(
                            id: summary.id,
                            type: .password,
                            title: summary.title,
                            payload: nil,
                            snippet: summary.maskedPassword
                        )
                    }
                }
                return try CapsuleContentStore.shared.search(
                    query,
                    kind: kind,
                    limit: boundedLimit
                ).map { record in
                    Candidate(
                        id: record.summary.id,
                        type: record.summary.type,
                        title: record.summary.title,
                        payload: record.content,
                        snippet: record.snippet
                    )
                }
            },
            passwordRecord: { id in
                try CapsulePasswordStore.shared.record(id: id)
            },
            createContent: { request in
                try CapsuleContentStore.shared.put(request)
            },
            performBackground: { work in
                DispatchQueue.global(qos: .userInitiated).async(execute: work)
            }
        )
    }

    enum Phase: Equatable {
        case idle
        case waiting
        case searching
        case creating(CapsuleEntryKind)
        case ready
        case failed(String)
    }

    enum UnlockChordResult: Equatable {
        case notMatched
        case progressed
        case rejected
        case delivered
        case deliveryFailed
    }

    private enum CreateAction: CaseIterable {
        case memory
        case prompt
        case skill

        var id: UUID {
            switch self {
            case .memory:
                return UUID(uuidString: "ca950001-0000-4000-8000-000000000001")!
            case .prompt:
                return UUID(uuidString: "ca950001-0000-4000-8000-000000000002")!
            case .skill:
                return UUID(uuidString: "ca950001-0000-4000-8000-000000000003")!
            }
        }

        var kind: CapsuleEntryKind {
            switch self {
            case .memory: return .memory
            case .prompt: return .prompt
            case .skill: return .skill
            }
        }

        var label: String { "＋ \(kind.displayName)" }
    }

    private struct UnlockSession: Equatable {
        let recordID: UUID
        let query: QuerySignature
        var completedSteps: Int
        let expiresAt: CFAbsoluteTime
    }

    private struct DeliveryLease: Equatable {
        let candidate: Candidate
        let query: QuerySignature
    }

    let workspacePluginKey = CapsuleWorkspace.pluginKey
    let workbenchDisplayName = "Capsule"

    private let sourceModel: BufferModel
    private let selected: () -> Bool
    private let dependencies: Dependencies
    private let persistSelectedKind: (CapsuleEntryKind) -> Void
    private var observers: [NSObjectProtocol] = []
    private var searchTimer: Timer?
    private var unlockTimer: Timer?
    private var started = false
    private var protectedSession = false
    private var selectedKind: CapsuleEntryKind
    private var searchRevision: UInt64 = 0
    private var generation: UInt64 = 0
    private var candidates: [Candidate] = []
    private var selectedPosition = 0
    private var readyQuery: QuerySignature?
    private var unlockSession: UnlockSession?
    private var deliveryLease: DeliveryLease?
    private(set) var phase: Phase = .idle

    init(sourceModel: BufferModel = .shared,
         selected: @escaping () -> Bool = {
            BufferPluginSelectionStore.shared.isSelected(
                CapsuleWorkspace.pluginKey
            )
         },
         dependencies: Dependencies = .live,
         initialKind: CapsuleEntryKind? = nil,
         persistSelectedKind: @escaping (CapsuleEntryKind) -> Void = {
             CapsuleKindSelectionStore.selected = $0
         }) {
        self.sourceModel = sourceModel
        self.selected = selected
        self.dependencies = dependencies
        selectedKind = initialKind ?? CapsuleKindSelectionStore.selected
        self.persistSelectedKind = persistSelectedKind
    }

    private var isSelected: Bool { selected() }
    private var isActive: Bool {
        started && isSelected && sourceModel.active && !protectedSession
    }

    var statusText: String {
        if let session = currentUnlockSession() {
            return "请输入访问密钥 · \(session.completedSteps)/\(CapsulePasswordUnlockChord.stepCount)"
        }
        if protectedSession {
            return "安全输入已开启"
        }
        if !sourceModel.active { return "请先开启缓冲区" }
        switch phase {
        case .idle:
            return "输入标题或内容搜索 \(selectedKind.displayName)"
        case .waiting: return "等待输入停顿"
        case .searching:
            return "正在本地搜索 \(selectedKind.displayName)"
        case let .creating(kind): return "正在添加 \(kind.displayName)"
        case .ready:
            if candidates.isEmpty {
                return availableCreateActions().isEmpty
                    ? "没有匹配 \(selectedKind.displayName)"
                    : "没有匹配 \(selectedKind.displayName)；可在原地添加"
            }
            if selectedCandidate?.type == .password {
                return "选择密码后点击上屏，并输入访问密钥"
            }
            return "选择条目后可直接上屏"
        case let .failed(message): return message
        }
    }

    // MARK: Workspace option picker

    var optionPickerOptions: [DerivedOptionPickerOption] {
        CapsuleEntryKind.allCases.map {
            DerivedOptionPickerOption(identifier: $0.rawValue,
                                      title: $0.displayName)
        }
    }

    var selectedOptionPickerID: String { selectedKind.rawValue }
    var optionPickerToolTip: String { "只搜索所选 Capsule 类型" }

    @discardableResult
    func setOptionPickerSelection(_ identifier: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let kind = CapsuleEntryKind(rawValue: identifier) else {
            return false
        }
        guard kind != selectedKind else { return true }
        selectedKind = kind
        persistSelectedKind(kind)
        generation &+= 1
        searchRevision &+= 1
        searchTimer?.invalidate()
        searchTimer = nil
        clearReadyState(cancelUnlock: true)
        if isActive {
            scheduleSearch()
        } else {
            phase = .idle
            notifyChange()
        }
        return true
    }

    var railSnapshot: TranslationRailSnapshot {
        let railPhase: TranslationRailSnapshot.Phase
        let message: String?
        switch phase {
        case .idle:
            railPhase = .idle
            message = nil
        case .waiting:
            railPhase = .waiting
            message = nil
        case .searching, .creating:
            railPhase = .translating
            message = nil
        case .ready:
            railPhase = .ready
            message = nil
        case let .failed(value):
            railPhase = .failed
            message = value
        }

        let rows: [TranslationOutputRow]
        if phase == .ready, candidates.isEmpty {
            let actions = availableCreateActions()
            let blocks = actions.enumerated().map { position, action in
                TranslationOutputBlock(
                    id: action.id,
                    text: action.label,
                    ordinal: nil,
                    selected: position == selectedPosition
                )
            }
            rows = blocks.isEmpty ? [] : [
                TranslationOutputRow(key: 0xCA950001, blocks: blocks),
            ]
        } else {
            rows = candidates.enumerated().map { position, candidate in
                TranslationOutputRow(
                    key: candidate.id.hashValue,
                    blocks: [
                        TranslationOutputBlock(
                            id: candidate.id,
                            text: Self.presentationText(for: candidate),
                            ordinal: candidates.count > 1 ? position + 1 : nil,
                            selected: phase == .ready
                                && position == selectedPosition
                        ),
                    ]
                )
            }
        }
        return TranslationRailSnapshot(
            sourceText: sourceModel.stagedText,
            sourceSelected: sourceModel.allContentSelected,
            outputBlocks: rows.flatMap(\.blocks),
            outputRows: rows.isEmpty ? nil : rows,
            phase: railPhase,
            message: message,
            sourceRole: "查",
            targetRole: "囊",
            sourceEmptyText: "输入标题或内容",
            targetEmptyText: "等待 Capsule 条目",
            waitingText: "等待输入停顿",
            processingText: phaseCreatingText ?? "正在本地搜索",
            updatingText: "更新搜索结果"
        )
    }

    var ownsResultNavigation: Bool { isActive }

    // MARK: BufferDeliveryContentSource

    var deliveryWorkspaceID: String { "capsule" }
    var deliveryGeneration: UInt64 { generation }
    var hasIncompleteDeliveryBlocks: Bool {
        guard isActive else { return false }
        switch phase {
        case .waiting, .searching, .creating: return true
        default: return false
        }
    }

    var deliveryPendingBlocks: [BufferModel.Block] {
        guard phase == .ready,
              currentQuerySignatureMatchesReadyState,
              let candidate = deliveryLease?.candidate ?? selectedCandidate,
              candidate.type != .password,
              let payload = candidate.payload,
              !payload.isEmpty,
              let query = deliveryLease?.query ?? readyQuery else {
            return []
        }
        return [makeDeliveryBlock(candidate, query: query)]
    }

    @discardableResult
    func prepareForDelivery() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isActive,
              phase == .ready,
              currentQuerySignatureMatchesReadyState,
              let candidate = selectedCandidate,
              candidate.type != .password,
              candidate.payload?.isEmpty == false,
              let readyQuery else {
            return false
        }
        if let deliveryLease {
            return deliveryLease.candidate.id == candidate.id
                && deliveryLease.query == currentQuerySignature()
        }
        deliveryLease = DeliveryLease(candidate: candidate, query: readyQuery)
        clearUnlockSession()
        generation &+= 1
        notifyChange()
        return true
    }

    func deliveryBlock(id: UUID, generation: UInt64) -> BufferModel.Block? {
        guard self.generation == generation,
              isActive,
              phase == .ready,
              let lease = deliveryLease,
              lease.candidate.id == id,
              lease.query == currentQuerySignature(),
              lease.candidate.type != .password,
              lease.candidate.payload?.isEmpty == false else {
            return nil
        }
        return makeDeliveryBlock(lease.candidate, query: lease.query)
    }

    func consumeDelivered(blockIDs: [UUID], generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard self.generation == generation,
              let lease = deliveryLease,
              blockIDs.contains(lease.candidate.id),
              lease.query == currentQuerySignature() else {
            return
        }
        let queryBlockIDs = lease.query.blockIDs
        clearReadyState(cancelUnlock: true)
        self.generation &+= 1
        sourceModel.consumeDelivered(blockIDs: queryBlockIDs)
        notifyChange()
    }

    func markDeliveryBlockStale(id _: UUID, generation _: UInt64) -> Bool {
        false
    }

    // MARK: Lifecycle and selection

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .bufferModelDidChange,
            object: sourceModel,
            queue: .main
        ) { [weak self] _ in self?.sourceDidChange() })
        observers.append(center.addObserver(
            forName: .activeBufferPluginDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.selectionDidChange() })
        if isActive { scheduleSearch() }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard started else { return }
        started = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        tombstone(cancelUnlock: true)
    }

    func setProtected(_ protected: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard protectedSession != protected else { return }
        protectedSession = protected
        searchRevision &+= 1
        searchTimer?.invalidate()
        searchTimer = nil
        if protected {
            // Retain only password record identity/query authority for the
            // brief prompted handoff into a secure field. Ordinary payloads
            // leave RAM, while the short-lived prompt contains no plaintext.
            clearReadyState(cancelUnlock: false)
            phase = .idle
            notifyChange()
        } else if isActive {
            scheduleSearch()
        } else {
            notifyChange()
        }
    }

    func workbenchWillPause() {
        dispatchPrecondition(condition: .onQueue(.main))
        searchRevision &+= 1
        searchTimer?.invalidate()
        searchTimer = nil
        clearReadyState(cancelUnlock: true)
        phase = .idle
        notifyChange()
    }

    @discardableResult
    func requestRefresh() -> Bool {
        guard isActive else { return false }
        scheduleSearch()
        return true
    }

    @discardableResult
    func moveResultSelection(delta: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard ownsResultNavigation, phase == .ready,
              deliveryLease == nil else { return false }
        let count = candidates.isEmpty
            ? availableCreateActions().count
            : candidates.count
        guard count > 1 else { return true }
        let next = min(max(selectedPosition + delta, 0), count - 1)
        if candidates.isEmpty {
            selectedPosition = next
            notifyChange()
        } else {
            selectCandidate(at: next)
        }
        return true
    }

    @discardableResult
    func selectResult(blockID: UUID) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard ownsResultNavigation,
              phase == .ready,
              deliveryLease == nil else {
            return false
        }
        if let position = candidates.firstIndex(where: { $0.id == blockID }) {
            selectCandidate(at: position)
            return true
        }
        guard candidates.isEmpty,
              let action = availableCreateActions().first(where: {
                  $0.id == blockID
              }),
              let query = readyQuery,
              query == currentQuerySignature() else {
            return false
        }
        beginCreate(action: action, query: query)
        return true
    }

    // MARK: Password-only protected delivery

    var canRequestProtectedDelivery: Bool {
        guard isActive,
              phase == .ready,
              currentQuerySignatureMatchesReadyState,
              selectedCandidate?.type == .password else {
            return false
        }
        return currentUnlockSession() == nil
    }

    var protectedDeliveryPromptActive: Bool {
        currentUnlockSession() != nil
    }

    var protectedDeliveryPromptProgress: Int {
        currentUnlockSession()?.completedSteps ?? 0
    }

    var protectedDeliveryPromptStepCount: Int {
        CapsulePasswordUnlockChord.stepCount
    }

    @discardableResult
    func requestProtectedDelivery(target: FocusLease) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard canRequestProtectedDelivery,
              let candidate = selectedCandidate,
              let readyQuery,
              candidate.type == .password,
              target.isExternalTarget,
              !target.compositionActive,
              InputFocusCoordinator.shared.liveTarget(
                expected: target.token,
                forceOverlayVisibilityRefresh: true
              ) === target else {
            return false
        }
        unlockSession = UnlockSession(
            recordID: candidate.id,
            query: readyQuery,
            completedSteps: 0,
            expiresAt: CFAbsoluteTimeGetCurrent() + Self.unlockLifetime
        )
        unlockTimer?.invalidate()
        let timer = Timer(timeInterval: Self.unlockLifetime, repeats: false) {
            [weak self] _ in
            guard let self, self.unlockSession != nil else { return }
            self.clearUnlockSession()
            self.notifyChange()
        }
        unlockTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        notifyChange()
        return true
    }

    @discardableResult
    func cancelProtectedDeliveryPrompt() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard unlockSession != nil else { return false }
        clearUnlockSession()
        notifyChange()
        return true
    }

    /// Consume an invalid plain input while the prompt owns the access
    /// gesture. The key is never replayed into Rime or the host field.
    @discardableResult
    func rejectProtectedDeliveryInput() -> Bool {
        guard currentUnlockSession() != nil else { return false }
        clearUnlockSession()
        notifyChange()
        return true
    }

    func acceptsUnlockChordKey(_ keycode: Int32) -> Bool {
        isSelected
            && currentUnlockSession() != nil
            && CapsulePasswordUnlockChord.accepts(keycode: keycode)
    }

    func handleUnlockChord(_ keys: [(keycode: Int32, mask: Int32)],
                           target: FocusLease) -> UnlockChordResult {
        dispatchPrecondition(condition: .onQueue(.main))
        guard var unlock = currentUnlockSession() else {
            return .notMatched
        }
        guard CapsulePasswordUnlockChord.matches(
                keys,
                step: unlock.completedSteps
              ) else {
            clearUnlockSession()
            notifyChange()
            return .rejected
        }
        guard isSelected,
              target.isExternalTarget,
              !target.compositionActive,
              InputFocusCoordinator.shared.liveTarget(
                expected: target.token,
                forceOverlayVisibilityRefresh: true
              ) === target,
              let controller = target.controller else {
            clearUnlockSession()
            IMELog.write("capsule protected delivery rejected without live authority")
            notifyChange()
            return .rejected
        }

        unlock.completedSteps += 1
        if unlock.completedSteps < CapsulePasswordUnlockChord.stepCount {
            unlockSession = unlock
            notifyChange()
            return .progressed
        }

        let record: CapsulePasswordRecord
        do {
            record = try dependencies.passwordRecord(unlock.recordID)
        } catch {
            clearUnlockSession()
            IMELog.write("capsule protected record decrypt failed")
            phase = .failed("密码无法解密或本地文件已损坏")
            notifyChange()
            return .deliveryFailed
        }
        let permit = CapsulePasswordDeliveryAuthorization.issue(
            recordID: record.summary.id,
            target: target
        )
        let delivered = controller.deliverCapsulePassword(
            record.secret.password,
            recordID: record.summary.id,
            permit: permit,
            target: target
        )
        guard delivered else {
            clearUnlockSession()
            IMELog.write("capsule protected delivery rejected")
            notifyChange()
            return .deliveryFailed
        }

        clearUnlockSession()
        generation &+= 1
        if currentQuerySignature() == unlock.query {
            sourceModel.consumeDelivered(blockIDs: unlock.query.blockIDs)
        }
        clearReadyState(cancelUnlock: true)
        phase = .idle
        IMELog.write("capsule password delivered after local authorization")
        notifyChange()
        DispatchQueue.main.async {
            BufferWindowController.shared.closeAndPause()
        }
        return .delivered
    }

    func fireSearchDebounceForTesting() {
        searchTimer?.fire()
    }

    // MARK: Search and inline creation

    private func sourceDidChange() {
        dispatchPrecondition(condition: .onQueue(.main))
        if sourceModel.lastMutationReason == .pause { return }
        generation &+= 1
        clearReadyState(cancelUnlock: true)
        searchRevision &+= 1
        searchTimer?.invalidate()
        searchTimer = nil
        guard isActive else {
            phase = .idle
            notifyChange()
            return
        }
        scheduleSearch()
    }

    private func selectionDidChange() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation &+= 1
        searchRevision &+= 1
        searchTimer?.invalidate()
        searchTimer = nil
        clearReadyState(cancelUnlock: true)
        guard isActive else {
            phase = .idle
            notifyChange()
            return
        }
        scheduleSearch()
    }

    private func scheduleSearch() {
        dispatchPrecondition(condition: .onQueue(.main))
        searchTimer?.invalidate()
        searchTimer = nil
        let signature = currentQuerySignature()
        guard isActive,
              !signature.text.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty else {
            clearReadyState(cancelUnlock: true)
            phase = .idle
            notifyChange()
            return
        }
        searchRevision &+= 1
        let revision = searchRevision
        phase = .waiting
        notifyChange()
        let timer = Timer(timeInterval: Self.searchDebounce, repeats: false) {
            [weak self] _ in
            self?.beginSearch(signature: signature, revision: revision)
        }
        searchTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func beginSearch(signature: QuerySignature, revision: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))
        searchTimer?.invalidate()
        searchTimer = nil
        guard searchAuthorityMatches(signature, revision: revision) else {
            return
        }
        phase = .searching
        notifyChange()
        dependencies.performBackground { [weak self] in
            guard let self else { return }
            let result = Result {
                try self.dependencies.search(
                    signature.text,
                    signature.kind,
                    5
                )
            }
            DispatchQueue.main.async { [weak self] in
                self?.finishSearch(
                    result,
                    signature: signature,
                    revision: revision
                )
            }
        }
    }

    private func finishSearch(
        _ result: Result<[Candidate], Error>,
        signature: QuerySignature,
        revision: UInt64
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard searchAuthorityMatches(signature, revision: revision) else {
            return
        }
        selectedPosition = 0
        deliveryLease = nil
        switch result {
        case let .success(found):
            candidates = Array(found.prefix(5))
            readyQuery = signature
            phase = .ready
        case .failure:
            clearReadyState(cancelUnlock: true)
            phase = .failed("Capsule 本地搜索失败")
        }
        notifyChange()
    }

    private func beginCreate(action: CreateAction, query: QuerySignature) {
        let request = CapsuleContentWriteRequest(
            type: action.kind,
            title: Self.inferredTitle(for: action.kind, content: query.text),
            content: query.text
        )
        searchRevision &+= 1
        let revision = searchRevision
        selectedPosition = 0
        phase = .creating(action.kind)
        notifyChange()
        dependencies.performBackground { [weak self] in
            guard let self else { return }
            let result = Result {
                try self.dependencies.createContent(request)
            }
            DispatchQueue.main.async { [weak self] in
                self?.finishCreate(
                    result,
                    request: request,
                    query: query,
                    revision: revision
                )
            }
        }
    }

    private func finishCreate(
        _ result: Result<CapsuleContentSummary, Error>,
        request: CapsuleContentWriteRequest,
        query: QuerySignature,
        revision: UInt64
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isActive,
              searchRevision == revision,
              query == currentQuerySignature() else {
            // The explicit write already completed; stale UI authority merely
            // prevents it from replacing a newer query presentation.
            return
        }
        switch result {
        case let .success(summary):
            candidates = [Candidate(
                id: summary.id,
                type: request.type,
                title: summary.title,
                payload: request.content,
                snippet: Self.compact(request.content, maximumCharacters: 72)
            )]
            selectedPosition = 0
            readyQuery = query
            deliveryLease = nil
            clearUnlockSession()
            generation &+= 1
            phase = .ready
        case .failure:
            clearReadyState(cancelUnlock: true)
            phase = .failed("Capsule 条目添加失败")
        }
        notifyChange()
    }

    private func selectCandidate(at position: Int) {
        guard candidates.indices.contains(position) else { return }
        generation &+= 1
        selectedPosition = position
        deliveryLease = nil
        clearUnlockSession()
        notifyChange()
    }

    private func currentUnlockSession() -> UnlockSession? {
        guard let unlockSession,
              unlockSession.expiresAt >= CFAbsoluteTimeGetCurrent() else {
            clearUnlockSession()
            return nil
        }
        return unlockSession
    }

    private func availableCreateActions() -> [CreateAction] {
        guard phase == .ready,
              candidates.isEmpty,
              let readyQuery,
              readyQuery == currentQuerySignature() else {
            return []
        }
        switch selectedKind {
        case .memory:
            return [.memory]
        case .prompt:
            return [.prompt]
        case .skill:
            return NSString(string: readyQuery.text).isAbsolutePath
                ? [.skill]
                : []
        case .password:
            return []
        }
    }

    private func searchAuthorityMatches(_ signature: QuerySignature,
                                        revision: UInt64) -> Bool {
        isActive
            && revision == searchRevision
            && signature == currentQuerySignature()
    }

    private func currentQuerySignature() -> QuerySignature {
        QuerySignature(
            text: sourceModel.stagedText,
            kind: selectedKind,
            blockIDs: sourceModel.blocks.map(\.id),
            changeCount: sourceModel.changeCount,
            allowsRemoteMirror: sourceModel.blocks.allSatisfy {
                $0.origin.allowsRemoteMirror
            }
        )
    }

    private var currentQuerySignatureMatchesReadyState: Bool {
        guard phase == .ready,
              let readyQuery,
              readyQuery == currentQuerySignature() else {
            return false
        }
        if let deliveryLease { return deliveryLease.query == readyQuery }
        return true
    }

    private var selectedCandidate: Candidate? {
        guard candidates.indices.contains(selectedPosition) else { return nil }
        return candidates[selectedPosition]
    }

    private func makeDeliveryBlock(_ candidate: Candidate,
                                   query: QuerySignature) -> BufferModel.Block {
        BufferModel.Block(
            id: candidate.id,
            text: candidate.payload ?? "",
            origin: .processor(
                id: Self.processorID,
                allowsRemoteMirror: query.allowsRemoteMirror
            )
        )
    }

    private func clearReadyState(cancelUnlock: Bool) {
        readyQuery = nil
        deliveryLease = nil
        candidates.removeAll(keepingCapacity: true)
        selectedPosition = 0
        if cancelUnlock { clearUnlockSession() }
    }

    private func clearUnlockSession() {
        unlockTimer?.invalidate()
        unlockTimer = nil
        unlockSession = nil
    }

    private func tombstone(cancelUnlock: Bool) {
        searchRevision &+= 1
        generation &+= 1
        searchTimer?.invalidate()
        searchTimer = nil
        clearReadyState(cancelUnlock: cancelUnlock)
        phase = .idle
        notifyChange()
    }

    private var phaseCreatingText: String? {
        guard case let .creating(kind) = phase else { return nil }
        return "正在添加 \(kind.displayName)"
    }

    private func notifyChange() {
        NotificationCenter.default.post(
            name: .derivedBufferWorkspaceDidChange,
            object: self
        )
    }

    private static func presentationText(for candidate: Candidate) -> String {
        let title = compact(candidate.title, maximumCharacters: 80)
        let snippet = compact(candidate.snippet, maximumCharacters: 110)
        if snippet.isEmpty { return "\(candidate.type.displayName) · \(title)" }
        return "\(candidate.type.displayName) · \(title) · \(snippet)"
    }

    private static func inferredTitle(for kind: CapsuleEntryKind,
                                      content: String) -> String {
        if kind == .skill {
            let name = URL(fileURLWithPath: content).lastPathComponent
            if !name.isEmpty { return compact(name, maximumCharacters: 80) }
        }
        let firstLine = content.components(separatedBy: .newlines)
            .first(where: {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            })?
            .trimmingCharacters(in: .whitespaces) ?? kind.displayName
        return compact(firstLine, maximumCharacters: 80)
    }

    private static func compact(_ raw: String,
                                maximumCharacters: Int) -> String {
        let value = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard value.count > maximumCharacters else { return value }
        return String(value.prefix(maximumCharacters)) + "…"
    }
}
