import Foundation

enum CapsulePasswordCLI {
    private struct PasswordPublicSummary: Encodable {
        let id: String
        let title: String
        let updatedAt: String
    }

    private struct ContentPublicSummary: Encodable {
        let id: String
        let type: String
        let title: String
        let updatedAt: String
    }

    static func handleIfRequested(arguments: [String]) -> Int32? {
        guard let capsuleIndex = arguments.firstIndex(of: "capsule") else {
            return nil
        }
        let tail = Array(arguments.dropFirst(capsuleIndex + 1))
        guard let namespace = tail.first, tail.count >= 2 else {
            writeUsage()
            return 64
        }
        do {
            switch namespace {
            case "password":
                return try handlePassword(Array(tail.dropFirst()))
            case "entry":
                return try handleContent(Array(tail.dropFirst()))
            default:
                writeUsage()
                return 64
            }
        } catch {
            writeError(error.localizedDescription)
            return 1
        }
    }

    private static func handlePassword(_ tail: [String]) throws -> Int32 {
        let store = CapsulePasswordStore.shared
        guard let command = tail.first else { return 64 }
        switch command {
            case "put":
                guard tail.count == 1 else {
                    writeError("password put reads one JSON record from stdin; no password argv is accepted")
                    return 64
                }
                let data = try readBoundedStandardInput(
                    maximum: CapsulePasswordStore.maximumImportBytes
                )
                guard !data.isEmpty,
                      data.count <= CapsulePasswordStore.maximumImportBytes else {
                    writeError("password JSON stdin is empty or too large")
                    return 65
                }
                let request = try JSONDecoder().decode(
                    CapsulePasswordWriteRequest.self,
                    from: data
                )
                let saved = try store.put(request)
                writeJSON(PasswordPublicSummary(
                    id: saved.id.uuidString.lowercased(),
                    title: saved.title,
                    updatedAt: iso8601.string(from: saved.updatedAt)
                ))
                return 0
            case "list":
                guard tail.count == 1 else { return 64 }
                let summaries = try store.listSummaries().map {
                    PasswordPublicSummary(
                        id: $0.id.uuidString.lowercased(),
                        title: $0.title,
                        updatedAt: iso8601.string(from: $0.updatedAt)
                    )
                }
                writeJSON(summaries)
                return 0
            case "remove":
                guard tail.count == 2,
                      let id = UUID(uuidString: tail[1]) else {
                    writeError("usage: RimeBuffer capsule password remove <uuid>")
                    return 64
                }
                try store.remove(id: id)
                writeStandardOutput("removed \(id.uuidString.lowercased())\n")
                return 0
            case "path":
                guard tail.count == 1 else { return 64 }
                writeStandardOutput(store.passwordDirectoryURL.path + "\n")
                return 0
            default:
                writeError("unknown capsule password command")
                return 64
            }
    }

    private static func handleContent(_ tail: [String]) throws -> Int32 {
        let store = CapsuleContentStore.shared
        guard let command = tail.first else { return 64 }
        switch command {
        case "put":
            guard tail.count == 1 else {
                writeError("entry put reads one JSON record from stdin")
                return 64
            }
            let data = try readBoundedStandardInput(
                maximum: CapsuleContentStore.maximumDocumentBytes
            )
            guard !data.isEmpty,
                  data.count <= CapsuleContentStore.maximumDocumentBytes else {
                writeError("entry JSON stdin is empty or too large")
                return 65
            }
            let request = try JSONDecoder().decode(
                CapsuleContentWriteRequest.self,
                from: data
            )
            let saved = try store.put(request)
            writeJSON(contentSummary(saved))
            return 0
        case "list":
            guard tail.count == 1 else { return 64 }
            writeJSON(try store.listRecords().map {
                contentSummary($0.summary)
            })
            return 0
        case "remove":
            guard tail.count == 2,
                  let id = UUID(uuidString: tail[1]) else {
                writeError("usage: RimeBuffer capsule entry remove <uuid>")
                return 64
            }
            try store.remove(id: id)
            writeStandardOutput("removed \(id.uuidString.lowercased())\n")
            return 0
        case "path":
            guard tail.count == 1 else { return 64 }
            writeStandardOutput(store.entryDirectoryURL.path + "\n")
            return 0
        case "seed":
            guard tail.count == 1 else { return 64 }
            let inserted = try store.seedDefaultsIfNeeded()
            writeStandardOutput(inserted ? "seeded\n" : "ready\n")
            return 0
        default:
            writeError("unknown capsule entry command")
            return 64
        }
    }

    private static func contentSummary(
        _ value: CapsuleContentSummary
    ) -> ContentPublicSummary {
        ContentPublicSummary(
            id: value.id.uuidString.lowercased(),
            type: value.type.rawValue,
            title: value.title,
            updatedAt: iso8601.string(from: value.updatedAt)
        )
    }

    private static func writeJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func readBoundedStandardInput(maximum: Int) throws -> Data {
        var collected = Data()
        while collected.count <= maximum {
            let remaining = maximum + 1 - collected.count
            guard remaining > 0,
                  let chunk = try FileHandle.standardInput.read(
                    upToCount: min(remaining, 64 * 1_024)
                  ),
                  !chunk.isEmpty else {
                break
            }
            collected.append(chunk)
        }
        return collected
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func writeStandardOutput(_ value: String) {
        FileHandle.standardOutput.write(Data(value.utf8))
    }

    private static func writeUsage() {
        writeError(
            "usage: RimeBuffer capsule password|entry put|list|remove|path|seed"
        )
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
