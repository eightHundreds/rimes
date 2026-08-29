import Foundation

private final class AITextMailboxSmokeCancellation: AITextCancellable {
    private(set) var wasCancelled = false
    func cancel() { wasCancelled = true }
}

private final class AITextMailboxSmokeProvider: AITextProvider {
    let kind: AITextProviderKind
    var availability: AITextProviderAvailability = .ready
    private(set) var requests: [AITextProviderRequest] = []
    private(set) var cancellations: [AITextMailboxSmokeCancellation] = []
    private var events: [(AITextProviderEvent) -> Void] = []
    private var completions: [
        (Result<[AITextProviderBlock], AITextProviderError>) -> Void
    ] = []

    init(kind: AITextProviderKind = .codexCLI) {
        self.kind = kind
    }

    @discardableResult
    func generate(
        _ request: AITextProviderRequest,
        onEvent: @escaping (AITextProviderEvent) -> Void,
        completion: @escaping (
            Result<[AITextProviderBlock], AITextProviderError>
        ) -> Void
    ) -> any AITextCancellable {
        requests.append(request)
        events.append(onEvent)
        completions.append(completion)
        let cancellation = AITextMailboxSmokeCancellation()
        cancellations.append(cancellation)
        return cancellation
    }

    func emit(_ event: AITextProviderEvent, request index: Int) {
        events[index](event)
    }

    func finish(
        _ result: Result<[AITextProviderBlock], AITextProviderError>,
        request index: Int
    ) {
        completions[index](result)
    }
}

private final class AITextMailboxSmokeStore: AITextMailboxPersisting {
    private(set) var threads: [MailboxThread] = []
    private(set) var previewResponses: [UUID: String] = [:]
    private(set) var previewFormats: [UUID: AITextContentFormat] = [:]
    private(set) var completedResponses: [UUID: String] = [:]
    private(set) var completedFormats: [UUID: AITextContentFormat] = [:]
    private(set) var completionCounts: [UUID: Int] = [:]
    private(set) var failedMessages: [UUID: String] = [:]
    private(set) var localNoteCount = 0
    private var nextSequence = 1

    var snapshot: MailboxStoreSnapshot {
        MailboxStoreSnapshot(
            revision: UInt64(threads.count + completedResponses.count
                + failedMessages.count + localNoteCount),
            threads: threads,
            selectedThreadID: nil,
            persistence: .available
        )
    }

    func thread(id: UUID) -> MailboxThread? {
        threads.first(where: { $0.id == id })
    }

    func beginAIConversation(
        source: MailboxSource,
        title: String?,
        prompt: String,
        author: String,
        format: AITextContentFormat
    ) throws -> MailboxGenerationHandle {
        let handle = nextHandle()
        let now = Date()
        threads.append(MailboxThread(
            id: handle.threadID,
            sequence: handle.sequence,
            title: title,
            source: source,
            messages: [MailboxMessage(role: .user,
                                      author: author,
                                      body: prompt,
                                      createdAt: now)],
            generation: .generating(
                id: handle.generationID,
                format: format,
                at: now
            ),
            unread: false,
            createdAt: now,
            updatedAt: now
        ))
        return handle
    }

    func beginAIReply(
        threadID: UUID,
        body: String,
        author: String,
        format: AITextContentFormat
    ) throws -> MailboxGenerationHandle {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else {
            throw MailboxStoreError.missingThread
        }
        let generation = MailboxGeneration.generating(format: format)
        threads[index].messages.append(MailboxMessage(role: .user,
                                                      author: author,
                                                      body: body))
        threads[index].generation = generation
        threads[index].unread = false
        return MailboxGenerationHandle(
            threadID: threadID,
            generationID: generation.id,
            sequence: threads[index].sequence
        )
    }

    func updateGenerationPreview(
        _ handle: MailboxGenerationHandle,
        response: String,
        author: String?,
        format: AITextContentFormat
    ) throws -> UUID {
        guard currentIndex(handle) != nil else {
            throw MailboxStoreError.staleGeneration
        }
        previewResponses[handle.generationID] = response
        previewFormats[handle.generationID] = format
        return UUID()
    }

    func completeGeneration(
        _ handle: MailboxGenerationHandle,
        response: String,
        author: String?,
        format: AITextContentFormat
    ) throws -> UUID {
        guard let index = currentIndex(handle) else {
            throw MailboxStoreError.staleGeneration
        }
        let message = MailboxMessage(role: .inbound,
                                     format: format,
                                     author: author,
                                     body: response)
        threads[index].messages.append(message)
        threads[index].generation = threads[index].generation?.succeeding(at: Date())
        threads[index].unread = true
        previewResponses.removeValue(forKey: handle.generationID)
        previewFormats.removeValue(forKey: handle.generationID)
        completedResponses[handle.generationID] = response
        completedFormats[handle.generationID] = format
        completionCounts[handle.generationID, default: 0] += 1
        return message.id
    }

    func failGeneration(
        _ handle: MailboxGenerationHandle,
        message: String
    ) throws {
        guard let index = currentIndex(handle) else {
            throw MailboxStoreError.staleGeneration
        }
        threads[index].generation = threads[index].generation?.failing(
            message: message,
            at: Date()
        )
        threads[index].unread = true
        previewResponses.removeValue(forKey: handle.generationID)
        previewFormats.removeValue(forKey: handle.generationID)
        failedMessages[handle.generationID] = message
    }

    func addLocalNote(
        threadID: UUID,
        body: String,
        author: String
    ) throws -> UUID {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else {
            throw MailboxStoreError.missingThread
        }
        let message = MailboxMessage(role: .user,
                                     kind: .localNote,
                                     author: author,
                                     body: body)
        threads[index].messages.append(message)
        localNoteCount += 1
        return message.id
    }

    func addLocalThread() -> UUID {
        let id = UUID()
        let now = Date()
        threads.append(MailboxThread(
            id: id,
            sequence: nextSequence,
            title: "HTTP",
            source: .http(source: "HTTP Push"),
            messages: [MailboxMessage(role: .inbound,
                                      author: "HTTP Push",
                                      body: "draft")],
            generation: nil,
            unread: true,
            createdAt: now,
            updatedAt: now
        ))
        nextSequence += 1
        return id
    }

    private func nextHandle() -> MailboxGenerationHandle {
        let handle = MailboxGenerationHandle(
            threadID: UUID(),
            generationID: UUID(),
            sequence: nextSequence
        )
        nextSequence += 1
        return handle
    }

    private func currentIndex(_ handle: MailboxGenerationHandle) -> Int? {
        threads.firstIndex {
            $0.id == handle.threadID
                && $0.generation?.id == handle.generationID
                && $0.generation?.phase == .generating
        }
    }
}

private enum AITextMailboxGenerationSmoke {
    static func run() -> Bool {
        Thread.isMainThread
            && promptPlanning()
            && preferencesRoundTrip()
            && inlineSelectionSnapshotAndRouting()
            && mailboxJSONValidation()
            && mailboxCapacityAdmission()
            && backgroundTerminalLifecycle()
    }

    private static func promptPlanning() -> Bool {
        do {
            let initial = try AITextRequestPlanner.initialPrompt(
                sourceText: "payload-原文",
                mode: .polish,
                output: .markdown
            )
            guard initial.contains(
                "Rewrite the source clearly while preserving its meaning"
            ), initial.contains(
                "Put the complete valid Markdown document"
            ), initial.contains("USER_PAYLOAD_JSON:"),
              initial.contains("\"source\":\"payload-原文\""),
              !initial.contains("(instruction)"),
              !initial.contains("(formatInstruction)"),
              !initial.contains("(encoded)") else {
                return false
            }

            let continuation = try AITextRequestPlanner.continuationPrompt(
                turns: [
                    AITextConversationPromptTurn(
                        role: .assistant,
                        content: "prior-answer"
                    ),
                    AITextConversationPromptTurn(
                        role: .user,
                        content: "follow-up"
                    ),
                ]
            )
            return continuation.contains("CONVERSATION_JSON:")
                && continuation.contains("\"content\":\"prior-answer\"")
                && continuation.contains("\"content\":\"follow-up\"")
                && !continuation.contains("(encoded)")
        } catch {
            return false
        }
    }

    private static func preferencesRoundTrip() -> Bool {
        let suite = "RimeBuffer.AITextMailboxPreferencesSmoke.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AITextGenerationPreferenceStore(defaults: defaults)
        guard store.mode == .ask,
              store.output == .plain,
              store.destination == .inline,
              store.format == .plain,
              store.modelID(for: .openAICompatible) == nil else {
            return false
        }
        store.mode = .summarize
        store.output = .mailbox
        store.set(destination: .mailbox, format: .markdown)
        do {
            try store.setModelID("  model-frozen  ", for: .openAICompatible)
        } catch {
            return false
        }
        let selection = store.selection(connectorKind: .openAICompatible)
        guard selection == AITextGenerationSelection(
            connectorKind: .openAICompatible,
            modelID: "model-frozen",
            mode: .summarize,
            destination: .mailbox,
            format: .markdown
        ) else {
            return false
        }

        let legacySuite = "RimeBuffer.AITextMailboxLegacyPreferencesSmoke.\(UUID().uuidString)"
        guard let legacyDefaults = UserDefaults(suiteName: legacySuite) else {
            return false
        }
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
        legacyDefaults.set(
            AITextGenerationOutput.mailbox.rawValue,
            forKey: "plugins.ai-text.generation.output.v1"
        )
        let migrated = AITextGenerationPreferenceStore(defaults: legacyDefaults)
        return migrated.destination == .mailbox
            && migrated.format == .plain
    }

    private static func inlineSelectionSnapshotAndRouting() -> Bool {
        let source = BufferModel()
        source.stageExternal("inline-source", origin: .rime)
        let provider = AITextMailboxSmokeProvider(kind: .codexCLI)
        var selection = AITextGenerationSelection(
            connectorKind: .codexCLI,
            modelID: "inline-model",
            mode: .summarize,
            output: .json
        )
        let workspace = AITextPluginWorkspace(
            provider: provider,
            sourceModel: source,
            generationSelectionResolver: { _ in selection },
            isSelected: { true }
        )
        workspace.start()
        defer { workspace.stop() }

        guard workspace.generate(), provider.requests.count == 1,
              provider.requests[0].modelID == "inline-model",
              provider.requests[0].preparedPrompt?.contains(
                "Summarize the source faithfully and concisely."
              ) == true,
              provider.requests[0].preparedPrompt?.contains(
                "Put one complete valid JSON value"
              ) == true,
              provider.requests[0].preparedPrompt?.contains(
                "\"source\":\"inline-source\""
              ) == true else {
            return false
        }
        let frozenPrompt = provider.requests[0].preparedPrompt
        selection = AITextGenerationSelection(
            connectorKind: .codexCLI,
            modelID: nil,
            mode: .translate,
            output: .plain
        )
        guard provider.requests[0].modelID == "inline-model",
              provider.requests[0].preparedPrompt == frozenPrompt else {
            return false
        }
        provider.emit(.blockSnapshot(AITextProviderBlock(
            index: 0,
            text: "{\"answer\":",
            title: nil
        )), request: 0)
        guard workspace.outputBlocks.isEmpty else { return false }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "{\"answer\":", title: nil),
            AITextProviderBlock(index: 1, text: "\"inline-result\"}", title: nil),
        ]), request: 0)
        guard workspace.phase == .ready,
              workspace.outputBlocks.count == 1,
              workspace.outputBlocks[0].text
                == "{\"answer\":\n\n\"inline-result\"}" else {
            return false
        }
        workspace.reset()

        selection = AITextGenerationSelection(
            connectorKind: .codexCLI,
            modelID: nil,
            mode: .ask,
            output: .json
        )
        guard workspace.generate(), provider.requests.count == 2 else {
            return false
        }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "not-json", title: nil),
        ]), request: 1)
        guard workspace.phase == .failed(
            AITextProviderError.invalidResult.userFacingMessage
        ), workspace.outputBlocks.isEmpty else {
            return false
        }
        workspace.reset()

        selection = AITextGenerationSelection(
            connectorKind: .codexCLI,
            modelID: nil,
            mode: .ask,
            output: .markdown
        )
        guard workspace.generate(), provider.requests.count == 3 else {
            return false
        }
        provider.emit(.blockSnapshot(AITextProviderBlock(
            index: 0,
            text: "# Title",
            title: nil
        )), request: 2)
        guard workspace.outputBlocks.isEmpty else { return false }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "# Title", title: nil),
            AITextProviderBlock(index: 1, text: "Body", title: nil),
        ]), request: 2)
        guard workspace.phase == .ready,
              workspace.outputBlocks.count == 1,
              workspace.outputBlocks[0].text == "# Title\n\nBody" else {
            return false
        }
        workspace.reset()

        selection = AITextGenerationSelection(
            connectorKind: .codexCLI,
            modelID: nil,
            mode: .ask,
            output: .mailbox
        )
        guard !workspace.generate(), provider.requests.count == 3 else {
            return false
        }

        let expectedHandle = MailboxGenerationHandle(
            threadID: UUID(),
            generationID: UUID(),
            sequence: 7
        )
        var routedPlan: AITextGenerationPlan?
        let result = AITextGenerationCommandRouter.request(
            controls: workspace,
            dependencies: .init(
                sourceModel: source,
                selectionResolver: { _ in selection },
                startMailbox: {
                    routedPlan = $0
                    return expectedHandle
                }
            )
        )
        guard result == .mailboxStarted(expectedHandle),
              routedPlan?.selection == selection,
              routedPlan?.sourceText == "inline-source",
              routedPlan?.preparedPrompt.contains("USER_PAYLOAD_JSON:") == true,
              provider.requests.count == 3 else {
            return false
        }
        return true
    }

    private static func mailboxJSONValidation() -> Bool {
        let source = BufferModel()
        source.stageExternal("json-source", origin: .rime)
        let provider = AITextMailboxSmokeProvider()
        let store = AITextMailboxSmokeStore()
        let coordinator = AITextMailboxGenerationCoordinator(
            sourceModel: source,
            dependencies: .init(
                store: store,
                providerResolver: { _ in provider }
            )
        )
        let selection = AITextGenerationSelection(
            connectorKind: .codexCLI,
            modelID: nil,
            mode: .ask,
            destination: .mailbox,
            format: .json
        )
        guard let firstPlan = try? AITextGenerationPlan.capture(
            sourceModel: source,
            selection: selection
        ), let first = try? coordinator.start(firstPlan),
              provider.requests.first?.preparedPrompt?.contains(
                "Put one complete valid JSON value"
              ) == true else {
            return false
        }
        provider.emit(.blockSnapshot(AITextProviderBlock(
            index: 0,
            text: #"{"unfinished":"#,
            title: nil
        )), request: 0)
        guard store.previewResponses[first.generationID]
                == #"{"unfinished":"#,
              store.previewFormats[first.generationID] == .plain else {
            return false
        }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "not-json", title: nil),
        ]), request: 0)
        guard store.completedResponses[first.generationID] == nil,
              store.failedMessages[first.generationID] != nil,
              source.stagedText == "json-source" else {
            return false
        }

        guard case let .generationStarted(retry) = try? coordinator.submitComposer(
            threadID: first.threadID,
            body: "retry json"
        ), provider.requests.count == 2,
              provider.requests[1].preparedPrompt?.contains(
                "Put one complete valid JSON value"
              ) == true else {
            return false
        }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "{\"retried\":true}", title: nil),
        ]), request: 1)
        guard store.completedFormats[retry.generationID] == .json else {
            return false
        }

        guard let secondPlan = try? AITextGenerationPlan.capture(
            sourceModel: source,
            selection: selection
        ), let second = try? coordinator.start(secondPlan) else {
            return false
        }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "{\"ok\":true}", title: nil),
        ]), request: 2)
        guard store.completedResponses[second.generationID] == "{\"ok\":true}",
              store.completedFormats[second.generationID] == .json else {
            return false
        }

        source.stageExternal("markdown-source", origin: .rime)
        let markdownSelection = AITextGenerationSelection(
            connectorKind: .codexCLI,
            modelID: nil,
            mode: .ask,
            destination: .mailbox,
            format: .markdown
        )
        guard let thirdPlan = try? AITextGenerationPlan.capture(
            sourceModel: source,
            selection: markdownSelection
        ), let third = try? coordinator.start(thirdPlan) else {
            return false
        }
        provider.emit(.blockSnapshot(AITextProviderBlock(
            index: 0,
            text: "# Streaming",
            title: nil
        )), request: 3)
        guard store.previewResponses[third.generationID] == "# Streaming",
              store.previewFormats[third.generationID] == .plain else {
            return false
        }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "# Streaming", title: nil),
            AITextProviderBlock(index: 1, text: "Complete", title: nil),
        ]), request: 3)
        return store.completedResponses[third.generationID]
                == "# Streaming\n\nComplete"
            && store.completedFormats[third.generationID] == .markdown
            && store.previewResponses[third.generationID] == nil
            && store.completedFormats[second.generationID] == .json
            && source.stagedText.isEmpty
    }

    /// Integration boundary: coordinator admission must fail before launching
    /// the provider when only the user slot, but not its assistant slot, fits.
    private static func mailboxCapacityAdmission() -> Bool {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "rimebuffer-ai-mailbox-capacity-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        do {
            let store = try MailboxStore(
                storageRoot: root,
                limits: MailboxStoreLimits(
                    maximumThreads: 2,
                    maximumMessagesPerThread: 3,
                    maximumMessageCharacters: 4_096,
                    maximumFileBytes: 1_048_576
                )
            )
            let initial = try store.beginAIConversation(
                source: .codexCLI(model: "capacity-model"),
                prompt: "first"
            )
            _ = try store.completeGeneration(initial, response: "second")

            let source = BufferModel()
            let provider = AITextMailboxSmokeProvider()
            let coordinator = AITextMailboxGenerationCoordinator(
                sourceModel: source,
                dependencies: .init(
                    store: store,
                    providerResolver: { _ in provider }
                )
            )
            let before = store.snapshot
            do {
                _ = try coordinator.submitComposer(
                    threadID: initial.threadID,
                    body: "must be rejected before provider launch"
                )
                return false
            } catch let error as AITextMailboxGenerationError {
                guard error == .persistence(
                    MailboxStoreError.capacityExceeded.localizedDescription
                ) else {
                    return false
                }
            }
            return provider.requests.isEmpty
                && coordinator.activeJobCount == 0
                && store.snapshot == before
                && store.thread(id: initial.threadID)?.messages.map(\.body)
                    == ["first", "second"]
        } catch {
            return false
        }
    }

    private static func backgroundTerminalLifecycle() -> Bool {
        let source = BufferModel()
        source.stageExternal("source", origin: .rime)
        let provider = AITextMailboxSmokeProvider()
        let store = AITextMailboxSmokeStore()
        var notices: [AITextMailboxGenerationNotice] = []
        let coordinator = AITextMailboxGenerationCoordinator(
            sourceModel: source,
            dependencies: .init(
                store: store,
                providerResolver: { kind in
                    kind == provider.kind ? provider : nil
                },
                notice: { notices.append($0) }
            )
        )
        let selection = AITextGenerationSelection(
            connectorKind: .codexCLI,
            modelID: "model-frozen",
            mode: .polish,
            destination: .mailbox,
            format: .plain
        )
        let plan: AITextGenerationPlan
        do {
            plan = try AITextGenerationPlan.capture(
                sourceModel: source,
                selection: selection
            )
        } catch {
            return false
        }
        let first: MailboxGenerationHandle
        do {
            first = try coordinator.start(plan)
        } catch {
            return false
        }
        guard coordinator.activeJobCount == 1,
              provider.requests.count == 1,
              provider.requests[0].requestID == plan.requestID,
              provider.requests[0].modelID == "model-frozen",
              provider.requests[0].preparedPrompt == plan.preparedPrompt else {
            return false
        }

        source.pauseCapturePreservingContent()
        guard provider.cancellations.first?.wasCancelled == false else {
            return false
        }
        provider.emit(.activity(AITextProviderActivity(
            kind: .reasoning,
            message: "hidden lifecycle only"
        )), request: 0)
        provider.emit(.blockSnapshot(AITextProviderBlock(
            index: 1,
            text: "tail",
            title: nil
        )), request: 0)
        guard store.previewResponses[first.generationID] == "tail",
              store.previewFormats[first.generationID] == .plain,
              store.completedResponses.isEmpty,
              store.threads.first(where: { $0.id == first.threadID })?.unread == false,
              notices.isEmpty,
              source.stagedText == "source" else {
            return false
        }
        provider.emit(.blockSnapshot(AITextProviderBlock(
            index: 0,
            text: "head-one",
            title: nil
        )), request: 0)
        provider.emit(.blockSnapshot(AITextProviderBlock(
            index: 0,
            text: "head-two",
            title: nil
        )), request: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        guard store.previewResponses[first.generationID]
                == "head-two\n\ntail",
              store.completedResponses.isEmpty,
              notices.isEmpty else {
            return false
        }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "complete-one", title: nil),
            AITextProviderBlock(index: 1, text: "complete-two", title: nil),
        ]), request: 0)
        guard coordinator.activeJobCount == 0,
              store.completedResponses[first.generationID]
                == "complete-one\n\ncomplete-two",
              store.completedFormats[first.generationID] == .plain,
              store.completionCounts[first.generationID] == 1,
              store.previewResponses[first.generationID] == nil,
              source.stagedText.isEmpty,
              notices == [.completed(
                threadID: first.threadID,
                sequence: first.sequence,
                unreadCount: 1
              )] else {
            return false
        }

        source.stageExternal("retry source", origin: .rime)
        let failedPlan: AITextGenerationPlan
        do {
            failedPlan = try AITextGenerationPlan.capture(
                sourceModel: source,
                selection: selection
            )
        } catch {
            return false
        }
        let failed: MailboxGenerationHandle
        do {
            failed = try coordinator.start(failedPlan)
        } catch {
            return false
        }
        provider.emit(.blockSnapshot(AITextProviderBlock(
            index: 0,
            text: "discard-on-failure",
            title: nil
        )), request: 1)
        guard store.previewResponses[failed.generationID]
                == "discard-on-failure" else {
            return false
        }
        provider.finish(.failure(.failed), request: 1)
        provider.finish(.failure(.failed), request: 1)
        provider.emit(.blockSnapshot(AITextProviderBlock(
            index: 0,
            text: "late partial",
            title: nil
        )), request: 1)
        guard store.failedMessages[failed.generationID]
                == AITextProviderError.failed.userFacingMessage,
              source.stagedText == "retry source",
              store.previewResponses[failed.generationID] == nil,
              store.completedResponses[failed.generationID] == nil,
              notices.filter({
                  if case .failed(_, _) = $0 { return true }
                  return false
              }).count == 1 else {
            return false
        }

        let requestCountBeforeNote = provider.requests.count
        let localThreadID = store.addLocalThread()
        do {
            guard case .localNoteAdded(_) = try coordinator.submitComposer(
                threadID: localThreadID,
                body: "private note"
            ) else {
                return false
            }
        } catch {
            return false
        }
        guard provider.requests.count == requestCountBeforeNote,
              store.localNoteCount == 1 else {
            return false
        }

        do {
            guard case .generationStarted(_) = try coordinator.submitComposer(
                threadID: first.threadID,
                body: "continue"
            ) else {
                return false
            }
        } catch {
            return false
        }
        guard provider.requests.count == requestCountBeforeNote + 1,
              provider.requests.last?.modelID == "model-frozen",
              provider.requests.last?.preparedPrompt?.contains(
                "CONVERSATION_JSON"
              ) == true else {
            return false
        }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "continued", title: nil),
        ]), request: 2)
        return provider.cancellations.allSatisfy { !$0.wasCancelled }
    }
}

/// Pure/fake smoke. It launches no CLI and performs no network request.
func runAITextMailboxGenerationSmokeTest() -> Bool {
    AITextMailboxGenerationSmoke.run()
}
