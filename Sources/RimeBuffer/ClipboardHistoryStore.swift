import CryptoKit
import Darwin
import Foundation
import GRDB

enum ClipboardItemKind: String, Codable, CaseIterable, Sendable {
    case text
    case link
    case image
    case files
    case color
    case unknown
}

enum ClipboardTextCompleteness: String, Codable, Sendable {
    case complete
    case previewOnly
    case unavailable
}

struct ClipboardStoredItemMetadata: Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: ClipboardItemKind
    let displayText: String?
    let searchText: String?
    let canonicalText: String?
    let textCompleteness: ClipboardTextCompleteness
    let capturedAt: Date
    let lastPromotedAt: Date?
    let sourceApplicationName: String?
    let sourceApplicationBundleIdentifier: String?
    let sourceNamespace: String
    let sourceID: String
    let sourceChecksum: String?
    let pasteRawType: Int?
    let pasteIdentifier: String?
    let pasteTitle: String?
    let pasteCreatedAt: Date?
    let pasteUpdatedAt: Date?
    let pasteRawPreviewByteCount: Int
    let payloadByteCount: Int
}

/// Large source representations are deliberately excluded from metadata reads.
/// They cross this lazy boundary only when an item is explicitly activated,
/// exported, or audited.
struct ClipboardStoredPayload: Sendable {
    let itemID: UUID
    let pasteRawPreview: Data?
    let opaquePayload: Data?
}

/// A normalized source-application icon. Clipboard rows retain only the bundle
/// identifier, so thousands of imported events do not duplicate the same PNG.
struct ClipboardSourceApplicationIconRecord: Equatable, Sendable {
    let bundleIdentifier: String
    let applicationName: String?
    let pngData: Data
}

/// Versioned, lossless representation used by RIMES instead of depending on
/// Paste's private JSON serialization at activation time.
struct ClipboardNativePayload: Codable, Equatable, Sendable {
    static let formatIdentifier = "com.rimes.clipboard-payload"
    static let currentVersion = 1

    let format: String
    let version: Int
    let sourceNamespace: String
    let sourceOpaquePayload: Data?
    let items: [ClipboardNativePasteboardItem]

    init(
        sourceNamespace: String,
        sourceOpaquePayload: Data?,
        items: [ClipboardNativePasteboardItem]
    ) {
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.sourceNamespace = sourceNamespace
        self.sourceOpaquePayload = sourceOpaquePayload
        self.items = items
    }

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> ClipboardNativePayload {
        let decoded = try PropertyListDecoder().decode(Self.self, from: data)
        guard decoded.format == formatIdentifier,
              decoded.version == currentVersion else {
            throw ClipboardHistoryStoreError.corruptRecord
        }
        return decoded
    }
}

struct ClipboardNativePasteboardItem: Codable, Equatable, Sendable {
    let types: [String]
    let dataByType: [String: Data]
}

struct ClipboardHistoryImportRecord: Sendable {
    let id: UUID
    let kind: ClipboardItemKind
    let displayText: String?
    let searchText: String?
    let canonicalText: String?
    let textCompleteness: ClipboardTextCompleteness
    let capturedAt: Date
    let sourceApplicationName: String?
    let sourceApplicationBundleIdentifier: String?
    let sourceNamespace: String
    let sourceID: String
    let sourceChecksum: String?
    let pasteRawType: Int?
    let pasteIdentifier: String?
    let pasteTitle: String?
    let pasteCreatedAt: Date?
    let pasteUpdatedAt: Date?
    let pasteRawPreview: Data?
    let opaquePayload: Data?

    init(
        id: UUID? = nil,
        kind: ClipboardItemKind,
        displayText: String?,
        searchText: String?,
        canonicalText: String?,
        textCompleteness: ClipboardTextCompleteness,
        capturedAt: Date,
        sourceApplicationName: String?,
        sourceApplicationBundleIdentifier: String?,
        sourceNamespace: String,
        sourceID: String,
        sourceChecksum: String? = nil,
        pasteRawType: Int? = nil,
        pasteIdentifier: String? = nil,
        pasteTitle: String? = nil,
        pasteCreatedAt: Date? = nil,
        pasteUpdatedAt: Date? = nil,
        pasteRawPreview: Data? = nil,
        opaquePayload: Data? = nil
    ) {
        self.id = id ?? ClipboardHistoryStableIdentity.uuid(
            sourceNamespace: sourceNamespace,
            sourceID: sourceID
        )
        self.kind = kind
        self.displayText = displayText
        self.searchText = searchText
        self.canonicalText = canonicalText
        self.textCompleteness = textCompleteness
        self.capturedAt = capturedAt
        self.sourceApplicationName = sourceApplicationName
        self.sourceApplicationBundleIdentifier =
            sourceApplicationBundleIdentifier
        self.sourceNamespace = sourceNamespace
        self.sourceID = sourceID
        self.sourceChecksum = sourceChecksum
        self.pasteRawType = pasteRawType
        self.pasteIdentifier = pasteIdentifier
        self.pasteTitle = pasteTitle
        self.pasteCreatedAt = pasteCreatedAt
        self.pasteUpdatedAt = pasteUpdatedAt
        self.pasteRawPreview = pasteRawPreview
        self.opaquePayload = opaquePayload
    }
}

struct ClipboardBatchImportResult: Equatable, Sendable {
    let sourceRecords: Int
    let inserted: Int
    let updated: Int
    let unchanged: Int
    let resolvedPayloadBytes: Int64

    var isIdempotent: Bool { inserted == 0 && updated == 0 }
}

struct ClipboardHistoryTypeCount: Equatable, Sendable {
    let kind: ClipboardItemKind
    let count: Int
}

struct ClipboardHistoryStoreAudit: Equatable, Sendable {
    let databaseIntegrityOK: Bool
    let totalItemCount: Int
    let sourceIdentityCount: Int
    let duplicateSourceIdentityCount: Int
    let invalidUUIDCount: Int
    let payloadItemCount: Int
    let pasteItemsMissingPayloadCount: Int
    let invalidPayloadLengthCount: Int
    let totalResolvedPayloadBytes: Int64
    let totalPastePreviewBytes: Int64
    let typeCounts: [ClipboardHistoryTypeCount]

    var isConsistent: Bool {
        databaseIntegrityOK
            && totalItemCount == sourceIdentityCount
            && duplicateSourceIdentityCount == 0
            && invalidUUIDCount == 0
            && pasteItemsMissingPayloadCount == 0
            && invalidPayloadLengthCount == 0
    }
}

enum ClipboardHistoryStoreError: LocalizedError {
    case unsafeStorage
    case invalidPermissions
    case invalidRecord
    case duplicateSourceIdentity
    case tooManyRecords
    case oversizedPayload
    case corruptRecord

    var errorDescription: String? {
        switch self {
        case .unsafeStorage:
            return "剪贴板历史数据库路径不安全。"
        case .invalidPermissions:
            return "剪贴板历史数据库权限不符合要求。"
        case .invalidRecord:
            return "剪贴板历史记录格式无效。"
        case .duplicateSourceIdentity:
            return "同一批次包含重复的剪贴板来源标识。"
        case .tooManyRecords:
            return "单次写入的剪贴板记录数量超过上限。"
        case .oversizedPayload:
            return "剪贴板记录负载超过安全上限。"
        case .corruptRecord:
            return "剪贴板历史数据库包含损坏的记录。"
        }
    }
}

/// Thread-safe durable clipboard history. Metadata queries never fetch the
/// potentially large preview/pasteboard blobs.
final class ClipboardHistoryStore: @unchecked Sendable {
    static let maximumBatchRecords = 100_000
    static let maximumPayloadBytes = 512 * 1_024 * 1_024
    static let maximumBatchPayloadBytes: Int64 = 64 * 1_024 * 1_024 * 1_024
    static let maximumSourceIconBytes = 4 * 1_024 * 1_024
    static let maximumSourceIconRecords = 10_000

    let rootDirectory: URL
    let databaseURL: URL

    private let databasePool: DatabasePool
    private let securityLock = NSLock()

    init(rootDirectory requestedRoot: URL? = nil) throws {
        let fileManager = FileManager.default
        let root: URL
        if let requestedRoot {
            root = requestedRoot.standardizedFileURL
            try ClipboardHistoryStorageSecurity.ensurePrivateDirectory(
                root,
                createIntermediateDirectories: true,
                fileManager: fileManager
            )
        } else {
            let applicationSupport = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent(
                    "Application Support",
                    isDirectory: true
                )
            let rimesRoot = applicationSupport.appendingPathComponent(
                "RIMES",
                isDirectory: true
            )
            try ClipboardHistoryStorageSecurity.ensurePrivateDirectory(
                rimesRoot,
                createIntermediateDirectories: false,
                fileManager: fileManager
            )
            root = rimesRoot.appendingPathComponent(
                "clipboard",
                isDirectory: true
            )
            try ClipboardHistoryStorageSecurity.ensurePrivateDirectory(
                root,
                createIntermediateDirectories: false,
                fileManager: fileManager
            )
        }

        let databaseURL = root.appendingPathComponent(
            "clipboard.sqlite",
            isDirectory: false
        )
        try ClipboardHistoryStorageSecurity.prepareDatabaseFile(databaseURL)
        for suffix in ["-wal", "-shm"] {
            try ClipboardHistoryStorageSecurity.validateOptionalRegularFile(
                URL(fileURLWithPath: databaseURL.path + suffix)
            )
        }

        var configuration = Configuration()
        configuration.busyMode = .timeout(5.0)
        configuration.maximumReaderCount = 4
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let pool = try DatabasePool(
            path: databaseURL.path,
            configuration: configuration
        )

        self.rootDirectory = root
        self.databaseURL = databaseURL
        databasePool = pool

        try pool.writeWithoutTransaction { db in
            _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
        }
        try Self.makeMigrator().migrate(pool)
        try tightenDatabaseFiles()
    }

    func loadPage(limit requestedLimit: Int, offset: Int = 0) throws
        -> [ClipboardStoredItemMetadata] {
        guard requestedLimit > 0, offset >= 0 else { return [] }
        let limit = min(requestedLimit, 10_000)
        return try databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: Self.metadataSelect + """

                    ORDER BY COALESCE(last_promoted_at, captured_at) DESC,
                        captured_at DESC, id ASC
                    LIMIT ? OFFSET ?
                    """,
                arguments: [limit, offset]
            ).map(Self.decodeMetadata)
        }
    }

    func loadAllMetadata() throws -> [ClipboardStoredItemMetadata] {
        try databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: Self.metadataSelect + """

                    ORDER BY COALESCE(last_promoted_at, captured_at) DESC,
                        captured_at DESC, id ASC
                    """
            ).map(Self.decodeMetadata)
        }
    }

    func metadata(id: UUID) throws -> ClipboardStoredItemMetadata? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: Self.metadataSelect + " WHERE id = ?",
                arguments: [id.uuidString.lowercased()]
            ) else { return nil }
            return try Self.decodeMetadata(row)
        }
    }

    func payload(for id: UUID) throws -> ClipboardStoredPayload? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, paste_raw_preview, opaque_payload
                    FROM clipboard_items
                    WHERE id = ?
                    """,
                arguments: [id.uuidString.lowercased()]
            ) else { return nil }
            let idText: String = row["id"]
            guard let itemID = UUID(uuidString: idText) else {
                throw ClipboardHistoryStoreError.corruptRecord
            }
            return ClipboardStoredPayload(
                itemID: itemID,
                pasteRawPreview: row["paste_raw_preview"],
                opaquePayload: row["opaque_payload"]
            )
        }
    }

    func sourceApplicationIcon(
        bundleIdentifier: String
    ) throws -> Data? {
        guard Self.isValidBundleIdentifier(bundleIdentifier) else {
            throw ClipboardHistoryStoreError.invalidRecord
        }
        return try databasePool.read { db in
            let data = try Data.fetchOne(
                db,
                sql: """
                    SELECT icon_png
                    FROM clipboard_source_apps
                    WHERE bundle_identifier = ?
                    """,
                arguments: [bundleIdentifier]
            )
            guard let data else { return nil }
            guard data.count <= Self.maximumSourceIconBytes,
                  Self.isPNG(data) else {
                throw ClipboardHistoryStoreError.corruptRecord
            }
            return data
        }
    }

    /// Imports application artwork independently from item payloads. This is
    /// deliberately idempotent and may be rerun to backfill an existing RIMES
    /// history that was migrated before source icons were supported.
    func importSourceApplicationIcons(
        _ records: [ClipboardSourceApplicationIconRecord]
    ) throws {
        guard records.count <= Self.maximumSourceIconRecords else {
            throw ClipboardHistoryStoreError.tooManyRecords
        }
        var seen = Set<String>()
        var totalBytes: Int64 = 0
        for record in records {
            guard Self.isValidBundleIdentifier(record.bundleIdentifier),
                  (record.applicationName?.utf8.count ?? 0) <= 16_384,
                  !(record.applicationName?.contains("\0") ?? false),
                  Self.isPNG(record.pngData),
                  record.pngData.count <= Self.maximumSourceIconBytes else {
                throw ClipboardHistoryStoreError.invalidRecord
            }
            guard seen.insert(record.bundleIdentifier).inserted else {
                throw ClipboardHistoryStoreError.duplicateSourceIdentity
            }
            totalBytes += Int64(record.pngData.count)
            guard totalBytes <= Int64(Self.maximumSourceIconBytes)
                    * Int64(Self.maximumSourceIconRecords) else {
                throw ClipboardHistoryStoreError.oversizedPayload
            }
        }

        try databasePool.write { db in
            for record in records {
                try db.execute(
                    sql: """
                        INSERT INTO clipboard_source_apps (
                            bundle_identifier, application_name, icon_png
                        ) VALUES (?, ?, ?)
                        ON CONFLICT(bundle_identifier) DO UPDATE SET
                            application_name = excluded.application_name,
                            icon_png = excluded.icon_png
                        """,
                    arguments: [
                        record.bundleIdentifier,
                        record.applicationName,
                        record.pngData,
                    ]
                )
            }
        }
        try tightenDatabaseFiles()
    }

    @discardableResult
    func upsert(_ record: ClipboardHistoryImportRecord) throws -> UUID {
        _ = try importBatch([record])
        return try databasePool.read { db in
            guard let idText = try String.fetchOne(
                db,
                sql: """
                    SELECT id FROM clipboard_items
                    WHERE source_namespace = ? AND source_id = ?
                    """,
                arguments: [record.sourceNamespace, record.sourceID]
            ), let id = UUID(uuidString: idText) else {
                throw ClipboardHistoryStoreError.corruptRecord
            }
            return id
        }
    }

    @discardableResult
    func importBatch(_ records: [ClipboardHistoryImportRecord]) throws
        -> ClipboardBatchImportResult {
        guard records.count <= Self.maximumBatchRecords else {
            throw ClipboardHistoryStoreError.tooManyRecords
        }

        var identities = Set<String>()
        var totalPayloadBytes: Int64 = 0
        var normalized: [(ClipboardHistoryImportRecord, String)] = []
        normalized.reserveCapacity(records.count)
        for record in records {
            try Self.validate(record)
            let identity = record.sourceNamespace + "\0" + record.sourceID
            guard identities.insert(identity).inserted else {
                throw ClipboardHistoryStoreError.duplicateSourceIdentity
            }
            totalPayloadBytes += Int64(record.opaquePayload?.count ?? 0)
            guard totalPayloadBytes <= Self.maximumBatchPayloadBytes else {
                throw ClipboardHistoryStoreError.oversizedPayload
            }
            normalized.append((record, Self.fingerprint(record)))
        }

        var inserted = 0
        var updated = 0
        var unchanged = 0
        let importedAt = Date().timeIntervalSince1970
        try databasePool.write { db in
            for (record, fingerprint) in normalized {
                let existing = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT id, record_fingerprint
                        FROM clipboard_items
                        WHERE source_namespace = ? AND source_id = ?
                        """,
                    arguments: [record.sourceNamespace, record.sourceID]
                )
                if let existing {
                    let existingFingerprint: String =
                        existing["record_fingerprint"]
                    if existingFingerprint == fingerprint {
                        unchanged += 1
                        continue
                    }
                    try Self.update(
                        record,
                        fingerprint: fingerprint,
                        importedAt: importedAt,
                        database: db
                    )
                    updated += 1
                } else {
                    try Self.insert(
                        record,
                        fingerprint: fingerprint,
                        importedAt: importedAt,
                        database: db
                    )
                    inserted += 1
                }
            }
        }
        try tightenDatabaseFiles()
        return ClipboardBatchImportResult(
            sourceRecords: records.count,
            inserted: inserted,
            updated: updated,
            unchanged: unchanged,
            resolvedPayloadBytes: totalPayloadBytes
        )
    }

    /// Repeated live content promotes the existing source identity. Importers
    /// that need event preservation must provide a distinct sourceID per event
    /// through `importBatch`.
    @discardableResult
    func insertOrPromote(
        kind: ClipboardItemKind,
        displayText: String?,
        searchText: String?,
        canonicalText: String?,
        textCompleteness: ClipboardTextCompleteness,
        capturedAt: Date = Date(),
        sourceApplicationName: String?,
        sourceApplicationBundleIdentifier: String?,
        sourceNamespace: String = "rimes.clipboard.live.content",
        sourceID requestedSourceID: String? = nil,
        sourceChecksum: String? = nil,
        opaquePayload: Data? = nil
    ) throws -> UUID {
        let sourceID = requestedSourceID ?? Self.liveSourceID(
            kind: kind,
            canonicalText: canonicalText,
            displayText: displayText,
            opaquePayload: opaquePayload
        )
        let record = ClipboardHistoryImportRecord(
            kind: kind,
            displayText: displayText,
            searchText: searchText,
            canonicalText: canonicalText,
            textCompleteness: textCompleteness,
            capturedAt: capturedAt,
            sourceApplicationName: sourceApplicationName,
            sourceApplicationBundleIdentifier:
                sourceApplicationBundleIdentifier,
            sourceNamespace: sourceNamespace,
            sourceID: sourceID,
            sourceChecksum: sourceChecksum,
            opaquePayload: opaquePayload
        )
        let id = try upsert(record)
        _ = try promote(id: id, at: capturedAt)
        return id
    }

    @discardableResult
    func promote(id: UUID, at date: Date = Date()) throws -> Bool {
        let changed = try databasePool.write { db -> Bool in
            try db.execute(
                sql: """
                    UPDATE clipboard_items
                    SET last_promoted_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    date.timeIntervalSince1970,
                    id.uuidString.lowercased(),
                ]
            )
            return db.changesCount > 0
        }
        try tightenDatabaseFiles()
        return changed
    }

    @discardableResult
    func promote(ids: [UUID], at date: Date = Date()) throws -> Int {
        let uniqueIDs = Self.uniqueIDs(ids)
        guard !uniqueIDs.isEmpty else { return 0 }
        let changed = try databasePool.write { db -> Int in
            var changed = 0
            for (index, id) in uniqueIDs.enumerated() {
                try db.execute(
                    sql: """
                        UPDATE clipboard_items
                        SET last_promoted_at = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        date.timeIntervalSince1970 - Double(index) * 0.000_001,
                        id.uuidString.lowercased(),
                    ]
                )
                changed += db.changesCount
            }
            return changed
        }
        try tightenDatabaseFiles()
        return changed
    }

    @discardableResult
    func delete(id: UUID) throws -> Bool {
        let changed = try databasePool.write { db -> Bool in
            try db.execute(
                sql: "DELETE FROM clipboard_items WHERE id = ?",
                arguments: [id.uuidString.lowercased()]
            )
            return db.changesCount > 0
        }
        try tightenDatabaseFiles()
        return changed
    }

    @discardableResult
    func delete(ids: [UUID]) throws -> Int {
        let uniqueIDs = Self.uniqueIDs(ids)
        guard !uniqueIDs.isEmpty else { return 0 }
        let changed = try databasePool.write { db -> Int in
            var changed = 0
            for id in uniqueIDs {
                try db.execute(
                    sql: "DELETE FROM clipboard_items WHERE id = ?",
                    arguments: [id.uuidString.lowercased()]
                )
                changed += db.changesCount
            }
            return changed
        }
        try tightenDatabaseFiles()
        return changed
    }

    @discardableResult
    func clear() throws -> Int {
        let removed = try databasePool.write { db -> Int in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM clipboard_items"
            ) ?? 0
            try db.execute(sql: "DELETE FROM clipboard_items")
            return count
        }
        try tightenDatabaseFiles()
        return removed
    }

    func count() throws -> Int {
        try databasePool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboard_items")
                ?? 0
        }
    }

    func typeCounts() throws -> [ClipboardHistoryTypeCount] {
        try databasePool.read(Self.fetchTypeCounts)
    }

    func audit() throws -> ClipboardHistoryStoreAudit {
        try databasePool.read { db in
            let integrityRows = try String.fetchAll(
                db,
                sql: "PRAGMA quick_check"
            )
            let total = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM clipboard_items"
            ) ?? 0
            let sourceIdentities = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM (
                        SELECT source_namespace, source_id
                        FROM clipboard_items
                        GROUP BY source_namespace, source_id
                    )
                    """
            ) ?? 0
            let duplicates = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM (
                        SELECT 1 FROM clipboard_items
                        GROUP BY source_namespace, source_id
                        HAVING COUNT(*) > 1
                    )
                    """
            ) ?? 0
            let invalidIDs = try String.fetchAll(
                db,
                sql: "SELECT id FROM clipboard_items"
            ).reduce(into: 0) { count, value in
                if UUID(uuidString: value) == nil { count += 1 }
            }
            let payloadItems = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM clipboard_items
                    WHERE opaque_payload IS NOT NULL
                    """
            ) ?? 0
            let missingPastePayloads = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM clipboard_items
                    WHERE paste_raw_type IS NOT NULL
                        AND opaque_payload IS NULL
                    """
            ) ?? 0
            let invalidLengths = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM clipboard_items
                    WHERE payload_byte_count !=
                        COALESCE(length(opaque_payload), 0)
                    """
            ) ?? 0
            let payloadBytes = try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(payload_byte_count), 0) FROM clipboard_items"
            ) ?? 0
            let previewBytes = try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(length(paste_raw_preview)), 0) FROM clipboard_items"
            ) ?? 0
            return ClipboardHistoryStoreAudit(
                databaseIntegrityOK: integrityRows == ["ok"],
                totalItemCount: total,
                sourceIdentityCount: sourceIdentities,
                duplicateSourceIdentityCount: duplicates,
                invalidUUIDCount: invalidIDs,
                payloadItemCount: payloadItems,
                pasteItemsMissingPayloadCount: missingPastePayloads,
                invalidPayloadLengthCount: invalidLengths,
                totalResolvedPayloadBytes: payloadBytes,
                totalPastePreviewBytes: previewBytes,
                typeCounts: try Self.fetchTypeCounts(db)
            )
        }
    }

    private func tightenDatabaseFiles() throws {
        securityLock.lock()
        defer { securityLock.unlock() }
        try ClipboardHistoryStorageSecurity.tightenDatabaseFiles(databaseURL)
    }

    private static let metadataSelect = """
        SELECT id, kind, display_text, search_text, canonical_text,
            text_completeness, captured_at, last_promoted_at,
            source_application_name, source_application_bundle_identifier,
            source_namespace, source_id, source_checksum, paste_raw_type,
            paste_identifier, paste_title, paste_created_at,
            paste_updated_at,
            COALESCE(length(paste_raw_preview), 0) AS preview_byte_count,
            payload_byte_count
        FROM clipboard_items
        """

    private static func decodeMetadata(_ row: Row) throws
        -> ClipboardStoredItemMetadata {
        let idText: String = row["id"]
        let kindText: String = row["kind"]
        let completenessText: String = row["text_completeness"]
        guard let id = UUID(uuidString: idText),
              let kind = ClipboardItemKind(rawValue: kindText),
              let completeness = ClipboardTextCompleteness(
                  rawValue: completenessText
              ) else {
            throw ClipboardHistoryStoreError.corruptRecord
        }
        let capturedAt: Double = row["captured_at"]
        let promotedAt: Double? = row["last_promoted_at"]
        let pasteCreatedAt: Double? = row["paste_created_at"]
        let pasteUpdatedAt: Double? = row["paste_updated_at"]
        return ClipboardStoredItemMetadata(
            id: id,
            kind: kind,
            displayText: row["display_text"],
            searchText: row["search_text"],
            canonicalText: row["canonical_text"],
            textCompleteness: completeness,
            capturedAt: Date(timeIntervalSince1970: capturedAt),
            lastPromotedAt: promotedAt.map(Date.init(timeIntervalSince1970:)),
            sourceApplicationName: row["source_application_name"],
            sourceApplicationBundleIdentifier:
                row["source_application_bundle_identifier"],
            sourceNamespace: row["source_namespace"],
            sourceID: row["source_id"],
            sourceChecksum: row["source_checksum"],
            pasteRawType: row["paste_raw_type"],
            pasteIdentifier: row["paste_identifier"],
            pasteTitle: row["paste_title"],
            pasteCreatedAt: pasteCreatedAt.map(
                Date.init(timeIntervalSince1970:)
            ),
            pasteUpdatedAt: pasteUpdatedAt.map(
                Date.init(timeIntervalSince1970:)
            ),
            pasteRawPreviewByteCount: row["preview_byte_count"],
            payloadByteCount: row["payload_byte_count"]
        )
    }

    private static func fetchTypeCounts(_ db: Database) throws
        -> [ClipboardHistoryTypeCount] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT kind, COUNT(*) AS item_count
                FROM clipboard_items
                GROUP BY kind
                ORDER BY kind
                """
        ).map { row in
            let kindText: String = row["kind"]
            guard let kind = ClipboardItemKind(rawValue: kindText) else {
                throw ClipboardHistoryStoreError.corruptRecord
            }
            return ClipboardHistoryTypeCount(
                kind: kind,
                count: row["item_count"]
            )
        }
    }

    private static func validate(_ record: ClipboardHistoryImportRecord) throws {
        let identityValues = [record.sourceNamespace, record.sourceID]
        guard identityValues.allSatisfy({
            !$0.isEmpty && !$0.contains("\0") && $0.utf8.count <= 16_384
        }), record.sourceChecksum?.utf8.count ?? 0 <= 16_384,
        record.pasteIdentifier?.utf8.count ?? 0 <= 16_384 else {
            throw ClipboardHistoryStoreError.invalidRecord
        }
        let payloadBytes = record.opaquePayload?.count ?? 0
        guard payloadBytes <= maximumPayloadBytes else {
            throw ClipboardHistoryStoreError.oversizedPayload
        }
        guard record.pasteRawPreview?.count ?? 0 <= maximumPayloadBytes else {
            throw ClipboardHistoryStoreError.oversizedPayload
        }
    }

    private static func uniqueIDs(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && !value.contains("\0")
            && value.utf8.count <= 16_384
    }

    private static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    }

    private static func insert(
        _ record: ClipboardHistoryImportRecord,
        fingerprint: String,
        importedAt: Double,
        database db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO clipboard_items (
                    id, kind, display_text, search_text, canonical_text,
                    text_completeness, captured_at, last_promoted_at,
                    source_application_name,
                    source_application_bundle_identifier,
                    source_namespace, source_id, source_checksum,
                    paste_raw_type, paste_identifier, paste_title,
                    paste_created_at, paste_updated_at, paste_raw_preview,
                    opaque_payload, payload_byte_count,
                    record_fingerprint, imported_at
                ) VALUES (
                    ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                    ?, ?, ?, ?, ?, ?
                )
                """,
            arguments: arguments(
                record,
                fingerprint: fingerprint,
                importedAt: importedAt,
                includeID: true
            )
        )
    }

    private static func update(
        _ record: ClipboardHistoryImportRecord,
        fingerprint: String,
        importedAt: Double,
        database db: Database
    ) throws {
        var values = arguments(
            record,
            fingerprint: fingerprint,
            importedAt: importedAt,
            includeID: false
        )
        values += [record.sourceNamespace, record.sourceID]
        try db.execute(
            sql: """
                UPDATE clipboard_items SET
                    kind = ?, display_text = ?, search_text = ?,
                    canonical_text = ?, text_completeness = ?,
                    captured_at = ?, source_application_name = ?,
                    source_application_bundle_identifier = ?,
                    source_namespace = ?, source_id = ?, source_checksum = ?,
                    paste_raw_type = ?, paste_identifier = ?, paste_title = ?,
                    paste_created_at = ?, paste_updated_at = ?,
                    paste_raw_preview = ?, opaque_payload = ?,
                    payload_byte_count = ?, record_fingerprint = ?,
                    imported_at = ?
                WHERE source_namespace = ? AND source_id = ?
                """,
            arguments: values
        )
    }

    private static func arguments(
        _ record: ClipboardHistoryImportRecord,
        fingerprint: String,
        importedAt: Double,
        includeID: Bool
    ) -> StatementArguments {
        var values: [DatabaseValueConvertible?] = []
        if includeID {
            values.append(record.id.uuidString.lowercased())
        }
        values += [
            record.kind.rawValue,
            record.displayText,
            record.searchText,
            record.canonicalText,
            record.textCompleteness.rawValue,
            record.capturedAt.timeIntervalSince1970,
            record.sourceApplicationName,
            record.sourceApplicationBundleIdentifier,
            record.sourceNamespace,
            record.sourceID,
            record.sourceChecksum,
            record.pasteRawType,
            record.pasteIdentifier,
            record.pasteTitle,
            record.pasteCreatedAt?.timeIntervalSince1970,
            record.pasteUpdatedAt?.timeIntervalSince1970,
            record.pasteRawPreview,
            record.opaquePayload,
            record.opaquePayload?.count ?? 0,
            fingerprint,
            importedAt,
        ]
        return StatementArguments(values)
    }

    private static func fingerprint(
        _ record: ClipboardHistoryImportRecord
    ) -> String {
        var hasher = SHA256()
        ClipboardHistoryStableIdentity.update(
            &hasher,
            values: [
                record.id.uuidString.lowercased(),
                record.kind.rawValue,
                record.displayText,
                record.searchText,
                record.canonicalText,
                record.textCompleteness.rawValue,
                String(format: "%.17g", record.capturedAt.timeIntervalSince1970),
                record.sourceApplicationName,
                record.sourceApplicationBundleIdentifier,
                record.sourceNamespace,
                record.sourceID,
                record.sourceChecksum,
                record.pasteRawType.map(String.init),
                record.pasteIdentifier,
                record.pasteTitle,
                record.pasteCreatedAt.map {
                    String(format: "%.17g", $0.timeIntervalSince1970)
                },
                record.pasteUpdatedAt.map {
                    String(format: "%.17g", $0.timeIntervalSince1970)
                },
            ]
        )
        ClipboardHistoryStableIdentity.update(&hasher, data: record.pasteRawPreview)
        ClipboardHistoryStableIdentity.update(&hasher, data: record.opaquePayload)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func liveSourceID(
        kind: ClipboardItemKind,
        canonicalText: String?,
        displayText: String?,
        opaquePayload: Data?
    ) -> String {
        var hasher = SHA256()
        ClipboardHistoryStableIdentity.update(
            &hasher,
            values: [kind.rawValue, canonicalText, displayText]
        )
        ClipboardHistoryStableIdentity.update(&hasher, data: opaquePayload)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("clipboard-history-v1") { db in
            try db.execute(sql: """
                CREATE TABLE clipboard_items (
                    id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    display_text TEXT,
                    search_text TEXT,
                    canonical_text TEXT,
                    text_completeness TEXT NOT NULL,
                    captured_at DOUBLE NOT NULL,
                    last_promoted_at DOUBLE,
                    source_application_name TEXT,
                    source_application_bundle_identifier TEXT,
                    source_namespace TEXT NOT NULL,
                    source_id TEXT NOT NULL,
                    source_checksum TEXT,
                    paste_raw_type INTEGER,
                    paste_identifier TEXT,
                    paste_title TEXT,
                    paste_created_at DOUBLE,
                    paste_updated_at DOUBLE,
                    paste_raw_preview BLOB,
                    opaque_payload BLOB,
                    payload_byte_count INTEGER NOT NULL DEFAULT 0,
                    record_fingerprint TEXT NOT NULL,
                    imported_at DOUBLE NOT NULL,
                    UNIQUE(source_namespace, source_id),
                    CHECK(payload_byte_count >= 0),
                    CHECK(payload_byte_count =
                        COALESCE(length(opaque_payload), 0))
                );

                CREATE INDEX clipboard_items_display_order
                    ON clipboard_items(last_promoted_at DESC, captured_at DESC);
                CREATE INDEX clipboard_items_kind
                    ON clipboard_items(kind);
                CREATE INDEX clipboard_items_source_checksum
                    ON clipboard_items(source_checksum);
                """)
        }
        migrator.registerMigration("clipboard-history-v2-source-icons") { db in
            try db.execute(sql: """
                CREATE TABLE clipboard_source_apps (
                    bundle_identifier TEXT PRIMARY KEY NOT NULL,
                    application_name TEXT,
                    icon_png BLOB NOT NULL
                );
                """)
        }
        return migrator
    }
}

private enum ClipboardHistoryStableIdentity {
    static func uuid(sourceNamespace: String, sourceID: String) -> UUID {
        var hasher = SHA256()
        update(&hasher, values: [sourceNamespace, sourceID])
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

    static func update(
        _ hasher: inout SHA256,
        values: [String?]
    ) {
        for value in values {
            guard let value else {
                hasher.update(data: Data([0]))
                continue
            }
            hasher.update(data: Data([1]))
            update(&hasher, data: Data(value.utf8))
        }
    }

    static func update(_ hasher: inout SHA256, data: Data?) {
        guard let data else {
            hasher.update(data: Data([0]))
            return
        }
        hasher.update(data: Data([1]))
        var length = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &length) { bytes in
            hasher.update(data: Data(bytes))
        }
        hasher.update(data: data)
    }
}

private enum ClipboardHistoryStorageSecurity {
    static func ensurePrivateDirectory(
        _ url: URL,
        createIntermediateDirectories: Bool,
        fileManager: FileManager
    ) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else {
                throw ClipboardHistoryStoreError.unsafeStorage
            }
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: createIntermediateDirectories,
                attributes: [.posixPermissions: 0o700]
            )
        }
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else {
            throw ClipboardHistoryStoreError.unsafeStorage
        }
        guard chmod(url.path, S_IRWXU) == 0 else {
            throw ClipboardHistoryStoreError.invalidPermissions
        }
    }

    static func prepareDatabaseFile(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            try validateRegularFile(info)
            guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
                throw ClipboardHistoryStoreError.invalidPermissions
            }
            return
        }
        guard errno == ENOENT else {
            throw ClipboardHistoryStoreError.unsafeStorage
        }
        let descriptor = open(
            url.path,
            O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ClipboardHistoryStoreError.unsafeStorage
        }
        defer { close(descriptor) }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw ClipboardHistoryStoreError.invalidPermissions
        }
    }

    static func validateOptionalRegularFile(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else {
                throw ClipboardHistoryStoreError.unsafeStorage
            }
            return
        }
        try validateRegularFile(info)
    }

    static func tightenDatabaseFiles(_ databaseURL: URL) throws {
        for path in [
            databaseURL.path,
            databaseURL.path + "-wal",
            databaseURL.path + "-shm",
        ] {
            var info = stat()
            if lstat(path, &info) != 0 {
                guard errno == ENOENT else {
                    throw ClipboardHistoryStoreError.unsafeStorage
                }
                continue
            }
            try validateRegularFile(info)
            guard chmod(path, S_IRUSR | S_IWUSR) == 0 else {
                throw ClipboardHistoryStoreError.invalidPermissions
            }
        }
    }

    private static func validateRegularFile(_ info: stat) throws {
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid() else {
            throw ClipboardHistoryStoreError.unsafeStorage
        }
    }
}
