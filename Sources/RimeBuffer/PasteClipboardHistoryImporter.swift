import AppKit
import Darwin
import Foundation
import GRDB

struct PasteClipboardTypeCount: Equatable, Sendable {
    let rawType: Int
    let kind: ClipboardItemKind
    let count: Int
}

struct PasteClipboardSourceSummary: Equatable, Sendable {
    let sourceRecords: Int
    let inlinePayloads: Int
    let externalPayloads: Int
    let compressedPayloadBytes: Int64
    let oldestTimestamp: Date?
    let newestTimestamp: Date?
    let typeCounts: [PasteClipboardTypeCount]
}

struct PasteClipboardImportResult: Equatable, Sendable {
    let sourceRecords: Int
    let inserted: Int
    let updated: Int
    let unchanged: Int
    let compressedPayloadBytes: Int64
    let storedPayloadBytes: Int64
    let typeCounts: [PasteClipboardTypeCount]

    var isIdempotent: Bool { inserted == 0 && updated == 0 }
    var nativePayloadBytes: Int64 { storedPayloadBytes }
}

enum PasteClipboardHistoryImportError: LocalizedError {
    case sourceApplicationRunning
    case unsafeSource
    case unsupportedApplication
    case unsupportedSchema
    case inconsistentSource
    case unsupportedPayloadWrapper
    case unsafeExternalPayload
    case missingExternalPayload
    case compressedPayloadLimit
    case invalidCompressedPayload
    case invalidPayloadEnvelope
    case invalidPreview

    var errorDescription: String? {
        switch self {
        case .sourceApplicationRunning:
            return "请先完全退出 Paste 及其后台辅助程序。"
        case .unsafeSource:
            return "Paste 数据库路径不安全。"
        case .unsupportedApplication:
            return "只支持从 Paste 5.0.5 导入。"
        case .unsupportedSchema:
            return "Paste 数据库结构不是已验证的 v3 结构。"
        case .inconsistentSource:
            return "Paste 数据库记录关系不完整。"
        case .unsupportedPayloadWrapper:
            return "Paste 记录使用了未知的负载封装。"
        case .unsafeExternalPayload:
            return "Paste 外置负载路径不安全。"
        case .missingExternalPayload:
            return "Paste 外置负载缺失。"
        case .compressedPayloadLimit:
            return "Paste 负载超过安全解压上限。"
        case .invalidCompressedPayload:
            return "Paste 负载无法安全解压。"
        case .invalidPayloadEnvelope:
            return "Paste 负载结构无效。"
        case .invalidPreview:
            return "Paste 预览结构无效。"
        }
    }
}

/// Lossless importer for the locally installed Paste 5.0.5 Core Data store.
/// The source database is opened read-only and queried in one deferred read
/// transaction, so the active WAL participates in a consistent snapshot.
final class PasteClipboardHistoryImporter {
    static let sourceNamespace = "paste.app.v5"
    static let supportedPasteVersion = "5.0.5"

    private static let pasteProcessBundleIdentifiers = [
        "com.wiheads.paste",
        "com.wiheads.paste.mac-helper",
    ]

    static let defaultSourceDatabaseURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Containers", isDirectory: true)
        .appendingPathComponent("com.wiheads.paste", isDirectory: true)
        .appendingPathComponent("Data", isDirectory: true)
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("Paste", isDirectory: true)
        .appendingPathComponent("db.sqlite", isDirectory: false)

    let sourceDatabaseURL: URL
    let pasteApplicationURL: URL

    init(
        sourceDatabaseURL: URL = defaultSourceDatabaseURL,
        pasteApplicationURL: URL = URL(
            fileURLWithPath: "/Applications/Paste.app",
            isDirectory: true
        )
    ) {
        self.sourceDatabaseURL = sourceDatabaseURL.standardizedFileURL
        self.pasteApplicationURL = pasteApplicationURL.standardizedFileURL
    }

    func inspectSource() throws -> PasteClipboardSourceSummary {
        try Self.validatePasteIsStopped()
        try validateApplication()
        let externalRoot = try validateExternalRoot()
        let queue = try makeReadOnlyQueue()
        let summary = try queue.read { db in
            // DatabaseQueue.read already wraps this closure in one isolated,
            // read-only transaction. Do not nest another BEGIN here.
            try Self.validateDatabase(db)
            return try Self.fetchSummary(
                db,
                resolvingPayloadsUnder: externalRoot
            )
        }
        // SQLite metadata and Core Data external blobs are separate files.
        // Re-check immediately after the complete read so an active Paste
        // writer can never be accepted as a valid source snapshot.
        try Self.validatePasteIsStopped()
        return summary
    }

    func importAll(into store: ClipboardHistoryStore) throws
        -> PasteClipboardImportResult {
        try Self.validatePasteIsStopped()
        try validateApplication()
        let externalRoot = try validateExternalRoot()
        let queue = try makeReadOnlyQueue()
        let snapshot = try queue.read { db -> PasteImportSnapshot in
            try Self.validateDatabase(db)
            return try readSnapshot(db, externalRoot: externalRoot)
        }

        // Every record above has already passed the production archive
        // decoder. Keep the source stopped through the final pre-commit gate
        // because external blobs do not participate in SQLite's transaction.
        try Self.validatePasteIsStopped()
        try store.importSourceApplicationIcons(snapshot.sourceApplicationIcons)
        let batch = try store.importBatch(snapshot.records)
        guard batch.sourceRecords == snapshot.summary.sourceRecords else {
            throw PasteClipboardHistoryImportError.inconsistentSource
        }
        return PasteClipboardImportResult(
            sourceRecords: batch.sourceRecords,
            inserted: batch.inserted,
            updated: batch.updated,
            unchanged: batch.unchanged,
            compressedPayloadBytes: snapshot.summary.compressedPayloadBytes,
            storedPayloadBytes: snapshot.storedPayloadBytes,
            typeCounts: snapshot.summary.typeCounts
        )
    }

    /// Small routing seam for `main.swift`: the caller remains responsible for
    /// printing only the returned counters and choosing the process exit code.
    static func runCLI(
        sourceDatabaseURL: URL = defaultSourceDatabaseURL,
        destinationRoot: URL? = nil,
        pasteApplicationURL: URL = URL(
            fileURLWithPath: "/Applications/Paste.app",
            isDirectory: true
        )
    ) throws -> PasteClipboardImportResult {
        let importer = PasteClipboardHistoryImporter(
            sourceDatabaseURL: sourceDatabaseURL,
            pasteApplicationURL: pasteApplicationURL
        )
        let store = try ClipboardHistoryStore(rootDirectory: destinationRoot)
        return try importer.importAll(into: store)
    }

    private func makeReadOnlyQueue() throws -> DatabaseQueue {
        try PasteSourceSecurity.validateRegularFile(sourceDatabaseURL)
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(5.0)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA query_only = ON")
        }
        return try DatabaseQueue(
            path: sourceDatabaseURL.path,
            configuration: configuration
        )
    }

    private func validateApplication() throws {
        guard let bundle = Bundle(url: pasteApplicationURL),
              bundle.bundleIdentifier == "com.wiheads.paste",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String == Self.supportedPasteVersion else {
            throw PasteClipboardHistoryImportError.unsupportedApplication
        }
    }

    private static func validatePasteIsStopped() throws {
        for bundleIdentifier in pasteProcessBundleIdentifiers {
            guard NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).isEmpty else {
                throw PasteClipboardHistoryImportError
                    .sourceApplicationRunning
            }
        }
    }

    private func validateExternalRoot() throws -> URL {
        let databaseDirectory = sourceDatabaseURL.deletingLastPathComponent()
        let support = databaseDirectory.appendingPathComponent(
            ".db_SUPPORT",
            isDirectory: true
        )
        let external = support.appendingPathComponent(
            "_EXTERNAL_DATA",
            isDirectory: true
        )
        try PasteSourceSecurity.validateOwnedDirectory(support)
        try PasteSourceSecurity.validateOwnedDirectory(external)
        return external
    }

    private func readSnapshot(
        _ db: Database,
        externalRoot: URL
    ) throws -> PasteImportSnapshot {
        let baseSummary = try Self.fetchSummary(db)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT i.Z_PK AS item_pk, i.ZRAWTYPE AS raw_type,
                    i.ZCREATEDAT AS created_at,
                    i.ZTIMESTAMP AS captured_at,
                    i.ZUPDATEDAT AS updated_at,
                    i.ZCHECKSUM AS checksum,
                    i.ZIDENTIFIER AS identifier,
                    i.ZTITLE AS title,
                    i.ZRAWPREVIEW AS raw_preview,
                    a.ZNAME AS application_name,
                    a.ZBUNDLEIDENTIFIER AS application_bundle_identifier,
                    d.ZRAWPASTEBOARDITEMS AS wrapped_payload
                FROM ZITEMENTITY i
                JOIN ZITEMDATAENTITY d ON d.ZITEM = i.Z_PK
                JOIN ZAPPLICATIONENTITY a
                    ON a.Z_PK = i.ZSOURCEAPPLICATION
                ORDER BY i.Z_PK ASC
                """
        )
        guard rows.count == baseSummary.sourceRecords else {
            throw PasteClipboardHistoryImportError.inconsistentSource
        }

        let sourceApplicationRows = try Row.fetchAll(
            db,
            sql: """
                SELECT ZBUNDLEIDENTIFIER AS bundle_identifier,
                    ZNAME AS application_name,
                    ZRAWICON AS icon_png
                FROM ZAPPLICATIONENTITY
                ORDER BY Z_PK ASC
                """
        )
        var sourceApplicationsByBundle:
            [String: ClipboardSourceApplicationIconRecord] = [:]
        for row in sourceApplicationRows {
            let bundleIdentifier: String? = row["bundle_identifier"]
            let pngData: Data? = row["icon_png"]
            guard let bundleIdentifier,
                  let pngData,
                  !bundleIdentifier.isEmpty,
                  !bundleIdentifier.contains("\0"),
                  !pngData.isEmpty else {
                throw PasteClipboardHistoryImportError.inconsistentSource
            }
            sourceApplicationsByBundle[bundleIdentifier] =
                ClipboardSourceApplicationIconRecord(
                    bundleIdentifier: bundleIdentifier,
                    applicationName: row["application_name"],
                    pngData: pngData
                )
        }

        var records: [ClipboardHistoryImportRecord] = []
        records.reserveCapacity(rows.count)
        var storedPayloadBytes: Int64 = 0
        var compressedPayloadBytes: Int64 = 0
        for row in rows {
            let rawType: Int = row["raw_type"]
            let identifier: String = row["identifier"]
            let checksum: String = row["checksum"]
            let capturedAt: Double = row["captured_at"]
            let createdAt: Double = row["created_at"]
            let updatedAt: Double = row["updated_at"]
            let wrappedPayload: Data = row["wrapped_payload"]
            guard Self.isPasteIdentifier(identifier),
                  Self.isPasteIdentifier(checksum),
                  checksum == identifier,
                  (0...5).contains(rawType) else {
                throw PasteClipboardHistoryImportError.inconsistentSource
            }

            let compressed = try Self.resolvePayload(
                wrappedPayload,
                externalRoot: externalRoot
            )
            compressedPayloadBytes += Int64(compressed.count)
            let archive = try Self.decodeProductionArchive(compressed)
            let nativeItems = archive.items.map {
                ClipboardNativePasteboardItem(
                    types: $0.types,
                    dataByType: $0.dataByType
                )
            }
            // The validated raw-DEFLATE stream is already RIMES's native rich
            // clipboard archive format, so preserving it byte-for-byte keeps
            // every UTI representation replayable and makes rollback exact.
            storedPayloadBytes += Int64(compressed.count)

            let rawPreview: Data? = row["raw_preview"]
            let title: String? = row["title"]
            let projection = try Self.makeProjection(
                rawType: rawType,
                title: title,
                rawPreview: rawPreview,
                items: nativeItems
            )
            records.append(ClipboardHistoryImportRecord(
                kind: Self.kind(for: rawType),
                displayText: projection.displayText,
                searchText: projection.searchText,
                canonicalText: projection.canonicalText,
                textCompleteness: projection.completeness,
                capturedAt: Date(timeIntervalSinceReferenceDate: capturedAt),
                sourceApplicationName: row["application_name"],
                sourceApplicationBundleIdentifier:
                    row["application_bundle_identifier"],
                sourceNamespace: Self.sourceNamespace,
                sourceID: identifier,
                sourceChecksum: checksum,
                pasteRawType: rawType,
                pasteIdentifier: identifier,
                pasteTitle: title,
                pasteCreatedAt: Date(timeIntervalSinceReferenceDate: createdAt),
                pasteUpdatedAt: Date(timeIntervalSinceReferenceDate: updatedAt),
                pasteRawPreview: rawPreview,
                opaquePayload: compressed
            ))
        }
        let summary = PasteClipboardSourceSummary(
            sourceRecords: baseSummary.sourceRecords,
            inlinePayloads: baseSummary.inlinePayloads,
            externalPayloads: baseSummary.externalPayloads,
            compressedPayloadBytes: compressedPayloadBytes,
            oldestTimestamp: baseSummary.oldestTimestamp,
            newestTimestamp: baseSummary.newestTimestamp,
            typeCounts: baseSummary.typeCounts
        )
        return PasteImportSnapshot(
            summary: summary,
            records: records,
            sourceApplicationIcons: sourceApplicationsByBundle.values.sorted {
                $0.bundleIdentifier < $1.bundleIdentifier
            },
            storedPayloadBytes: storedPayloadBytes
        )
    }

    private static func validateDatabase(_ db: Database) throws {
        let quickCheck = try String.fetchAll(db, sql: "PRAGMA quick_check")
        guard quickCheck == ["ok"] else {
            throw PasteClipboardHistoryImportError.inconsistentSource
        }
        let expectedColumns: [String: Set<String>] = [
            "Z_METADATA": ["Z_VERSION", "Z_UUID", "Z_PLIST"],
            "ZITEMENTITY": [
                "Z_PK", "Z_ENT", "Z_OPT", "ZDISPLAYORDERINPINBOARD",
                "ZRAWTYPE", "ZDATA", "ZDEVICE", "ZLIST",
                "ZSOURCEAPPLICATION", "ZCREATEDAT", "ZTIMESTAMP",
                "ZUPDATEDAT", "ZCHECKSUM", "ZIDENTIFIER", "ZTITLE",
                "ZRAWPREVIEW",
            ],
            "ZITEMDATAENTITY": [
                "Z_PK", "Z_ENT", "Z_OPT", "ZITEM",
                "ZRAWPASTEBOARDITEMS",
            ],
            "ZAPPLICATIONENTITY": [
                "Z_PK", "Z_ENT", "Z_OPT", "ZRAWCOLOR", "ZCREATEDAT",
                "ZUPDATEDAT", "ZBUNDLEIDENTIFIER", "ZNAME", "ZRAWICON",
            ],
        ]
        for (table, expected) in expectedColumns {
            let actual = Set(try db.columns(in: table).map(\.name))
            guard actual == expected else {
                throw PasteClipboardHistoryImportError.unsupportedSchema
            }
        }
        guard let metadata = try Row.fetchOne(
            db,
            sql: "SELECT Z_VERSION, Z_PLIST FROM Z_METADATA"
        ) else {
            throw PasteClipboardHistoryImportError.unsupportedSchema
        }
        let coreDataVersion: Int = metadata["Z_VERSION"]
        let plistData: Data = metadata["Z_PLIST"]
        let plist = try PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        )
        guard coreDataVersion == 1,
              let dictionary = plist as? [String: Any],
              (dictionary["NSStoreModelVersionHashesVersion"] as? NSNumber)?
                .intValue == 3,
              dictionary["NSStoreModelVersionChecksumKey"] as? String ==
                "ZaumikppJe6kAm9LWvuaSPKXaLP826c4WZ4vmJIZ6iU=" else {
            throw PasteClipboardHistoryImportError.unsupportedSchema
        }

        let itemCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM ZITEMENTITY"
        ) ?? 0
        let payloadCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM ZITEMDATAENTITY"
        ) ?? 0
        let joinedCount = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM ZITEMENTITY i
                JOIN ZITEMDATAENTITY d ON d.ZITEM = i.Z_PK
                JOIN ZAPPLICATIONENTITY a
                    ON a.Z_PK = i.ZSOURCEAPPLICATION
                """
        ) ?? 0
        let duplicatedPayloadLinks = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM (
                    SELECT ZITEM FROM ZITEMDATAENTITY
                    GROUP BY ZITEM HAVING COUNT(*) != 1
                )
                """
        ) ?? 0
        guard itemCount <= ClipboardHistoryStore.maximumBatchRecords,
              itemCount == payloadCount,
              itemCount == joinedCount,
              duplicatedPayloadLinks == 0 else {
            throw PasteClipboardHistoryImportError.inconsistentSource
        }
    }

    private static func fetchSummary(_ db: Database) throws
        -> PasteClipboardSourceSummary {
        let aggregate = try Row.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) AS source_records,
                    SUM(CASE WHEN substr(d.ZRAWPASTEBOARDITEMS, 1, 1) = X'01'
                        THEN 1 ELSE 0 END) AS inline_payloads,
                    SUM(CASE WHEN substr(d.ZRAWPASTEBOARDITEMS, 1, 1) = X'02'
                        THEN 1 ELSE 0 END) AS external_payloads,
                    SUM(CASE WHEN substr(d.ZRAWPASTEBOARDITEMS, 1, 1) = X'01'
                        THEN length(d.ZRAWPASTEBOARDITEMS) - 1 ELSE 0 END)
                        AS inline_bytes,
                    MIN(i.ZTIMESTAMP) AS oldest_timestamp,
                    MAX(i.ZTIMESTAMP) AS newest_timestamp
                FROM ZITEMENTITY i
                JOIN ZITEMDATAENTITY d ON d.ZITEM = i.Z_PK
                """
        )
        guard let aggregate else {
            throw PasteClipboardHistoryImportError.inconsistentSource
        }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT ZRAWTYPE AS raw_type, COUNT(*) AS item_count
                FROM ZITEMENTITY
                GROUP BY ZRAWTYPE ORDER BY ZRAWTYPE
                """
        )
        let typeCounts = try rows.map { row -> PasteClipboardTypeCount in
            let rawType: Int = row["raw_type"]
            guard (0...5).contains(rawType) else {
                throw PasteClipboardHistoryImportError.unsupportedSchema
            }
            return PasteClipboardTypeCount(
                rawType: rawType,
                kind: kind(for: rawType),
                count: row["item_count"]
            )
        }
        let oldest: Double? = aggregate["oldest_timestamp"]
        let newest: Double? = aggregate["newest_timestamp"]
        let inlineBytes: Int64 = aggregate["inline_bytes"]
        return PasteClipboardSourceSummary(
            sourceRecords: aggregate["source_records"],
            inlinePayloads: aggregate["inline_payloads"],
            externalPayloads: aggregate["external_payloads"],
            compressedPayloadBytes: inlineBytes,
            oldestTimestamp: oldest.map(Date.init(timeIntervalSinceReferenceDate:)),
            newestTimestamp: newest.map(Date.init(timeIntervalSinceReferenceDate:)),
            typeCounts: typeCounts
        )
    }

    private static func fetchSummary(
        _ db: Database,
        resolvingPayloadsUnder externalRoot: URL
    ) throws -> PasteClipboardSourceSummary {
        let base = try fetchSummary(db)
        let wrappedPayloads = try Data.fetchAll(
            db,
            sql: "SELECT ZRAWPASTEBOARDITEMS FROM ZITEMDATAENTITY"
        )
        guard wrappedPayloads.count == base.sourceRecords else {
            throw PasteClipboardHistoryImportError.inconsistentSource
        }
        var compressedBytes: Int64 = 0
        for wrapped in wrappedPayloads {
            let compressed = try resolvePayload(
                wrapped,
                externalRoot: externalRoot
            )
            _ = try decodeProductionArchive(compressed)
            compressedBytes += Int64(compressed.count)
        }
        return PasteClipboardSourceSummary(
            sourceRecords: base.sourceRecords,
            inlinePayloads: base.inlinePayloads,
            externalPayloads: base.externalPayloads,
            compressedPayloadBytes: compressedBytes,
            oldestTimestamp: base.oldestTimestamp,
            newestTimestamp: base.newestTimestamp,
            typeCounts: base.typeCounts
        )
    }

    private static func resolvePayload(
        _ wrapped: Data,
        externalRoot: URL
    ) throws -> Data {
        guard let marker = wrapped.first else {
            throw PasteClipboardHistoryImportError.unsupportedPayloadWrapper
        }
        switch marker {
        case 0x01:
            guard wrapped.count > 1 else {
                throw PasteClipboardHistoryImportError.invalidCompressedPayload
            }
            return Data(wrapped.dropFirst())
        case 0x02:
            guard wrapped.count == 38, wrapped.last == 0,
                  let token = String(
                      data: wrapped.subdata(in: 1..<37),
                      encoding: .ascii
                  ), let uuid = UUID(uuidString: token),
                  token == uuid.uuidString.uppercased() else {
                throw PasteClipboardHistoryImportError.unsafeExternalPayload
            }
            return try PasteSourceSecurity.readExternalPayload(
                root: externalRoot,
                component: token,
                maximumBytes: ClipboardPasteboardArchive.Limits.standard
                    .maximumCompressedBytes
            )
        default:
            throw PasteClipboardHistoryImportError.unsupportedPayloadWrapper
        }
    }

    private static func decodeProductionArchive(_ compressed: Data) throws
        -> ClipboardPasteboardArchive {
        do {
            return try ClipboardPasteboardArchive.decodeRawDeflate(
                compressed,
                limits: .standard
            )
        } catch {
            throw PasteClipboardHistoryImportError.invalidPayloadEnvelope
        }
    }

    private static func makeProjection(
        rawType: Int,
        title: String?,
        rawPreview: Data?,
        items: [ClipboardNativePasteboardItem]
    ) throws -> PasteProjection {
        let exact = exactCanonicalText(rawType: rawType, items: items)
        let preview = try previewProjection(
            rawType: rawType,
            rawPreview: rawPreview
        )
        let canonical = bounded(exact, maximumUTF8Bytes: 32 * 1_024 * 1_024)
        let usedExact = exact != nil && canonical != nil
        let primary = canonical ?? preview
        let display = bounded(primary, maximumUTF8Bytes: 64 * 1_024)
        let search = joinedNonempty([
            title,
            bounded(primary, maximumUTF8Bytes: 2 * 1_024 * 1_024),
        ])
        let completeness: ClipboardTextCompleteness
        if usedExact {
            completeness = .complete
        } else if preview != nil {
            completeness = .previewOnly
        } else {
            completeness = .unavailable
        }
        return PasteProjection(
            displayText: display ?? normalized(title),
            searchText: search,
            canonicalText: canonical,
            completeness: completeness
        )
    }

    private static func exactCanonicalText(
        rawType: Int,
        items: [ClipboardNativePasteboardItem]
    ) -> String? {
        var values: [String] = []
        for item in items {
            if rawType == 3, let file = exactFilePath(item) {
                values.append(file)
                continue
            }
            if let text = exactText(item) {
                values.append(text)
            }
        }
        return joinedNonempty(values)
    }

    private static func exactText(
        _ item: ClipboardNativePasteboardItem
    ) -> String? {
        let preferred = [
            "public.utf8-plain-text",
            "public.utf16-external-plain-text",
            "public.utf16-plain-text",
            "public.plain-text",
            "public.text",
            "NSStringPboardType",
            "com.apple.traditional-mac-plain-text",
            "com.trolltech.anymime.text--plain",
            "com.trolltech.anymime.text--uri-list",
        ]
        for type in preferred {
            guard let data = item.dataByType[type] else { continue }
            let encodings: [String.Encoding]
            switch type {
            case "public.utf16-external-plain-text":
                encodings = [.utf16, .utf16BigEndian, .utf16LittleEndian]
            case "public.utf16-plain-text":
                encodings = [.utf16, .utf16LittleEndian, .utf16BigEndian]
            case "com.apple.traditional-mac-plain-text":
                encodings = [.macOSRoman, .utf8]
            default:
                encodings = [.utf8, .utf16, .utf16LittleEndian]
            }
            for encoding in encodings {
                if let text = String(data: data, encoding: encoding),
                   let normalized = normalized(text) {
                    return normalized
                }
            }
        }
        return nil
    }

    private static func exactFilePath(
        _ item: ClipboardNativePasteboardItem
    ) -> String? {
        if let data = item.dataByType["public.file-url"],
           let value = String(data: data, encoding: .utf8),
           let url = URL(string: value.trimmingCharacters(
               in: .whitespacesAndNewlines.union(.init(charactersIn: "\0"))
           )), url.isFileURL {
            return normalized(url.path)
        }
        if let data = item.dataByType["NSFilenamesPboardType"],
           let value = try? PropertyListSerialization.propertyList(
               from: data,
               options: [],
               format: nil
           ), let paths = value as? [String] {
            return joinedNonempty(paths)
        }
        return exactText(item)
    }

    private static func previewProjection(
        rawType: Int,
        rawPreview: Data?
    ) throws -> String? {
        guard let rawPreview else {
            guard rawType == 0 else {
                throw PasteClipboardHistoryImportError.invalidPreview
            }
            return nil
        }
        let object = try JSONSerialization.jsonObject(with: rawPreview)
        guard let preview = object as? [String: Any] else {
            throw PasteClipboardHistoryImportError.invalidPreview
        }
        switch rawType {
        case 1:
            if let size = preview["imageSize"] as? [NSNumber], size.count == 2 {
                return "Image \(size[0]) × \(size[1])"
            }
        case 2:
            if let code = preview["colorCode"] as? NSNumber {
                return String(format: "#%06X", code.intValue & 0x00ff_ffff)
            }
        case 3:
            if let paths = preview["filePaths"] as? [String] {
                return joinedNonempty(paths)
            }
        case 4:
            return joinedNonempty([
                preview["urlName"] as? String,
                preview["url"] as? String,
            ])
        case 5:
            if let text = preview["text"] as? String {
                return normalized(text)
            }
            if let parts = preview["text"] as? [Any] {
                return joinedNonempty(parts.compactMap { $0 as? String },
                                      separator: "")
            }
            if let attributed = preview["text"] as? [String: Any],
               let runs = attributed["runs"] as? [Any] {
                return joinedNonempty(runs.compactMap { $0 as? String },
                                      separator: "")
            }
        case 0:
            return nil
        default:
            throw PasteClipboardHistoryImportError.unsupportedSchema
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.replacingOccurrences(of: "\0", with: "")
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return cleaned
    }

    private static func joinedNonempty(
        _ values: [String?],
        separator: String = "\n"
    ) -> String? {
        joinedNonempty(values.compactMap { $0 }, separator: separator)
    }

    private static func joinedNonempty(
        _ values: [String],
        separator: String = "\n"
    ) -> String? {
        let values = values.compactMap(normalized)
        return values.isEmpty ? nil : values.joined(separator: separator)
    }

    private static func bounded(
        _ value: String?,
        maximumUTF8Bytes: Int
    ) -> String? {
        guard let value = normalized(value),
              value.utf8.count <= maximumUTF8Bytes else { return nil }
        return value
    }

    private static func kind(for rawType: Int) -> ClipboardItemKind {
        switch rawType {
        case 1: return .image
        case 2: return .color
        case 3: return .files
        case 4: return .link
        case 5: return .text
        default: return .unknown
        }
    }

    private static func isPasteIdentifier(_ value: String) -> Bool {
        value.count == 32
            && value.allSatisfy { $0.isHexDigit }
    }
}

enum PasteClipboardHistoryCLI {
    /// Returns nil when the command does not belong to Clipboard History. The
    /// caller can therefore install this as an early route in `main.swift`.
    /// All emitted JSON is aggregate-only: no clipboard text, identifiers, or
    /// filesystem locations cross the CLI boundary.
    static func handleIfRequested(
        arguments: [String] = CommandLine.arguments
    ) -> Int32? {
        guard arguments.count >= 2 else { return nil }
        let command = arguments[1]
        guard command == "clipboard-import-paste"
                || command == "clipboard-audit"
                || command == "clipboard-store-audit" else {
            return nil
        }

        do {
            let options = try parseOptions(Array(arguments.dropFirst(2)))
            switch command {
            case "clipboard-import-paste":
                let importer = PasteClipboardHistoryImporter(
                    sourceDatabaseURL: options.sourceDatabaseURL
                        ?? PasteClipboardHistoryImporter
                            .defaultSourceDatabaseURL,
                    pasteApplicationURL: options.pasteApplicationURL
                        ?? URL(
                            fileURLWithPath: "/Applications/Paste.app",
                            isDirectory: true
                        )
                )
                let store = try ClipboardHistoryStore(
                    rootDirectory: options.destinationRoot
                )
                let result = try importer.importAll(into: store)
                let audit = try store.audit()
                let replay = try replayabilityAudit(store)
                let imagePreviews = try imagePreviewAudit(store)
                try emitJSON(
                    importOutput(
                        result: result,
                        audit: audit,
                        replay: replay,
                        imagePreviews: imagePreviews
                    ),
                    to: .standardOutput
                )
                return audit.isConsistent
                    && replay.invalid == 0
                    && imagePreviews.failureCount == 0 ? 0 : 2

            case "clipboard-audit", "clipboard-store-audit":
                let store = try ClipboardHistoryStore(
                    rootDirectory: options.destinationRoot
                )
                let audit = try store.audit()
                let replay = try replayabilityAudit(store)
                let imagePreviews = try imagePreviewAudit(store)
                try emitJSON(
                    auditOutput(
                        audit,
                        replay: replay,
                        imagePreviews: imagePreviews
                    ),
                    to: .standardOutput
                )
                return audit.isConsistent
                    && replay.invalid == 0
                    && imagePreviews.failureCount == 0 ? 0 : 2

            default:
                return nil
            }
        } catch PasteClipboardCLIError.invalidArguments {
            try? emitJSON(
                ["ok": false, "error": "invalid_arguments"],
                to: .standardError
            )
            return 64
        } catch {
            try? emitJSON(
                ["ok": false, "error": "operation_failed"],
                to: .standardError
            )
            return 1
        }
    }

    private struct Options {
        var sourceDatabaseURL: URL?
        var destinationRoot: URL?
        var pasteApplicationURL: URL?
    }

    private static func parseOptions(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count else {
                throw PasteClipboardCLIError.invalidArguments
            }
            let value = arguments[index + 1]
            guard !value.isEmpty else {
                throw PasteClipboardCLIError.invalidArguments
            }
            let url = URL(fileURLWithPath: value).standardizedFileURL
            switch option {
            case "--source":
                guard options.sourceDatabaseURL == nil else {
                    throw PasteClipboardCLIError.invalidArguments
                }
                options.sourceDatabaseURL = url
            case "--destination-root":
                guard options.destinationRoot == nil else {
                    throw PasteClipboardCLIError.invalidArguments
                }
                options.destinationRoot = url
            case "--paste-app":
                guard options.pasteApplicationURL == nil else {
                    throw PasteClipboardCLIError.invalidArguments
                }
                options.pasteApplicationURL = url
            default:
                throw PasteClipboardCLIError.invalidArguments
            }
            index += 2
        }
        return options
    }

    private static func importOutput(
        result: PasteClipboardImportResult,
        audit: ClipboardHistoryStoreAudit,
        replay: ReplayabilityAudit,
        imagePreviews: ImagePreviewAudit
    ) -> [String: Any] {
        [
            "ok": audit.isConsistent
                && replay.invalid == 0
                && imagePreviews.failureCount == 0,
            "operation": "clipboard-import-paste",
            "source_records": result.sourceRecords,
            "inserted": result.inserted,
            "updated": result.updated,
            "unchanged": result.unchanged,
            "idempotent": result.isIdempotent,
            "source_payload_bytes": result.compressedPayloadBytes,
            "stored_payload_bytes": result.storedPayloadBytes,
            "source_types": typeDictionary(result.typeCounts),
            "audit": auditOutput(
                audit,
                replay: replay,
                imagePreviews: imagePreviews
            ),
        ]
    }

    private static func auditOutput(
        _ audit: ClipboardHistoryStoreAudit,
        replay: ReplayabilityAudit,
        imagePreviews: ImagePreviewAudit
    ) -> [String: Any] {
        [
            "ok": audit.isConsistent
                && replay.invalid == 0
                && imagePreviews.failureCount == 0,
            "database_integrity": audit.databaseIntegrityOK,
            "total_items": audit.totalItemCount,
            "source_identities": audit.sourceIdentityCount,
            "duplicate_source_identities":
                audit.duplicateSourceIdentityCount,
            "invalid_uuids": audit.invalidUUIDCount,
            "payload_items": audit.payloadItemCount,
            "paste_items_missing_payload":
                audit.pasteItemsMissingPayloadCount,
            "invalid_payload_lengths": audit.invalidPayloadLengthCount,
            "payload_bytes": audit.totalResolvedPayloadBytes,
            "preview_bytes": audit.totalPastePreviewBytes,
            "paste_payloads": replay.pasteItems,
            "replayable_payloads": replay.replayable,
            "invalid_replay_payloads": replay.invalid,
            "image_preview_items": imagePreviews.previewItems,
            "image_record_items": imagePreviews.imageRecords,
            "image_bearing_file_items": imagePreviews.imageBearingFiles,
            "decodable_image_previews": imagePreviews.decodable,
            "missing_image_payloads": imagePreviews.missingPayload,
            "invalid_image_archives": imagePreviews.invalidArchive,
            "undecodable_image_previews": imagePreviews.undecodable,
            "types": Dictionary(uniqueKeysWithValues:
                audit.typeCounts.map { ($0.kind.rawValue, $0.count) }),
        ]
    }

    /// Payloads are fetched one at a time so an audit does not materialize the
    /// complete Paste archive in memory. This uses the same production decoder
    /// as rich clipboard activation.
    private static func replayabilityAudit(
        _ store: ClipboardHistoryStore
    ) throws -> ReplayabilityAudit {
        let pasteItems = try store.loadAllMetadata().filter {
            $0.sourceNamespace == PasteClipboardHistoryImporter.sourceNamespace
        }
        var replayable = 0
        var invalid = 0
        for item in pasteItems {
            guard let stored = try store.payload(for: item.id),
                  let payload = stored.opaquePayload else {
                invalid += 1
                continue
            }
            do {
                let archive = try ClipboardPasteboardArchive.decodeRawDeflate(
                    payload
                )
                let reconstructedCount: Int = try MainActor.assumeIsolated {
                    try archive.makePasteboardItems().count
                }
                guard reconstructedCount == archive.items.count else {
                    invalid += 1
                    continue
                }
                replayable += 1
            } catch {
                invalid += 1
            }
        }
        return ReplayabilityAudit(
            pasteItems: pasteItems.count,
            replayable: replayable,
            invalid: invalid
        )
    }

    /// Verifies the same bounded ImageIO path used by visible cards against
    /// every durable image record and every file record that carries an image
    /// representation. Output remains aggregate-only: no clipboard payload,
    /// identifier, title, or source path is emitted.
    private static func imagePreviewAudit(
        _ store: ClipboardHistoryStore
    ) throws -> ImagePreviewAudit {
        let candidates = try store.loadAllMetadata().filter {
            $0.kind.allowsImageThumbnail
        }
        let imageRecords = candidates.filter { $0.kind == .image }.count
        var previewItems = 0
        var imageBearingFiles = 0
        var decodable = 0
        var missingPayload = 0
        var invalidArchive = 0
        var undecodable = 0
        for item in candidates {
            guard let stored = try store.payload(for: item.id),
                  let payload = stored.opaquePayload else {
                if item.kind == .image {
                    previewItems += 1
                    missingPayload += 1
                }
                continue
            }
            do {
                let archive = try ClipboardPasteboardArchive.decodeRawDeflate(
                    payload
                )
                guard item.kind == .image
                        || archive.containsImageRepresentation else { continue }
                previewItems += 1
                if item.kind == .files { imageBearingFiles += 1 }
                if archive.makeImageThumbnail(maximumPixelSize: 64) != nil {
                    decodable += 1
                } else {
                    undecodable += 1
                }
            } catch {
                if item.kind == .image {
                    previewItems += 1
                    invalidArchive += 1
                }
            }
        }
        return ImagePreviewAudit(
            previewItems: previewItems,
            imageRecords: imageRecords,
            imageBearingFiles: imageBearingFiles,
            decodable: decodable,
            missingPayload: missingPayload,
            invalidArchive: invalidArchive,
            undecodable: undecodable
        )
    }

    private static func typeDictionary(
        _ counts: [PasteClipboardTypeCount]
    ) -> [String: Int] {
        Dictionary(uniqueKeysWithValues:
            counts.map { ($0.kind.rawValue, $0.count) })
    }

    private static func emitJSON(
        _ object: [String: Any],
        to handle: FileHandle
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        handle.write(data)
        handle.write(Data([0x0a]))
    }
}

private struct ReplayabilityAudit {
    let pasteItems: Int
    let replayable: Int
    let invalid: Int
}

private struct ImagePreviewAudit {
    let previewItems: Int
    let imageRecords: Int
    let imageBearingFiles: Int
    let decodable: Int
    let missingPayload: Int
    let invalidArchive: Int
    let undecodable: Int

    var failureCount: Int {
        missingPayload + invalidArchive + undecodable
    }
}

private enum PasteClipboardCLIError: Error {
    case invalidArguments
}

private struct PasteProjection {
    let displayText: String?
    let searchText: String?
    let canonicalText: String?
    let completeness: ClipboardTextCompleteness
}

private struct PasteImportSnapshot {
    let summary: PasteClipboardSourceSummary
    let records: [ClipboardHistoryImportRecord]
    let sourceApplicationIcons: [ClipboardSourceApplicationIconRecord]
    let storedPayloadBytes: Int64
}

private enum PasteSourceSecurity {
    static func validateRegularFile(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid() else {
            throw PasteClipboardHistoryImportError.unsafeSource
        }
    }

    static func validateOwnedDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else {
            throw PasteClipboardHistoryImportError.unsafeExternalPayload
        }
    }

    static func readExternalPayload(
        root: URL,
        component: String,
        maximumBytes: Int
    ) throws -> Data {
        guard !component.contains("/"), !component.contains("\\"),
              component != ".", component != ".." else {
            throw PasteClipboardHistoryImportError.unsafeExternalPayload
        }
        let url = root.appendingPathComponent(component, isDirectory: false)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw PasteClipboardHistoryImportError.missingExternalPayload
            }
            throw PasteClipboardHistoryImportError.unsafeExternalPayload
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_size > 0,
              info.st_size <= off_t(maximumBytes) else {
            try? handle.close()
            throw PasteClipboardHistoryImportError.unsafeExternalPayload
        }
        guard let data = try handle.readToEnd(),
              !data.isEmpty, data.count <= maximumBytes,
              data.count == Int(info.st_size) else {
            throw PasteClipboardHistoryImportError.unsafeExternalPayload
        }
        return data
    }
}
