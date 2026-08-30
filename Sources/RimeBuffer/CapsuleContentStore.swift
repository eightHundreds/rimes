import Darwin
import CryptoKit
import Foundation

enum CapsuleEntryKind: String, Codable, CaseIterable {
    case prompt
    case memory
    case password
    case skill

    var displayName: String {
        switch self {
        case .prompt: return "Prompt"
        case .memory: return "Memory"
        case .password: return "Password"
        case .skill: return "Skill"
        }
    }
}

struct CapsuleContentWriteRequest: Codable, Equatable {
    let id: UUID?
    let type: CapsuleEntryKind
    let title: String
    let content: String

    init(id: UUID? = nil,
         type: CapsuleEntryKind,
         title: String,
         content: String) {
        self.id = id
        self.type = type
        self.title = title
        self.content = content
    }
}

struct CapsuleContentSummary: Equatable, Identifiable {
    let id: UUID
    let type: CapsuleEntryKind
    let title: String
    let updatedAt: Date
    let fileURL: URL
}

struct CapsuleContentRecord: Equatable {
    let summary: CapsuleContentSummary
    let content: String

    var snippet: String {
        let flattened = content
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard flattened.count > 72 else { return flattened }
        return String(flattened.prefix(72)) + "…"
    }
}

enum CapsuleContentStoreError: LocalizedError, Equatable {
    case unsafeStorage(String)
    case invalidRequest(String)
    case malformedDocument(String)
    case recordNotFound
    case revisionConflict
    case fileOperation(String)

    var errorDescription: String? {
        switch self {
        case let .unsafeStorage(path):
            return "Capsule 本地目录不安全：\(path)"
        case let .invalidRequest(message):
            return "Capsule 条目无效：\(message)"
        case let .malformedDocument(path):
            return "Capsule Markdown 格式无效：\(path)"
        case .recordNotFound:
            return "未找到 Capsule 条目"
        case .revisionConflict:
            return "Capsule 条目已被其他窗口更新"
        case let .fileOperation(message):
            return "Capsule 本地文件操作失败：\(message)"
        }
    }
}

/// Obsidian-readable local store for non-secret Capsule units. Passwords keep
/// their authenticated encrypted format in `passwords/`; Prompt, Memory and
/// Skill path units live here as ordinary Markdown so Obsidian can read, edit
/// and graph them without a product-specific database.
final class CapsuleContentStore {
    static let shared = CapsuleContentStore()

    static let maximumDocumentBytes = 1 * 1_024 * 1_024
    static let maximumRecordCount = 20_000
    static let maximumTitleCharacters = 256
    static let maximumContentCharacters = 256 * 1_024
    static let defaultEntryID = UUID(
        uuidString: "72696d65-7300-4000-8000-000000000001"
    )!
    static let defaultEntryTitle = "RIMES 默认词条"
    static let defaultEntryContent = "RIMES"

    let rootURL: URL
    let entryDirectoryURL: URL
    let seedMarkerURL: URL

    private let fileManager: FileManager
    private let now: () -> Date

    init(rootURL: URL = CapsulePasswordStore.defaultRootURL(),
         fileManager: FileManager = .default,
         now: @escaping () -> Date = Date.init) {
        self.rootURL = rootURL.standardizedFileURL
        entryDirectoryURL = self.rootURL.appendingPathComponent(
            "entries",
            isDirectory: true
        )
        seedMarkerURL = self.rootURL.appendingPathComponent("content-seed-v1")
        self.fileManager = fileManager
        self.now = now
    }

    /// Seeds once per local Capsule library. The marker deliberately survives
    /// deletion of the preset so an intentional user removal remains final.
    @discardableResult
    func seedDefaultsIfNeeded() throws -> Bool {
        try withStoreLock {
            try prepareDirectoriesWithoutLock()
            if fileManager.fileExists(atPath: seedMarkerURL.path) {
                try requireSafeRegularFile(seedMarkerURL, maximumBytes: 64)
                return false
            }
            let existing = try recordsWithoutLock()
            var inserted = false
            if !existing.contains(where: {
                $0.summary.id == Self.defaultEntryID
                    || $0.summary.title == Self.defaultEntryTitle
            }) {
                _ = try writeRecordWithoutLock(
                    CapsuleContentWriteRequest(
                        id: Self.defaultEntryID,
                        type: .memory,
                        title: Self.defaultEntryTitle,
                        content: Self.defaultEntryContent
                    ),
                    requiresExistingID: false
                )
                inserted = true
            }
            try writePrivateFileWithoutLock(
                Data("seeded\n".utf8),
                to: seedMarkerURL
            )
            return inserted
        }
    }

    func listRecords() throws -> [CapsuleContentRecord] {
        try withStoreLock {
            try prepareDirectoriesWithoutLock()
            try seedDefaultsWithoutLockIfNeeded()
            return try recordsWithoutLock()
        }
    }

    func search(_ query: String,
                kind: CapsuleEntryKind? = nil,
                limit: Int = 5) throws
        -> [CapsuleContentRecord] {
        let terms = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return [] }
        return try listRecords().lazy.filter { record in
            guard kind == nil || record.summary.type == kind else {
                return false
            }
            let searchable = (record.summary.title + "\n" + record.content)
                .lowercased()
            return terms.allSatisfy(searchable.contains)
        }
        .prefix(min(max(limit, 1), 20))
        .map { $0 }
    }

    @discardableResult
    func put(_ request: CapsuleContentWriteRequest,
             expectedRevision: String? = nil) throws
        -> CapsuleContentSummary {
        let normalized = try Self.validate(request)
        return try withStoreLock {
            try prepareDirectoriesWithoutLock()
            try seedDefaultsWithoutLockIfNeeded()
            return try writeRecordWithoutLock(
                normalized,
                requiresExistingID: normalized.id != nil,
                expectedRevision: expectedRevision
            )
        }
    }

    func record(id: UUID) throws -> CapsuleContentRecord {
        try withStoreLock {
            try prepareDirectoriesWithoutLock()
            try seedDefaultsWithoutLockIfNeeded()
            let url = entryURL(id: id)
            guard fileManager.fileExists(atPath: url.path) else {
                throw CapsuleContentStoreError.recordNotFound
            }
            let record = try parseDocumentWithoutLock(url)
            guard record.summary.id == id else {
                throw CapsuleContentStoreError.malformedDocument(url.path)
            }
            return record
        }
    }

    func remove(id: UUID, expectedRevision: String? = nil) throws {
        try withStoreLock {
            let url = entryURL(id: id)
            guard fileManager.fileExists(atPath: url.path) else {
                throw CapsuleContentStoreError.recordNotFound
            }
            try requireSafeRegularFile(
                url,
                maximumBytes: Self.maximumDocumentBytes
            )
            if let expectedRevision {
                guard try fileRevisionWithoutLock(url) == expectedRevision else {
                    throw CapsuleContentStoreError.revisionConflict
                }
            }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw CapsuleContentStoreError.fileOperation(
                    error.localizedDescription
                )
            }
        }
    }

    private func fileRevisionWithoutLock(_ url: URL) throws -> String {
        try requireSafeRegularFile(
            url,
            maximumBytes: Self.maximumDocumentBytes
        )
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw CapsuleContentStoreError.fileOperation(
                error.localizedDescription
            )
        }
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func seedDefaultsWithoutLockIfNeeded() throws {
        guard !fileManager.fileExists(atPath: seedMarkerURL.path) else {
            try requireSafeRegularFile(seedMarkerURL, maximumBytes: 64)
            return
        }
        let existing = try recordsWithoutLock()
        if !existing.contains(where: {
            $0.summary.id == Self.defaultEntryID
                || $0.summary.title == Self.defaultEntryTitle
        }) {
            _ = try writeRecordWithoutLock(
                CapsuleContentWriteRequest(
                    id: Self.defaultEntryID,
                    type: .memory,
                    title: Self.defaultEntryTitle,
                    content: Self.defaultEntryContent
                ),
                requiresExistingID: false
            )
        }
        try writePrivateFileWithoutLock(Data("seeded\n".utf8), to: seedMarkerURL)
    }

    private func writeRecordWithoutLock(
        _ request: CapsuleContentWriteRequest,
        requiresExistingID: Bool,
        expectedRevision: String? = nil
    ) throws -> CapsuleContentSummary {
        let normalized = try Self.validate(request)
        let id = normalized.id ?? UUID()
        if requiresExistingID {
            let destination = entryURL(id: id)
            guard fileManager.fileExists(atPath: destination.path) else {
                throw CapsuleContentStoreError.recordNotFound
            }
            try requireSafeRegularFile(
                destination,
                maximumBytes: Self.maximumDocumentBytes
            )
        } else {
            let existing = try recordsWithoutLock()
            if !existing.contains(where: { $0.summary.id == id }),
               existing.count >= Self.maximumRecordCount {
                throw CapsuleContentStoreError.invalidRequest("记录数量超过上限")
            }
        }
        let updatedAt = now()
        let document = Self.markdownDocument(
            id: id,
            type: normalized.type,
            title: normalized.title,
            updatedAt: updatedAt,
            content: normalized.content
        )
        let data = Data(document.utf8)
        guard data.count <= Self.maximumDocumentBytes else {
            throw CapsuleContentStoreError.invalidRequest("Markdown 超过大小上限")
        }
        let destination = entryURL(id: id)
        if let expectedRevision {
            guard try fileRevisionWithoutLock(destination)
                    == expectedRevision else {
                throw CapsuleContentStoreError.revisionConflict
            }
        }
        try writePrivateFileWithoutLock(data, to: destination)
        return CapsuleContentSummary(
            id: id,
            type: normalized.type,
            title: normalized.title,
            updatedAt: updatedAt,
            fileURL: destination
        )
    }

    private func recordsWithoutLock() throws -> [CapsuleContentRecord] {
        guard fileManager.fileExists(atPath: entryDirectoryURL.path) else {
            return []
        }
        try requireSafeDirectory(entryDirectoryURL)
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: entryDirectoryURL,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw CapsuleContentStoreError.fileOperation(
                error.localizedDescription
            )
        }
        guard urls.count <= Self.maximumRecordCount else {
            throw CapsuleContentStoreError.unsafeStorage(entryDirectoryURL.path)
        }
        return try urls.compactMap { url in
            guard url.pathExtension.lowercased() == "md" else { return nil }
            let record = try parseDocumentWithoutLock(url)
            guard url.deletingPathExtension().lastPathComponent
                    == record.summary.id.uuidString.lowercased() else {
                throw CapsuleContentStoreError.malformedDocument(url.path)
            }
            return record
        }
        .sorted {
            let order = $0.summary.title.localizedStandardCompare(
                $1.summary.title
            )
            if order == .orderedSame {
                return $0.summary.id.uuidString < $1.summary.id.uuidString
            }
            return order == .orderedAscending
        }
    }

    private func parseDocumentWithoutLock(_ url: URL) throws
        -> CapsuleContentRecord {
        guard url.deletingLastPathComponent().standardizedFileURL
                == entryDirectoryURL.standardizedFileURL else {
            throw CapsuleContentStoreError.unsafeStorage(url.path)
        }
        try requireSafeRegularFile(
            url,
            maximumBytes: Self.maximumDocumentBytes
        )
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw CapsuleContentStoreError.fileOperation(
                error.localizedDescription
            )
        }
        guard let text = String(data: data, encoding: .utf8),
              !text.contains("\0") else {
            throw CapsuleContentStoreError.malformedDocument(url.path)
        }
        let lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard lines.count >= 8,
              lines[0] == "---",
              let end = lines.dropFirst().firstIndex(of: "---") else {
            throw CapsuleContentStoreError.malformedDocument(url.path)
        }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else {
                throw CapsuleContentStoreError.malformedDocument(url.path)
            }
            let key = String(line[..<colon])
                .trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, fields[key] == nil else {
                throw CapsuleContentStoreError.malformedDocument(url.path)
            }
            fields[key] = value
        }
        guard fields["version"] == "1",
              let kindRaw = fields["capsule"],
              let kind = CapsuleEntryKind(rawValue: kindRaw),
              kind != .password,
              let idRaw = fields["id"],
              let id = UUID(uuidString: try Self.decodeJSONScalar(idRaw)),
              let titleRaw = fields["title"],
              let title = try? Self.decodeJSONScalar(titleRaw),
              !title.isEmpty,
              title.count <= Self.maximumTitleCharacters,
              let updatedRaw = fields["updated_at"],
              let updatedString = try? Self.decodeJSONScalar(updatedRaw),
              let updatedAt = Self.iso8601.date(from: updatedString) else {
            throw CapsuleContentStoreError.malformedDocument(url.path)
        }
        var bodyStart = end + 1
        if lines.indices.contains(bodyStart), lines[bodyStart].isEmpty {
            bodyStart += 1
        }
        let content = bodyStart < lines.count
            ? lines[bodyStart...].joined(separator: "\n")
            : ""
        let normalized = try Self.validate(
            CapsuleContentWriteRequest(
                id: id,
                type: kind,
                title: title,
                content: content
            )
        )
        return CapsuleContentRecord(
            summary: CapsuleContentSummary(
                id: id,
                type: kind,
                title: normalized.title,
                updatedAt: updatedAt,
                fileURL: url
            ),
            content: normalized.content
        )
    }

    private func entryURL(id: UUID) -> URL {
        entryDirectoryURL.appendingPathComponent(
            "\(id.uuidString.lowercased()).md"
        )
    }

    private func prepareDirectoriesWithoutLock() throws {
        try preparePrivateDirectory(rootURL)
        try preparePrivateDirectory(entryDirectoryURL)
    }

    private func preparePrivateDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try requireSafeDirectory(url)
        } else {
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw CapsuleContentStoreError.fileOperation(
                    error.localizedDescription
                )
            }
        }
        guard chmod(url.path, 0o700) == 0 else {
            throw CapsuleContentStoreError.fileOperation("无法收紧目录权限")
        }
    }

    private func requireSafeDirectory(_ url: URL) throws {
        let values = try safeValues(for: url)
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw CapsuleContentStoreError.unsafeStorage(url.path)
        }
    }

    private func requireSafeRegularFile(_ url: URL,
                                        maximumBytes: Int) throws {
        let values = try safeValues(for: url)
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              size <= maximumBytes else {
            throw CapsuleContentStoreError.unsafeStorage(url.path)
        }
    }

    private func safeValues(for url: URL) throws -> URLResourceValues {
        do {
            return try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
        } catch {
            throw CapsuleContentStoreError.fileOperation(
                error.localizedDescription
            )
        }
    }

    private func writePrivateFileWithoutLock(_ data: Data, to url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL
                == rootURL.standardizedFileURL
                || url.deletingLastPathComponent().standardizedFileURL
                    == entryDirectoryURL.standardizedFileURL else {
            throw CapsuleContentStoreError.unsafeStorage(url.path)
        }
        let directory = url.deletingLastPathComponent()
        try preparePrivateDirectory(directory)
        let staged = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: staged, options: [.atomic])
            guard chmod(staged.path, 0o600) == 0 else {
                throw CapsuleContentStoreError.fileOperation("无法收紧文件权限")
            }
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(
                    url,
                    withItemAt: staged,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: staged, to: url)
            }
            guard chmod(url.path, 0o600) == 0 else {
                throw CapsuleContentStoreError.fileOperation("无法收紧文件权限")
            }
        } catch let error as CapsuleContentStoreError {
            try? fileManager.removeItem(at: staged)
            throw error
        } catch {
            try? fileManager.removeItem(at: staged)
            throw CapsuleContentStoreError.fileOperation(
                error.localizedDescription
            )
        }
    }

    private func withStoreLock<T>(_ body: () throws -> T) throws -> T {
        try preparePrivateDirectory(rootURL)
        let lockURL = rootURL.appendingPathComponent(".lock")
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw CapsuleContentStoreError.fileOperation("无法打开存储锁")
        }
        defer { close(descriptor) }
        _ = fchmod(descriptor, mode_t(0o600))
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw CapsuleContentStoreError.fileOperation("无法取得存储锁")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func validate(_ request: CapsuleContentWriteRequest) throws
        -> CapsuleContentWriteRequest {
        let title = request.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard request.type != .password else {
            throw CapsuleContentStoreError.invalidRequest("Password 必须使用加密存储")
        }
        guard !title.isEmpty,
              title.count <= maximumTitleCharacters,
              !title.contains("\0") else {
            throw CapsuleContentStoreError.invalidRequest("标题为空或过长")
        }
        guard !request.content.isEmpty,
              request.content.count <= maximumContentCharacters,
              !request.content.contains("\0") else {
            throw CapsuleContentStoreError.invalidRequest("内容为空或过长")
        }
        if request.type == .skill,
           !NSString(string: request.content).isAbsolutePath {
            throw CapsuleContentStoreError.invalidRequest("Skill 必须是绝对路径")
        }
        return CapsuleContentWriteRequest(
            id: request.id,
            type: request.type,
            title: title,
            content: request.content
        )
    }

    private static func markdownDocument(id: UUID,
                                         type: CapsuleEntryKind,
                                         title: String,
                                         updatedAt: Date,
                                         content: String) -> String {
        """
        ---
        capsule: \(type.rawValue)
        version: 1
        id: \(encodeJSONScalar(id.uuidString.lowercased()))
        title: \(encodeJSONScalar(title))
        updated_at: \(encodeJSONScalar(iso8601.string(from: updatedAt)))
        ---

        \(content)
        """
    }

    private static func encodeJSONScalar(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private static func decodeJSONScalar(_ value: String) throws -> String {
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else {
            throw CapsuleContentStoreError.malformedDocument("front matter")
        }
        return decoded
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
