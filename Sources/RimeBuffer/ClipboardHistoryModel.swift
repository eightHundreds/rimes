import Cocoa
import Carbon.HIToolbox
import CryptoKit

/// Reasons clipboard content must not be read or rendered. Multiple reasons can
/// be active at once during fast user/session transitions.
struct ClipboardHistoryProtection: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let secureInput = ClipboardHistoryProtection(rawValue: 1 << 0)
    static let screenLocked = ClipboardHistoryProtection(rawValue: 1 << 1)
    static let sessionInactive = ClipboardHistoryProtection(rawValue: 1 << 2)
}

struct ClipboardHistoryCaptureState: Equatable, Sendable {
    var windowVisible: Bool
    var captureEnabled: Bool
    var protection: ClipboardHistoryProtection

    init(windowVisible: Bool = false,
         captureEnabled: Bool = false,
         protection: ClipboardHistoryProtection = []) {
        self.windowVisible = windowVisible
        self.captureEnabled = captureEnabled
        self.protection = protection
    }

    var allowsClipboardObservation: Bool {
        captureEnabled && protection.isEmpty
    }

    var allowsContentPresentation: Bool {
        windowVisible && captureEnabled && protection.isEmpty
    }
}

struct ClipboardHistoryItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: ClipboardItemKind
    let displayText: String?
    let searchText: String?
    let canonicalText: String?
    let textCompleteness: ClipboardTextCompleteness
    let byteCount: Int
    let payloadByteCount: Int
    let capturedAt: Date
    let sourceApplicationName: String?
    let sourceApplicationBundleIdentifier: String?
    let sourceNamespace: String
    let sourceID: String

    /// Compatibility projection for the existing text-only pane. Rich-item
    /// actions use `restoreToPasteboard(id:)` instead of this projection.
    var text: String {
        displayText ?? canonicalText ?? ""
    }

    init(metadata: ClipboardStoredItemMetadata) {
        id = metadata.id
        kind = metadata.kind
        displayText = metadata.displayText
        searchText = metadata.searchText
        canonicalText = metadata.canonicalText
        textCompleteness = metadata.textCompleteness
        payloadByteCount = metadata.payloadByteCount
        byteCount = max(
            metadata.payloadByteCount,
            metadata.canonicalText?.lengthOfBytes(using: .utf8) ?? 0
        )
        capturedAt = metadata.lastPromotedAt ?? metadata.capturedAt
        sourceApplicationName = metadata.sourceApplicationName
        sourceApplicationBundleIdentifier =
            metadata.sourceApplicationBundleIdentifier
        sourceNamespace = metadata.sourceNamespace
        sourceID = metadata.sourceID
    }

    init(
        id: UUID,
        kind: ClipboardItemKind,
        displayText: String?,
        searchText: String?,
        canonicalText: String?,
        textCompleteness: ClipboardTextCompleteness,
        byteCount: Int,
        payloadByteCount: Int,
        capturedAt: Date,
        sourceApplicationName: String?,
        sourceApplicationBundleIdentifier: String?,
        sourceNamespace: String,
        sourceID: String
    ) {
        self.id = id
        self.kind = kind
        self.displayText = displayText
        self.searchText = searchText
        self.canonicalText = canonicalText
        self.textCompleteness = textCompleteness
        self.byteCount = byteCount
        self.payloadByteCount = payloadByteCount
        self.capturedAt = capturedAt
        self.sourceApplicationName = sourceApplicationName
        self.sourceApplicationBundleIdentifier =
            sourceApplicationBundleIdentifier
        self.sourceNamespace = sourceNamespace
        self.sourceID = sourceID
    }
}

extension ClipboardItemKind {
    /// File clipboard records can also carry an encoded image representation
    /// (for example file URL + PNG). The archive remains the source of truth;
    /// this only bounds which card kinds may request a thumbnail.
    var allowsImageThumbnail: Bool {
        self == .image || self == .files
    }

    /// Human search aliases keep type discovery useful when a rich item has no
    /// readable text projection (the usual case for screenshots and photos).
    var searchAliases: String {
        switch self {
        case .text: return "text plain 文本 文字"
        case .link: return "link url 链接 网址"
        case .image: return "image photo picture screenshot 图片 图像 照片 截图"
        case .files: return "file files 文件"
        case .color: return "color colour 颜色 色彩"
        case .unknown: return "unknown 未知"
        }
    }
}

struct ClipboardHistoryConfiguration: Equatable, Sendable {
    let maximumItems: Int
    let maximumItemBytes: Int
    let maximumTotalBytes: Int
    let pollingInterval: TimeInterval

    init(maximumItems: Int = 100_000,
         maximumItemBytes: Int = 256 * 1_024 * 1_024,
         maximumTotalBytes: Int = 64 * 1_024 * 1_024 * 1_024,
         pollingInterval: TimeInterval = 0.45) {
        let resolvedTotal = max(1, maximumTotalBytes)
        self.maximumItems = max(1, maximumItems)
        self.maximumItemBytes = min(max(1, maximumItemBytes), resolvedTotal)
        self.maximumTotalBytes = resolvedTotal
        self.pollingInterval = max(0.1, pollingInterval)
    }
}

@MainActor
protocol ClipboardHistoryPasteboardReading: AnyObject {
    var changeCount: Int { get }
    var usesTextOnlyCompatibilityArchive: Bool { get }
    func readPlainText() -> String?
    func readArchive() throws -> ClipboardPasteboardArchive?
    func readArchiveAsynchronously(
        expectedChangeCount: Int,
        completion: @escaping (Result<ClipboardPasteboardArchive?, Error>) -> Void
    )
}

extension ClipboardHistoryPasteboardReading {
    var usesTextOnlyCompatibilityArchive: Bool { true }

    /// Text-only compatibility path used by deterministic model doubles.
    func readArchive() throws -> ClipboardPasteboardArchive? {
        guard let text = readPlainText() else { return nil }
        return try ClipboardPasteboardArchive(items: [
            .init(
                types: [NSPasteboard.PasteboardType.string.rawValue],
                dataByType: [
                    NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8),
                ]
            ),
        ])
    }

    func readArchiveAsynchronously(
        expectedChangeCount: Int,
        completion: @escaping (Result<ClipboardPasteboardArchive?, Error>) -> Void
    ) {
        guard changeCount == expectedChangeCount else {
            completion(.success(nil))
            return
        }
        completion(Result { try readArchive() })
    }
}

/// Common markers used by password managers and other confidential pasteboard
/// providers. RIMES still treats Secure Input as the authoritative live gate;
/// these markers prevent a marked payload from entering the process at all.
enum ClipboardHistoryPasteboardPolicy {
    private static let confidentialTypeNames: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "com.agilebits.onepassword",
    ]

    static func allowsPlainTextRead(typeNames: [String]) -> Bool {
        confidentialTypeNames.isDisjoint(with: typeNames)
    }
}

private final class SystemClipboardHistoryPasteboard: ClipboardHistoryPasteboardReading {
    private static let captureQueue = DispatchQueue(
        label: "com.rimes.clipboard-history.capture",
        qos: .utility
    )
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }
    var usesTextOnlyCompatibilityArchive: Bool { false }

    func readPlainText() -> String? {
        let typeNames = pasteboard.types?.map(\.rawValue) ?? []
        guard ClipboardHistoryPasteboardPolicy
            .allowsPlainTextRead(typeNames: typeNames) else { return nil }
        return pasteboard.string(forType: .string)
    }

    func readArchive() throws -> ClipboardPasteboardArchive? {
        try ClipboardPasteboardArchive.capture(from: pasteboard)
    }

    func readArchiveAsynchronously(
        expectedChangeCount: Int,
        completion: @escaping (Result<ClipboardPasteboardArchive?, Error>) -> Void
    ) {
        Self.captureQueue.async {
            let pasteboard = NSPasteboard.general
            let result: Result<ClipboardPasteboardArchive?, Error>
            if pasteboard.changeCount != expectedChangeCount {
                result = .success(nil)
            } else {
                result = Result {
                    let archive = try ClipboardPasteboardArchive.capture(
                        from: pasteboard
                    )
                    guard pasteboard.changeCount == expectedChangeCount else {
                        return nil
                    }
                    return archive
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

/// Serializes all durable-store work away from the main actor. Store creation
/// is lazy as well, because opening GRDB performs migrations and filesystem
/// permission checks that must not delay the first keystroke after launch.
private final class ClipboardHistoryPersistenceCoordinator: @unchecked Sendable {
    typealias StoreFactory = @Sendable () throws -> ClipboardHistoryStore

    private let queue = DispatchQueue(
        label: "com.rimes.clipboard-history.persistence",
        qos: .utility
    )
    private let storeFactory: StoreFactory
    private let previewQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.rimes.clipboard-history.image-previews"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private var store: ClipboardHistoryStore?
    /// Accessed only by `queue`. A later successful retry clears the matching
    /// identity; unresolved mutations keep the termination barrier fail-closed.
    private var failedUpsertIDs = Set<UUID>()
    private var failedPromotionIDs = Set<UUID>()
    private var failedDeleteIDs = Set<UUID>()
    private var clearFailed = false

    init(store: ClipboardHistoryStore) {
        self.store = store
        storeFactory = { store }
    }

    init(storeFactory: @escaping StoreFactory) {
        self.storeFactory = storeFactory
    }

    func loadAllMetadata(
        completion: @escaping (Result<[ClipboardStoredItemMetadata], Error>) -> Void
    ) {
        queue.async { [self] in
            let result = Result { try resolvedStore().loadAllMetadata() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func upsert(
        _ record: ClipboardHistoryImportRecord,
        completion: @escaping (Result<UUID, Error>) -> Void
    ) {
        queue.async { [self] in
            let result = Result { () throws -> UUID in
                let store = try resolvedStore()
                let id = try store.upsert(record)
                _ = try store.promote(id: id, at: record.capturedAt)
                return id
            }
            switch result {
            case .success:
                failedUpsertIDs.remove(record.id)
            case .failure:
                failedUpsertIDs.insert(record.id)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func promote(id: UUID, at date: Date) {
        queue.async { [self] in
            do {
                _ = try resolvedStore().promote(id: id, at: date)
                failedPromotionIDs.remove(id)
            } catch {
                failedPromotionIDs.insert(id)
                IMELog.write("clipboard persistence promote failed: \(error.localizedDescription)")
            }
        }
    }

    func promote(ids: [UUID], at date: Date) {
        guard !ids.isEmpty else { return }
        queue.async { [self] in
            do {
                _ = try resolvedStore().promote(ids: ids, at: date)
                failedPromotionIDs.subtract(ids)
            } catch {
                failedPromotionIDs.formUnion(ids)
                IMELog.write(
                    "clipboard persistence batch promote failed: "
                        + error.localizedDescription
                )
            }
        }
    }

    func delete(id: UUID) {
        queue.async { [self] in
            do {
                _ = try resolvedStore().delete(id: id)
                failedUpsertIDs.remove(id)
                failedPromotionIDs.remove(id)
                failedDeleteIDs.remove(id)
            } catch {
                failedDeleteIDs.insert(id)
                IMELog.write("clipboard persistence delete failed: \(error.localizedDescription)")
            }
        }
    }

    func delete(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        queue.async { [self] in
            do {
                _ = try resolvedStore().delete(ids: ids)
                failedUpsertIDs.subtract(ids)
                failedPromotionIDs.subtract(ids)
                failedDeleteIDs.subtract(ids)
            } catch {
                failedDeleteIDs.formUnion(ids)
                IMELog.write(
                    "clipboard persistence batch delete failed: "
                        + error.localizedDescription
                )
            }
        }
    }

    func clear() {
        queue.async { [self] in
            do {
                _ = try resolvedStore().clear()
                failedUpsertIDs.removeAll()
                failedPromotionIDs.removeAll()
                failedDeleteIDs.removeAll()
                clearFailed = false
            } catch {
                clearFailed = true
                IMELog.write("clipboard persistence clear failed: \(error.localizedDescription)")
            }
        }
    }

    /// Reads and decodes a large representation on the persistence queue. The
    /// completion always returns on the main queue, where the caller must
    /// revalidate window, protection, and focus authority before writing the
    /// pasteboard.
    func archive(
        id: UUID,
        transientPayload: Data?,
        completion: @escaping (Result<ClipboardPasteboardArchive?, Error>) -> Void
    ) {
        queue.async { [self] in
            let result = Result { () throws -> ClipboardPasteboardArchive? in
                let payload: Data?
                if let transientPayload {
                    payload = transientPayload
                } else {
                    payload = try resolvedStore().payload(for: id)?.opaquePayload
                }
                guard let payload else { return nil }
                return try ClipboardPasteboardArchive.decodeRawDeflate(payload)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func archives(
        ids: [UUID],
        transientPayloads: [UUID: Data],
        completion: @escaping (
            Result<[ClipboardPasteboardArchive]?, Error>
        ) -> Void
    ) {
        queue.async { [self] in
            let result = Result { () throws -> [ClipboardPasteboardArchive]? in
                var archives: [ClipboardPasteboardArchive] = []
                archives.reserveCapacity(ids.count)
                let store = try resolvedStore()
                for id in ids {
                    let payload: Data?
                    if let transient = transientPayloads[id] {
                        payload = transient
                    } else {
                        payload = try store.payload(for: id)?.opaquePayload
                    }
                    guard let payload else { return nil }
                    archives.append(
                        try ClipboardPasteboardArchive.decodeRawDeflate(payload)
                    )
                }
                return archives
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func imageThumbnail(
        id: UUID,
        transientPayload: Data?,
        maximumPixelSize: Int,
        completion: @escaping (Result<CGImage?, Error>) -> Void
    ) {
        queue.async { [self] in
            let payloadResult = Result { () throws -> Data? in
                if let transientPayload { return transientPayload }
                return try resolvedStore().payload(for: id)?.opaquePayload
            }
            previewQueue.addOperation {
                let result = payloadResult.flatMap { payload -> Result<CGImage?, Error> in
                    Result {
                        guard let payload else { return nil }
                        return try ClipboardPasteboardArchive
                            .decodeRawDeflate(payload)
                            .makeImageThumbnail(
                                maximumPixelSize: maximumPixelSize
                            )
                    }
                }
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    func sourceApplicationIcon(
        bundleIdentifier: String,
        completion: @escaping (Result<Data?, Error>) -> Void
    ) {
        queue.async { [self] in
            let result = Result {
                try resolvedStore().sourceApplicationIcon(
                    bundleIdentifier: bundleIdentifier
                )
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Waits until every store mutation submitted before this call has
    /// completed. Completion callbacks may still be waiting on the main queue,
    /// but the durable SQLite writes themselves are ordered ahead of the
    /// sentinel block below.
    func flush(timeout: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = ClipboardHistoryFlushOutcome()
        queue.async { [self] in
            outcome.setSucceeded(
                failedUpsertIDs.isEmpty
                    && failedPromotionIDs.isEmpty
                    && failedDeleteIDs.isEmpty
                    && !clearFailed
            )
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + max(0, timeout)) == .success
        else { return false }
        return outcome.succeeded
    }

    private func resolvedStore() throws -> ClipboardHistoryStore {
        if let store { return store }
        let created = try storeFactory()
        store = created
        return created
    }
}

private final class ClipboardHistoryFlushOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var succeeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func setSucceeded(_ succeeded: Bool) {
        lock.lock()
        value = succeeded
        lock.unlock()
    }
}

private let clipboardHistoryArchiveProcessingQueue = DispatchQueue(
    label: "com.rimes.clipboard-history.archive-processing",
    qos: .utility
)

private struct ClipboardHistoryArchiveProjection: Sendable {
    let kind: ClipboardItemKind
    let displayText: String?
    let searchText: String?
    let canonicalText: String?
    let textCompleteness: ClipboardTextCompleteness

    var hasMeaningfulPresentation: Bool {
        if kind != .text { return true }
        guard let canonicalText else { return false }
        return !canonicalText.contains("\0")
            && !canonicalText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
    }
}

private struct ClipboardHistoryPreparedArchive: Sendable {
    let payload: Data
    let projection: ClipboardHistoryArchiveProjection
    let budgetByteCount: Int
    let sourceID: String
}

/// Clipboard history for the standalone Clip window.
///
/// Observation follows the user's capture switch rather than window visibility,
/// so closing the presentation surface does not create holes in future history.
/// Every protected or inactive gap is followed by a change-count-only baseline,
/// so content copied while Secure Input or a locked session is active is never
/// backfilled on resume.
@MainActor
final class ClipboardHistoryModel {
    typealias Observer = () -> Void

    private let configuration: ClipboardHistoryConfiguration
    private let pasteboard: ClipboardHistoryPasteboardReading
    private let protectionProbe: () -> ClipboardHistoryProtection
    private let clock: () -> Date
    private let sourceApplicationName: () -> String?
    private let sourceApplicationBundleIdentifier: () -> String?
    private let schedulesAutomaticPolling: Bool
    private let persistence: ClipboardHistoryPersistenceCoordinator?

    private var timer: Timer?
    private var observers: [UUID: Observer] = [:]
    private var lastObservedPasteboardChangeCount: Int?
    private var needsPasteboardBaseline = true
    private var effectiveProtection: ClipboardHistoryProtection = []
    private var started = false
    private var totalBytes = 0
    private var didRequestPersistenceLoad = false
    private var persistenceMutationGeneration: UInt64 = 0
    private var captureClearGeneration: UInt64 = 0
    private var discardedPendingCaptureIDs = Set<UUID>()
    private var contentAccessGeneration: UInt64 = 0
    private var transientPayloads: [UUID: Data] = [:]

    private(set) var captureState = ClipboardHistoryCaptureState()
    private var storedItems: [ClipboardHistoryItem] = []
    private(set) var selectedID: UUID?
    private(set) var selectedIDs: Set<UUID> = []

    init(configuration: ClipboardHistoryConfiguration = .init()) {
        self.configuration = configuration
        pasteboard = SystemClipboardHistoryPasteboard()
        protectionProbe = {
            IsSecureEventInputEnabled() ? [.secureInput] : []
        }
        clock = Date.init
        sourceApplicationName = {
            NSWorkspace.shared.frontmostApplication?.localizedName
        }
        sourceApplicationBundleIdentifier = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        schedulesAutomaticPolling = true
        persistence = ClipboardHistoryPersistenceCoordinator(
            storeFactory: { try ClipboardHistoryStore() }
        )
    }

    init(configuration: ClipboardHistoryConfiguration,
         pasteboard: ClipboardHistoryPasteboardReading,
         protectionProbe: @escaping () -> ClipboardHistoryProtection = { [] },
         clock: @escaping () -> Date = Date.init,
         sourceApplicationName: @escaping () -> String? = { nil },
         sourceApplicationBundleIdentifier: @escaping () -> String? = { nil },
         store: ClipboardHistoryStore? = nil,
         schedulesAutomaticPolling: Bool = true) {
        self.configuration = configuration
        self.pasteboard = pasteboard
        self.protectionProbe = protectionProbe
        self.clock = clock
        self.sourceApplicationName = sourceApplicationName
        self.sourceApplicationBundleIdentifier =
            sourceApplicationBundleIdentifier
        self.schedulesAutomaticPolling = schedulesAutomaticPolling
        persistence = store.map(ClipboardHistoryPersistenceCoordinator.init)
    }

    deinit {
        timer?.invalidate()
    }

    var isStarted: Bool { started }

    /// Re-probe Secure Input on every content access and action, not only on
    /// the polling cadence. This closes the interval between a password field
    /// gaining focus and the next scheduled timer tick.
    var isContentShielded: Bool {
        !resolveEffectiveProtection(notifyOnChange: false).isEmpty
    }

    var activeProtection: ClipboardHistoryProtection {
        resolveEffectiveProtection(notifyOnChange: false)
    }
    var storedByteCount: Int { totalBytes }
    var itemCount: Int { storedItems.count }
    var hasScheduledPolling: Bool { timer != nil }

    var isCaptureEligible: Bool {
        started
            && captureState.captureEnabled
            && !isContentShielded
    }

    /// Safe UI projection. Protected content stays in process memory but never
    /// crosses into a view hierarchy while the protection gate is active.
    var items: [ClipboardHistoryItem] {
        isContentShielded ? [] : storedItems
    }

    var visibleItems: [ClipboardHistoryItem] { items }

    var selectedItem: ClipboardHistoryItem? {
        guard !isContentShielded, let selectedID else { return nil }
        return storedItems.first { $0.id == selectedID }
    }

    var selectedItems: [ClipboardHistoryItem] {
        guard !isContentShielded else { return [] }
        return storedItems.filter { selectedIDs.contains($0.id) }
    }

    func start() {
        guard !started else {
            reconcilePolling()
            return
        }
        started = true
        needsPasteboardBaseline = true
        requestPersistenceLoadIfNeeded()
        reconcilePolling()
        notifyObservers()
    }

    /// Stops all observation without clearing the in-memory history. A later
    /// start establishes a fresh change-count baseline before any text read.
    func stop() {
        guard started || timer != nil else { return }
        started = false
        contentAccessGeneration &+= 1
        invalidateTimer()
        needsPasteboardBaseline = true
        notifyObservers()
    }

    func update(_ state: ClipboardHistoryCaptureState) {
        let oldNominalEligibility = captureState.allowsClipboardObservation
        guard state != captureState else {
            reconcilePolling()
            return
        }
        contentAccessGeneration &+= 1
        captureState = state
        if oldNominalEligibility != state.allowsClipboardObservation {
            needsPasteboardBaseline = true
        }
        reconcilePolling()
        notifyObservers()
    }

    func update(windowVisible: Bool,
                captureEnabled: Bool,
                protection: ClipboardHistoryProtection) {
        update(ClipboardHistoryCaptureState(
            windowVisible: windowVisible,
            captureEnabled: captureEnabled,
            protection: protection
        ))
    }

    @discardableResult
    func addObserver(_ observer: @escaping Observer) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    @discardableResult
    func select(id: UUID) -> Bool {
        guard !isContentShielded,
              storedItems.contains(where: { $0.id == id }) else { return false }
        guard selectedID != id || selectedIDs != [id] else { return true }
        selectedID = id
        selectedIDs = [id]
        notifyObservers()
        return true
    }

    @discardableResult
    func select(ids: [UUID], focusedID requestedFocusedID: UUID?) -> Bool {
        guard !isContentShielded else { return false }
        let validIDs = Set(storedItems.map(\.id))
        let selection = ids.filter { validIDs.contains($0) }
        let uniqueSelection = Set(selection)
        let focusedID = requestedFocusedID.flatMap {
            uniqueSelection.contains($0) ? $0 : nil
        } ?? selection.first
        guard uniqueSelection != selectedIDs || focusedID != selectedID else {
            return !selection.isEmpty
        }
        selectedIDs = uniqueSelection
        selectedID = focusedID
        notifyObservers()
        return !selection.isEmpty
    }

    @discardableResult
    func toggleSelection(id: UUID) -> Bool {
        guard !isContentShielded,
              storedItems.contains(where: { $0.id == id }) else { return false }
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            if selectedID == id {
                selectedID = storedItems.first(where: {
                    selectedIDs.contains($0.id)
                })?.id
            }
        } else {
            selectedIDs.insert(id)
            selectedID = id
        }
        notifyObservers()
        return true
    }

    @discardableResult
    func moveSelection(delta: Int) -> Bool {
        guard !isContentShielded, !storedItems.isEmpty, delta != 0 else { return false }
        let current = selectedID.flatMap { id in storedItems.firstIndex { $0.id == id } } ?? 0
        let next = min(max(0, current + delta), storedItems.count - 1)
        guard next != current else { return true }
        selectedID = storedItems[next].id
        selectedIDs = [storedItems[next].id]
        notifyObservers()
        return true
    }

    @discardableResult
    func deleteSelected() -> Bool {
        let ids = selectedIDs.isEmpty
            ? selectedID.map { [$0] } ?? []
            : storedItems.filter { selectedIDs.contains($0.id) }.map(\.id)
        return delete(ids: ids)
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        delete(ids: [id])
    }

    @discardableResult
    func delete(ids: [UUID]) -> Bool {
        guard !isContentShielded, !ids.isEmpty else { return false }
        let requested = Set(ids)
        let removed = storedItems.filter { requested.contains($0.id) }
        guard !removed.isEmpty else { return false }
        let firstRemovedIndex = storedItems.firstIndex {
            requested.contains($0.id)
        } ?? 0
        let removedIDs = Set(removed.map(\.id))
        storedItems.removeAll { removedIDs.contains($0.id) }
        contentAccessGeneration &+= 1
        discardedPendingCaptureIDs.formUnion(removedIDs)
        for item in removed {
            totalBytes = max(0, totalBytes - item.byteCount)
            transientPayloads.removeValue(forKey: item.id)
        }
        persistenceMutationGeneration &+= 1
        persistence?.delete(ids: removed.map(\.id))
        selectedIDs.subtract(removedIDs)
        if selectedIDs.isEmpty {
            let neighborIndex = min(firstRemovedIndex, storedItems.count - 1)
            selectedID = neighborIndex >= 0 ? storedItems[neighborIndex].id : nil
            selectedIDs = selectedID.map { Set([$0]) } ?? []
        } else if let selectedID, removedIDs.contains(selectedID) {
            self.selectedID = storedItems.first(where: {
                selectedIDs.contains($0.id)
            })?.id
        }
        notifyObservers()
        return true
    }

    func clear() {
        guard !storedItems.isEmpty || selectedID != nil
                || !selectedIDs.isEmpty || persistence != nil else {
            return
        }
        storedItems.removeAll(keepingCapacity: false)
        transientPayloads.removeAll(keepingCapacity: false)
        selectedID = nil
        selectedIDs.removeAll(keepingCapacity: false)
        totalBytes = 0
        contentAccessGeneration &+= 1
        persistenceMutationGeneration &+= 1
        captureClearGeneration &+= 1
        discardedPendingCaptureIDs.removeAll()
        persistence?.clear()
        notifyObservers()
    }

    /// Synchronizes the polling cursor after this process intentionally writes
    /// the general pasteboard (for the explicit Copy action). It reads only the
    /// change counter and never asks the provider for text.
    @discardableResult
    func baselineAfterOwnPasteboardWrite(
        expectedChangeCount: Int? = nil
    ) -> Bool {
        guard started,
              captureState.captureEnabled,
              resolveEffectiveProtection(notifyOnChange: true).isEmpty else {
            needsPasteboardBaseline = true
            return false
        }
        let currentChangeCount = pasteboard.changeCount
        guard expectedChangeCount == nil
                || expectedChangeCount == currentChangeCount else {
            return false
        }
        lastObservedPasteboardChangeCount = expectedChangeCount
            ?? currentChangeCount
        needsPasteboardBaseline = false
        return true
    }

    /// Moves an activated item to the front without changing its identity.
    @discardableResult
    func promote(id: UUID) -> Bool {
        promote(ids: [id])
    }

    @discardableResult
    func promote(ids: [UUID]) -> Bool {
        guard !isContentShielded, !ids.isEmpty else { return false }
        let itemByID = Dictionary(uniqueKeysWithValues: storedItems.map { ($0.id, $0) })
        var seen = Set<UUID>()
        let promoted = ids.compactMap { id -> ClipboardHistoryItem? in
            guard seen.insert(id).inserted else { return nil }
            return itemByID[id]
        }
        guard !promoted.isEmpty else { return false }
        let promotedIDs = Set(promoted.map(\.id))
        storedItems.removeAll { promotedIDs.contains($0.id) }
        storedItems.insert(contentsOf: promoted, at: 0)
        selectedIDs = promotedIDs
        selectedID = promoted.first?.id
        persistence?.promote(ids: promoted.map(\.id), at: clock())
        notifyObservers()
        return true
    }

    /// Loads and decodes a lossless representation away from the IMK main
    /// thread. The generation and live protection gate are revalidated after
    /// the background work; callers must still revalidate their own window and
    /// exact-focus intent before performing the final AppKit pasteboard write.
    func loadArchive(
        id: UUID,
        completion: @escaping (ClipboardPasteboardArchive?) -> Void
    ) {
        guard !isContentShielded,
              storedItems.contains(where: { $0.id == id }),
              let persistence else {
            completion(nil)
            return
        }
        let generation = contentAccessGeneration
        let transientPayload = transientPayloads[id]
        persistence.archive(
            id: id,
            transientPayload: transientPayload
        ) { [weak self] result in
            guard let self,
                  generation == self.contentAccessGeneration,
                  !self.isContentShielded,
                  self.storedItems.contains(where: { $0.id == id }) else {
                completion(nil)
                return
            }
            switch result {
            case let .success(archive):
                completion(archive)
            case let .failure(error):
                IMELog.write(
                    "clipboard archive load failed: \(error.localizedDescription)"
                )
                completion(nil)
            }
        }
    }

    /// Loads an ordered multi-selection as one all-or-nothing snapshot. The
    /// caller can therefore decide between exact IMK text insertion and a
    /// lossless multi-item pasteboard restore without partially acting on a
    /// stale selection.
    func loadArchives(
        ids: [UUID],
        completion: @escaping ([ClipboardPasteboardArchive]?) -> Void
    ) {
        guard !ids.isEmpty,
              !isContentShielded,
              ids.allSatisfy({ id in
                  storedItems.contains(where: { $0.id == id })
              }),
              let persistence else {
            completion(nil)
            return
        }
        let generation = contentAccessGeneration
        let payloads = transientPayloads.filter { ids.contains($0.key) }
        persistence.archives(ids: ids, transientPayloads: payloads) {
            [weak self] result in
            guard let self,
                  generation == self.contentAccessGeneration,
                  !self.isContentShielded,
                  ids.allSatisfy({ id in
                      self.storedItems.contains(where: { $0.id == id })
                  }) else {
                completion(nil)
                return
            }
            switch result {
            case let .success(archives): completion(archives)
            case let .failure(error):
                IMELog.write(
                    "clipboard archive batch load failed: "
                        + error.localizedDescription
                )
                completion(nil)
            }
        }
    }

    /// Requests a downsampled image for one visible card. Archive inflation and
    /// ImageIO decoding stay off the IMK main thread and at most two previews
    /// run concurrently in the persistence coordinator.
    func loadImageThumbnail(
        id: UUID,
        maximumPixelSize: Int,
        completion: @escaping (CGImage?) -> Void
    ) {
        guard !isContentShielded,
              let requestedItem = storedItems.first(where: {
                  $0.id == id && $0.kind.allowsImageThumbnail
              }),
              let persistence else {
            completion(nil)
            return
        }
        let generation = contentAccessGeneration
        persistence.imageThumbnail(
            id: id,
            transientPayload: transientPayloads[id],
            maximumPixelSize: maximumPixelSize
        ) { [weak self] result in
            guard let self,
                  generation == self.contentAccessGeneration,
                  !self.isContentShielded,
                  self.storedItems.contains(where: {
                      $0.id == id && $0.kind.allowsImageThumbnail
                  }) else {
                completion(nil)
                return
            }
            switch result {
            case let .success(image):
                if image == nil, requestedItem.kind == .image {
                    IMELog.write(
                        "clipboard image preview unavailable kind=image"
                    )
                }
                completion(image)
            case let .failure(error):
                IMELog.write(
                    "clipboard image preview failed: "
                        + error.localizedDescription
                )
                completion(nil)
            }
        }
    }

    func loadSourceApplicationIcon(
        bundleIdentifier: String,
        completion: @escaping (Data?) -> Void
    ) {
        guard !bundleIdentifier.isEmpty, let persistence else {
            completion(nil)
            return
        }
        persistence.sourceApplicationIcon(
            bundleIdentifier: bundleIdentifier
        ) { result in
            switch result {
            case let .success(data): completion(data)
            case let .failure(error):
                IMELog.write(
                    "clipboard source icon load failed: "
                        + error.localizedDescription
                )
                completion(nil)
            }
        }
    }

    /// Drains durable mutations that the UI has already accepted before the
    /// input-method process terminates.
    func flushPersistence(timeout: TimeInterval = 5) -> Bool {
        persistence?.flush(timeout: timeout) ?? true
    }

    /// Test seam and timer target. It never reads the pasteboard when any
    /// enablement or protection gate is closed.
    @discardableResult
    func pollNow() -> Bool {
        guard started,
              captureState.captureEnabled else {
            needsPasteboardBaseline = true
            return false
        }

        let protection = resolveEffectiveProtection(notifyOnChange: true)
        guard protection.isEmpty else {
            needsPasteboardBaseline = true
            return false
        }

        if needsPasteboardBaseline {
            lastObservedPasteboardChangeCount = pasteboard.changeCount
            needsPasteboardBaseline = false
            return false
        }

        let changeCount = pasteboard.changeCount
        guard changeCount != lastObservedPasteboardChangeCount else { return false }
        lastObservedPasteboardChangeCount = changeCount

        // Re-check the live Secure Input probe immediately before asking a
        // potentially lazy pasteboard provider for all payload representations.
        guard resolveEffectiveProtection(notifyOnChange: true).isEmpty else {
            needsPasteboardBaseline = true
            return false
        }

        if !pasteboard.usesTextOnlyCompatibilityArchive {
            return scheduleArchiveCapture(
                expectedChangeCount: changeCount,
                requiresVisibleWindow: false
            )
        }

        // Deterministic text-only doubles stay synchronous so the model smoke
        // can assert the result of a poll without waiting on a run loop.
        do {
            guard let archive = try pasteboard.readArchive() else { return false }
            guard resolveEffectiveProtection(notifyOnChange: true).isEmpty,
                  captureState.captureEnabled else {
                needsPasteboardBaseline = true
                return false
            }
            return ingest(
                archive,
                usesTextOnlyCompatibilityBudget: true
            )
        } catch {
            return false
        }
    }

    /// Explicit user intent may import the clipboard item that already exists
    /// when Clipboard History is enabled or summoned. This is deliberately a
    /// separate entry point from passive resume: hidden, locked, session, and
    /// Secure Input transitions must continue to establish a baseline only.
    @discardableResult
    func captureCurrentIfEligible() -> Bool {
        guard started,
              captureState.windowVisible,
              captureState.captureEnabled else {
            needsPasteboardBaseline = true
            return false
        }

        guard resolveEffectiveProtection(notifyOnChange: true).isEmpty else {
            needsPasteboardBaseline = true
            return false
        }

        lastObservedPasteboardChangeCount = pasteboard.changeCount
        needsPasteboardBaseline = false

        // Recheck immediately before and after asking a potentially lazy
        // pasteboard provider for all payload representations.
        guard resolveEffectiveProtection(notifyOnChange: true).isEmpty,
              captureState.windowVisible,
              captureState.captureEnabled else {
            needsPasteboardBaseline = true
            return false
        }
        if !pasteboard.usesTextOnlyCompatibilityArchive {
            return scheduleArchiveCapture(
                expectedChangeCount: lastObservedPasteboardChangeCount ?? 0,
                requiresVisibleWindow: true
            )
        }

        do {
            guard let archive = try pasteboard.readArchive() else { return false }
            guard resolveEffectiveProtection(notifyOnChange: true).isEmpty,
                  captureState.windowVisible,
                  captureState.captureEnabled else {
                needsPasteboardBaseline = true
                return false
            }
            return ingest(
                archive,
                usesTextOnlyCompatibilityBudget: true
            )
        } catch {
            return false
        }
    }

    /// Schedules the potentially expensive lazy-provider read, archive
    /// compression, preview projection, and hashing away from the IMK main
    /// thread. The captured generation is checked both before processing and
    /// before applying the result, so a Secure Input/session/window transition
    /// discards an in-flight payload without exposing it to the UI or store.
    private func scheduleArchiveCapture(
        expectedChangeCount: Int,
        requiresVisibleWindow: Bool
    ) -> Bool {
        let generation = contentAccessGeneration
        let capturedAt = clock()
        let applicationName = sourceApplicationName()
        let bundleIdentifier = sourceApplicationBundleIdentifier()
        let configuration = configuration

        pasteboard.readArchiveAsynchronously(
            expectedChangeCount: expectedChangeCount
        ) { [weak self] result in
            guard let self,
                  generation == self.contentAccessGeneration,
                  self.started,
                  self.captureState.captureEnabled,
                  (!requiresVisibleWindow || self.captureState.windowVisible),
                  self.resolveEffectiveProtection(notifyOnChange: true).isEmpty
            else { return }

            let archive: ClipboardPasteboardArchive
            switch result {
            case let .success(captured?):
                archive = captured
            case .success(nil):
                return
            case let .failure(error):
                IMELog.write(
                    "clipboard archive capture failed: "
                        + error.localizedDescription
                )
                return
            }
            clipboardHistoryArchiveProcessingQueue.async { [weak self] in
                let prepared = Self.prepareArchive(
                    archive,
                    requestedBudgetByteCount: nil,
                    usesTextOnlyCompatibilityBudget: false,
                    configuration: configuration
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          generation == self.contentAccessGeneration,
                          self.started,
                          self.captureState.captureEnabled,
                          (!requiresVisibleWindow
                              || self.captureState.windowVisible),
                          self.resolveEffectiveProtection(
                            notifyOnChange: true
                          ).isEmpty,
                          let prepared else {
                        return
                    }
                    self.persistPreparedArchiveBeforePresentation(
                        prepared,
                        capturedAt: capturedAt,
                        applicationName: applicationName,
                        bundleIdentifier: bundleIdentifier
                    )
                }
            }
        }
        return true
    }

    /// Internal deterministic seam used by the standalone model/view smoke.
    @discardableResult
    func ingest(_ text: String) -> Bool {
        guard !isContentShielded,
              !text.isEmpty,
              !text.contains("\0"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let byteCount = text.lengthOfBytes(using: .utf8)
        guard byteCount > 0,
              byteCount <= configuration.maximumItemBytes,
              byteCount <= configuration.maximumTotalBytes else {
            return false
        }
        do {
            let archive = try ClipboardPasteboardArchive(items: [
                .init(
                    types: [NSPasteboard.PasteboardType.string.rawValue],
                    dataByType: [
                        NSPasteboard.PasteboardType.string.rawValue:
                            Data(text.utf8),
                    ]
                ),
            ])
            return ingest(archive, budgetByteCount: byteCount)
        } catch {
            return false
        }
    }

    @discardableResult
    private func ingest(
        _ archive: ClipboardPasteboardArchive,
        budgetByteCount requestedBudgetByteCount: Int? = nil,
        usesTextOnlyCompatibilityBudget: Bool = false
    ) -> Bool {
        guard !isContentShielded else { return false }
        guard let prepared = Self.prepareArchive(
            archive,
            requestedBudgetByteCount: requestedBudgetByteCount,
            usesTextOnlyCompatibilityBudget: usesTextOnlyCompatibilityBudget,
            configuration: configuration
        ), !isContentShielded else { return false }
        return applyPreparedArchive(
            prepared,
            capturedAt: clock(),
            applicationName: sourceApplicationName(),
            bundleIdentifier: sourceApplicationBundleIdentifier()
        )
    }

    nonisolated private static func prepareArchive(
        _ archive: ClipboardPasteboardArchive,
        requestedBudgetByteCount: Int?,
        usesTextOnlyCompatibilityBudget: Bool,
        configuration: ClipboardHistoryConfiguration
    ) -> ClipboardHistoryPreparedArchive? {
        guard let payload = try? archive.encodeRawDeflate() else { return nil }
        let projection = projection(for: archive)
        guard projection.hasMeaningfulPresentation else { return nil }
        let budgetByteCount = requestedBudgetByteCount
            ?? (usesTextOnlyCompatibilityBudget
                ? projection.canonicalText?.lengthOfBytes(using: .utf8)
                : nil)
            ?? payload.count
        guard budgetByteCount > 0,
              budgetByteCount <= configuration.maximumItemBytes,
              budgetByteCount <= configuration.maximumTotalBytes else {
            return nil
        }
        return ClipboardHistoryPreparedArchive(
            payload: payload,
            projection: projection,
            budgetByteCount: budgetByteCount,
            sourceID: sourceID(for: archive)
        )
    }

    private func applyPreparedArchive(
        _ prepared: ClipboardHistoryPreparedArchive,
        capturedAt: Date,
        applicationName: String?,
        bundleIdentifier: String?
    ) -> Bool {
        guard !isContentShielded else { return false }
        let item = makePreparedItem(
            prepared,
            capturedAt: capturedAt,
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier
        )
        installPreparedItem(
            item,
            transientPayload: prepared.payload,
            persistAfterInstall: true
        )
        return storedItems.contains { $0.id == item.id }
    }

    /// Production capture does not expose a card until its payload has been
    /// committed. This keeps every item the user can see recoverable after an
    /// immediate input-method restart; a failed upsert remains an aggregate log
    /// event and never masquerades as a durable history entry.
    private func persistPreparedArchiveBeforePresentation(
        _ prepared: ClipboardHistoryPreparedArchive,
        capturedAt: Date,
        applicationName: String?,
        bundleIdentifier: String?,
        attempt: Int = 0,
        expectedClearGeneration: UInt64? = nil
    ) {
        if attempt == 0, isContentShielded { return }
        guard let persistence else {
            _ = applyPreparedArchive(
                prepared,
                capturedAt: capturedAt,
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier
            )
            return
        }
        let item = makePreparedItem(
            prepared,
            capturedAt: capturedAt,
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier
        )
        let clearGeneration = expectedClearGeneration ?? captureClearGeneration
        guard clearGeneration == captureClearGeneration else { return }
        if attempt == 0 { discardedPendingCaptureIDs.remove(item.id) }
        guard !discardedPendingCaptureIDs.contains(item.id) else { return }
        let record = persistenceRecord(for: item, payload: prepared.payload)
        persistence.upsert(record) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(persistedID):
                guard clearGeneration == self.captureClearGeneration,
                      !self.discardedPendingCaptureIDs.contains(item.id)
                else { return }
                let persistedItem = self.replacingID(
                    of: item,
                    with: persistedID
                )
                self.installPreparedItem(
                    persistedItem,
                    transientPayload: nil,
                    persistAfterInstall: false
                )
            case let .failure(error):
                guard clearGeneration == self.captureClearGeneration,
                      !self.discardedPendingCaptureIDs.contains(item.id)
                else { return }
                guard attempt < 3 else {
                    IMELog.write(
                        "clipboard durable capture failed after retries: "
                            + error.localizedDescription
                    )
                    return
                }
                let delay = 0.25 * pow(2, Double(attempt))
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + delay
                ) { [weak self] in
                    self?.persistPreparedArchiveBeforePresentation(
                        prepared,
                        capturedAt: capturedAt,
                        applicationName: applicationName,
                        bundleIdentifier: bundleIdentifier,
                        attempt: attempt + 1,
                        expectedClearGeneration: clearGeneration
                    )
                }
            }
        }
    }

    private func makePreparedItem(
        _ prepared: ClipboardHistoryPreparedArchive,
        capturedAt: Date,
        applicationName: String?,
        bundleIdentifier: String?
    ) -> ClipboardHistoryItem {
        let sourceNamespace = "rimes.clipboard.live.archive.v1"
        let searchText = Self.joinedSearchText(
            prepared.projection.searchText,
            applicationName,
            bundleIdentifier
        )

        let existingIndex = storedItems.firstIndex {
            $0.sourceNamespace == sourceNamespace
                && $0.sourceID == prepared.sourceID
        }
        let itemID = existingIndex.map { storedItems[$0].id }
            ?? Self.stableID(
                sourceNamespace: sourceNamespace,
                sourceID: prepared.sourceID
            )
        return ClipboardHistoryItem(
            id: itemID,
            kind: prepared.projection.kind,
            displayText: prepared.projection.displayText,
            searchText: searchText,
            canonicalText: prepared.projection.canonicalText,
            textCompleteness: prepared.projection.textCompleteness,
            byteCount: prepared.budgetByteCount,
            payloadByteCount: prepared.payload.count,
            capturedAt: capturedAt,
            sourceApplicationName: applicationName,
            sourceApplicationBundleIdentifier: bundleIdentifier,
            sourceNamespace: sourceNamespace,
            sourceID: prepared.sourceID
        )
    }

    private func installPreparedItem(
        _ item: ClipboardHistoryItem,
        transientPayload: Data?,
        persistAfterInstall: Bool
    ) {
        let existingIndex = storedItems.firstIndex {
            $0.sourceNamespace == item.sourceNamespace
                && $0.sourceID == item.sourceID
        }
        if let existingIndex {
            let existing = storedItems.remove(at: existingIndex)
            totalBytes = max(0, totalBytes - existing.byteCount)
        }
        storedItems.insert(item, at: 0)
        if let transientPayload {
            transientPayloads[item.id] = transientPayload
        } else {
            transientPayloads.removeValue(forKey: item.id)
        }
        totalBytes += item.byteCount
        selectedID = item.id
        selectedIDs = [item.id]
        trimToBounds(persistRemovedItems: true)
        if persistAfterInstall, let transientPayload {
            persist(item: item, payload: transientPayload)
        }
        notifyObservers()
    }

    nonisolated private static func projection(
        for archive: ClipboardPasteboardArchive
    ) -> ClipboardHistoryArchiveProjection {
        let typeNames = archive.items.flatMap(\.types)
        let loweredTypes = typeNames.map { $0.lowercased() }
        let hasFiles = loweredTypes.contains {
            $0 == NSPasteboard.PasteboardType.fileURL.rawValue.lowercased()
                || $0.contains("filenamespboardtype")
        }
        let hasImage = archive.containsImageRepresentation
        let hasLink = loweredTypes.contains {
            $0 == NSPasteboard.PasteboardType.URL.rawValue.lowercased()
                || $0 == "public.url"
        }
        let hasColor = loweredTypes.contains { $0.contains("color") }
        let hasText = loweredTypes.contains {
            $0 == NSPasteboard.PasteboardType.string.rawValue.lowercased()
                || $0 == "public.text"
                || $0.contains("plain-text")
                || $0.contains("stringpboardtype")
        }

        let textualValues = decodedTextualValues(in: archive)
        let fileValues = decodedFileValues(in: archive)
        let urlValues = decodedValues(
            in: archive,
            matching: { typeName in
                let lowered = typeName.lowercased()
                return lowered == NSPasteboard.PasteboardType.URL.rawValue
                    .lowercased() || lowered == "public.url"
            }
        )

        let kind: ClipboardItemKind
        let canonicalText: String?
        let displayText: String?
        let completeness: ClipboardTextCompleteness
        if hasFiles {
            kind = .files
            canonicalText = joinedSearchText(fileValues)
            let names = fileValues.map { value -> String in
                guard let url = URL(string: value), url.isFileURL else {
                    return URL(fileURLWithPath: value).lastPathComponent
                }
                return url.lastPathComponent
            }.filter { !$0.isEmpty }
            displayText = joinedSearchText(names) ?? "文件"
            completeness = canonicalText == nil ? .unavailable : .complete
        } else if hasImage {
            kind = .image
            canonicalText = nil
            displayText = "图像"
            completeness = .unavailable
        } else if hasLink {
            kind = .link
            canonicalText = urlValues.first ?? textualValues.first
            displayText = canonicalText ?? "链接"
            completeness = canonicalText == nil ? .unavailable : .complete
        } else if hasColor {
            kind = .color
            canonicalText = textualValues.first
            displayText = canonicalText ?? "颜色"
            completeness = canonicalText == nil ? .unavailable : .complete
        } else if hasText {
            kind = .text
            canonicalText = textualValues.first
            displayText = canonicalText
            completeness = canonicalText == nil ? .unavailable : .complete
        } else {
            kind = .unknown
            canonicalText = textualValues.first
            displayText = canonicalText ?? "未知剪贴板内容"
            completeness = canonicalText == nil ? .unavailable : .previewOnly
        }

        return ClipboardHistoryArchiveProjection(
            kind: kind,
            displayText: displayText,
            searchText: joinedSearchText(
                textualValues + fileValues + urlValues + [displayText]
            ),
            canonicalText: canonicalText,
            textCompleteness: completeness
        )
    }

    nonisolated private static func decodedTextualValues(
        in archive: ClipboardPasteboardArchive
    ) -> [String] {
        decodedValues(in: archive) { typeName in
            let lowered = typeName.lowercased()
            return lowered == NSPasteboard.PasteboardType.string.rawValue
                .lowercased()
                || lowered == "public.text"
                || lowered.contains("plain-text")
                || lowered.contains("stringpboardtype")
                || lowered == NSPasteboard.PasteboardType.URL.rawValue
                    .lowercased()
                || lowered == NSPasteboard.PasteboardType.fileURL.rawValue
                    .lowercased()
        }
    }

    nonisolated private static func decodedFileValues(
        in archive: ClipboardPasteboardArchive
    ) -> [String] {
        var values = decodedValues(in: archive) { typeName in
            typeName.lowercased()
                == NSPasteboard.PasteboardType.fileURL.rawValue.lowercased()
        }
        for item in archive.items {
            for typeName in item.types
                where typeName.lowercased().contains("filenamespboardtype") {
                guard let data = item.dataByType[typeName],
                      let propertyList = try? PropertyListSerialization
                        .propertyList(from: data, options: [], format: nil),
                      let filenames = propertyList as? [String] else { continue }
                values.append(contentsOf: filenames)
            }
        }
        return uniqueNonemptyStrings(values)
    }

    nonisolated private static func decodedValues(
        in archive: ClipboardPasteboardArchive,
        matching predicate: (String) -> Bool
    ) -> [String] {
        var values: [String] = []
        for item in archive.items {
            for typeName in item.types where predicate(typeName) {
                guard let data = item.dataByType[typeName],
                      let value = decodedString(data, typeName: typeName),
                      !value.contains("\0") else { continue }
                values.append(value)
            }
        }
        return uniqueNonemptyStrings(values)
    }

    nonisolated private static func decodedString(
        _ data: Data,
        typeName: String
    ) -> String? {
        let lowered = typeName.lowercased()
        let encodings: [String.Encoding]
        if lowered.contains("utf16-external") {
            encodings = [.utf16, .utf16BigEndian, .utf16LittleEndian]
        } else if lowered.contains("utf16") {
            encodings = [.utf16LittleEndian, .utf16, .utf16BigEndian]
        } else if lowered.contains("traditional-mac") {
            encodings = [.macOSRoman, .utf8]
        } else {
            encodings = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian]
        }
        for encoding in encodings {
            guard let value = String(data: data, encoding: encoding) else {
                continue
            }
            let cleaned = value.trimmingCharacters(
                in: CharacterSet(charactersIn: "\0")
            )
            if !cleaned.contains("\0") { return cleaned }
        }
        return nil
    }

    nonisolated private static func uniqueNonemptyStrings(
        _ values: [String]
    ) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            guard !value.isEmpty else { return false }
            return seen.insert(value).inserted
        }
    }

    nonisolated private static func joinedSearchText(
        _ values: String?...
    ) -> String? {
        joinedSearchText(values)
    }

    nonisolated private static func joinedSearchText(
        _ values: [String?]
    ) -> String? {
        joinedSearchText(values.compactMap { $0 })
    }

    nonisolated private static func joinedSearchText(
        _ values: [String]
    ) -> String? {
        let unique = uniqueNonemptyStrings(values)
        return unique.isEmpty ? nil : unique.joined(separator: "\n")
    }

    nonisolated private static func sourceID(
        for archive: ClipboardPasteboardArchive
    ) -> String {
        var hasher = SHA256()
        update(&hasher, integer: UInt64(archive.items.count))
        for item in archive.items {
            let types = item.types.sorted()
            update(&hasher, integer: UInt64(types.count))
            for typeName in types {
                update(&hasher, data: Data(typeName.utf8))
                update(&hasher, data: item.dataByType[typeName] ?? Data())
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func stableID(
        sourceNamespace: String,
        sourceID: String
    ) -> UUID {
        var hasher = SHA256()
        for value in [sourceNamespace, sourceID] {
            hasher.update(data: Data([1]))
            update(&hasher, data: Data(value.utf8))
        }
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    nonisolated private static func update(
        _ hasher: inout SHA256,
        data: Data
    ) {
        hasher.update(data: Data([1]))
        update(&hasher, integer: UInt64(data.count))
        hasher.update(data: data)
    }

    nonisolated private static func update(
        _ hasher: inout SHA256,
        integer: UInt64
    ) {
        var littleEndian = integer.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            hasher.update(data: Data(bytes))
        }
    }

    private func replacingID(
        of item: ClipboardHistoryItem,
        with id: UUID
    ) -> ClipboardHistoryItem {
        guard item.id != id else { return item }
        return ClipboardHistoryItem(
            id: id,
            kind: item.kind,
            displayText: item.displayText,
            searchText: item.searchText,
            canonicalText: item.canonicalText,
            textCompleteness: item.textCompleteness,
            byteCount: item.byteCount,
            payloadByteCount: item.payloadByteCount,
            capturedAt: item.capturedAt,
            sourceApplicationName: item.sourceApplicationName,
            sourceApplicationBundleIdentifier:
                item.sourceApplicationBundleIdentifier,
            sourceNamespace: item.sourceNamespace,
            sourceID: item.sourceID
        )
    }

    private func persistenceRecord(
        for item: ClipboardHistoryItem,
        payload: Data
    ) -> ClipboardHistoryImportRecord {
        ClipboardHistoryImportRecord(
            id: item.id,
            kind: item.kind,
            displayText: item.displayText,
            searchText: item.searchText,
            canonicalText: item.canonicalText,
            textCompleteness: item.textCompleteness,
            capturedAt: item.capturedAt,
            sourceApplicationName: item.sourceApplicationName,
            sourceApplicationBundleIdentifier:
                item.sourceApplicationBundleIdentifier,
            sourceNamespace: item.sourceNamespace,
            sourceID: item.sourceID,
            sourceChecksum: item.sourceID,
            opaquePayload: payload
        )
    }

    private func persist(item: ClipboardHistoryItem, payload: Data) {
        guard let persistence else { return }
        let record = persistenceRecord(for: item, payload: payload)
        persistence.upsert(record) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case let .success(persistedID):
                    reconcilePersistedID(
                        temporaryID: item.id,
                        persistedID: persistedID
                    )
                case let .failure(error):
                    IMELog.write(
                        "clipboard persistence upsert failed: "
                            + error.localizedDescription
                    )
                }
            }
        }
    }

    private func reconcilePersistedID(
        temporaryID: UUID,
        persistedID: UUID
    ) {
        defer { transientPayloads.removeValue(forKey: temporaryID) }
        guard temporaryID != persistedID,
              let temporaryIndex = storedItems.firstIndex(where: {
                  $0.id == temporaryID
              }) else { return }

        if let persistedIndex = storedItems.firstIndex(where: {
            $0.id == persistedID
        }) {
            let removed = storedItems.remove(at: temporaryIndex)
            totalBytes = max(0, totalBytes - removed.byteCount)
            selectedID = persistedID
            if selectedIDs.remove(temporaryID) != nil {
                selectedIDs.insert(persistedID)
            }
            if persistedIndex != 0,
               let currentIndex = storedItems.firstIndex(where: {
                   $0.id == persistedID
               }) {
                let persisted = storedItems.remove(at: currentIndex)
                storedItems.insert(persisted, at: 0)
            }
        } else {
            let item = storedItems[temporaryIndex]
            storedItems[temporaryIndex] = ClipboardHistoryItem(
                id: persistedID,
                kind: item.kind,
                displayText: item.displayText,
                searchText: item.searchText,
                canonicalText: item.canonicalText,
                textCompleteness: item.textCompleteness,
                byteCount: item.byteCount,
                payloadByteCount: item.payloadByteCount,
                capturedAt: item.capturedAt,
                sourceApplicationName: item.sourceApplicationName,
                sourceApplicationBundleIdentifier:
                    item.sourceApplicationBundleIdentifier,
                sourceNamespace: item.sourceNamespace,
                sourceID: item.sourceID
            )
            if selectedID == temporaryID { selectedID = persistedID }
            if selectedIDs.remove(temporaryID) != nil {
                selectedIDs.insert(persistedID)
            }
        }
        notifyObservers()
    }

    private func requestPersistenceLoadIfNeeded() {
        guard !didRequestPersistenceLoad, let persistence else { return }
        didRequestPersistenceLoad = true
        let requestedGeneration = persistenceMutationGeneration
        persistence.loadAllMetadata { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard requestedGeneration == persistenceMutationGeneration else {
                    didRequestPersistenceLoad = false
                    requestPersistenceLoadIfNeeded()
                    return
                }
                switch result {
                case let .success(metadata):
                    mergePersistedMetadata(metadata)
                case let .failure(error):
                    IMELog.write(
                        "clipboard persistence load failed: "
                            + error.localizedDescription
                    )
                }
            }
        }
    }

    private func mergePersistedMetadata(
        _ metadata: [ClipboardStoredItemMetadata]
    ) {
        var knownIDs = Set(storedItems.map(\.id))
        var knownSourceIdentities = Set(storedItems.map {
            $0.sourceNamespace + "\0" + $0.sourceID
        })
        var merged = storedItems
        merged.reserveCapacity(storedItems.count + metadata.count)
        for persisted in metadata {
            let sourceIdentity = persisted.sourceNamespace + "\0"
                + persisted.sourceID
            guard knownIDs.insert(persisted.id).inserted,
                  knownSourceIdentities.insert(sourceIdentity).inserted else {
                continue
            }
            merged.append(ClipboardHistoryItem(metadata: persisted))
        }
        storedItems = merged
        totalBytes = storedItems.reduce(into: 0) { total, item in
            let (next, overflow) = total.addingReportingOverflow(item.byteCount)
            total = overflow ? Int.max : next
        }
        trimToBounds(persistRemovedItems: true)
        if selectedID == nil { selectedID = storedItems.first?.id }
        if selectedIDs.isEmpty, let selectedID { selectedIDs = [selectedID] }
        notifyObservers()
    }

    private func reconcilePolling() {
        let nominallyEligible = started
            && captureState.captureEnabled

        guard nominallyEligible, captureState.protection.isEmpty else {
            invalidateTimer()
            needsPasteboardBaseline = true
            _ = resolveEffectiveProtection(notifyOnChange: true)
            return
        }

        let protection = resolveEffectiveProtection(notifyOnChange: true)
        if protection.isEmpty, needsPasteboardBaseline {
            // Baseline only: never import content that appeared while capture
            // was stopped, hidden, disabled, locked, or protected.
            lastObservedPasteboardChangeCount = pasteboard.changeCount
            needsPasteboardBaseline = false
        }

        guard schedulesAutomaticPolling, timer == nil else { return }
        let timer = Timer(timeInterval: configuration.pollingInterval,
                          repeats: true) { [weak self] _ in
            Task { @MainActor in
                _ = self?.pollNow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    @discardableResult
    private func resolveEffectiveProtection(notifyOnChange: Bool) -> ClipboardHistoryProtection {
        let resolved = captureState.protection.union(protectionProbe())
        guard resolved != effectiveProtection else { return resolved }
        effectiveProtection = resolved
        contentAccessGeneration &+= 1
        if !resolved.isEmpty {
            needsPasteboardBaseline = true
        }
        if notifyOnChange {
            notifyObservers()
        }
        return resolved
    }

    private func trimToBounds(persistRemovedItems: Bool = false) {
        while storedItems.count > configuration.maximumItems
                || totalBytes > configuration.maximumTotalBytes {
            guard let removed = storedItems.popLast() else { break }
            totalBytes -= removed.byteCount
            transientPayloads.removeValue(forKey: removed.id)
            if persistRemovedItems { persistence?.delete(id: removed.id) }
        }
        totalBytes = max(0, totalBytes)
        let validIDs = Set(storedItems.map(\.id))
        selectedIDs.formIntersection(validIDs)
        if let selectedID, !storedItems.contains(where: { $0.id == selectedID }) {
            self.selectedID = storedItems.first?.id
        }
        if selectedIDs.isEmpty, let selectedID { selectedIDs = [selectedID] }
    }

    private func notifyObservers() {
        let callbacks = Array(observers.values)
        callbacks.forEach { $0() }
    }
}
