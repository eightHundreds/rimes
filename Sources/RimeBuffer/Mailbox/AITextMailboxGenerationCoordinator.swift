import Foundation

protocol AITextMailboxPersisting: AnyObject {
    var snapshot: MailboxStoreSnapshot { get }
    func thread(id: UUID) -> MailboxThread?
    func beginAIConversation(source: MailboxSource,
                             title: String?,
                             prompt: String,
                             author: String,
                             format: AITextContentFormat) throws -> MailboxGenerationHandle
    func beginAIReply(threadID: UUID,
                      body: String,
                      author: String,
                      format: AITextContentFormat) throws -> MailboxGenerationHandle
    @discardableResult
    func updateGenerationPreview(_ handle: MailboxGenerationHandle,
                                 response: String,
                                 author: String?,
                                 format: AITextContentFormat) throws -> UUID
    @discardableResult
    func completeGeneration(_ handle: MailboxGenerationHandle,
                            response: String,
                            author: String?,
                            format: AITextContentFormat) throws -> UUID
    func failGeneration(_ handle: MailboxGenerationHandle,
                        message: String) throws
    @discardableResult
    func addLocalNote(threadID: UUID,
                      body: String,
                      author: String) throws -> UUID
}

extension MailboxStore: AITextMailboxPersisting {}

enum AITextMailboxGenerationError: LocalizedError, Equatable {
    case connectorUnavailable(String)
    case unsupportedConversationSource
    case invalidMessage
    case invalidTerminalResponse
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case let .connectorUnavailable(message), let .persistence(message):
            return message
        case .unsupportedConversationSource:
            return "该 Mailbox 会话不能继续向 AI 提问"
        case .invalidMessage:
            return "请输入有效的回复或备注"
        case .invalidTerminalResponse:
            return "生成结果格式无效"
        }
    }
}

enum AITextMailboxComposerResult: Equatable {
    case generationStarted(MailboxGenerationHandle)
    case localNoteAdded(UUID)
}

enum AITextMailboxGenerationNotice: Equatable {
    case completed(threadID: UUID, sequence: Int, unreadCount: Int)
    case failed(threadID: UUID?, message: String)
}

/// Owns provider tasks created by Mailbox's native new-conversation and reply
/// commands. It has no Buffer source, workbench observer, or source-consumption
/// path; provider timeout/process failure still terminates a job normally.
final class AITextMailboxGenerationCoordinator {
    static let shared = AITextMailboxGenerationCoordinator()

    struct Dependencies {
        let store: any AITextMailboxPersisting
        let providerResolver: (AITextProviderKind) -> (any AITextProvider)?
        let notice: (AITextMailboxGenerationNotice) -> Void

        init(
            store: any AITextMailboxPersisting = MailboxStore.shared,
            providerResolver: @escaping (AITextProviderKind) -> (any AITextProvider)? = {
                AITextConnectorRegistry.shared.provider(for: $0)
            },
            notice: @escaping (AITextMailboxGenerationNotice) -> Void = { _ in }
        ) {
            self.store = store
            self.providerResolver = providerResolver
            self.notice = notice
        }
    }

    private struct RequestPlan {
        let requestID: UUID
        let sourceText: String
        let connectorKind: AITextProviderKind
        let modelID: String?
        let format: AITextContentFormat
        let preparedPrompt: String
    }

    private final class Job {
        let handle: MailboxGenerationHandle
        let plan: RequestPlan
        let relay: AITextCancellationRelay
        var streamingBlocks: [Int: AITextProviderBlock] = [:]
        var lastPublishedPreview: String?
        var lastPreviewPublishUptime: TimeInterval?
        var pendingPreviewBody: String?
        var pendingPreviewWorkItem: DispatchWorkItem?

        init(handle: MailboxGenerationHandle,
             plan: RequestPlan,
             relay: AITextCancellationRelay) {
            self.handle = handle
            self.plan = plan
            self.relay = relay
        }
    }

    private static let previewMinimumInterval: TimeInterval = 0.05

    private let dependencies: Dependencies
    /// Main-thread isolated. Provider callbacks are marshalled before access.
    private var jobs: [UUID: Job] = [:]

    init(dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
    }

    var activeJobCount: Int {
        dispatchPrecondition(condition: .onQueue(.main))
        return jobs.count
    }

    /// Starts a Mailbox-native conversation without borrowing text, ownership,
    /// or lifecycle from Buffer. The connector and model are normalized and
    /// frozen into both the provider request and the durable thread source before
    /// the background job starts. New conversations are always ordinary plain
    /// question/answer threads; later replies retain that thread-local source.
    @discardableResult
    func startConversation(
        connectorKind: AITextProviderKind,
        modelID: String?,
        prompt: String
    ) throws -> MailboxGenerationHandle {
        dispatchPrecondition(condition: .onQueue(.main))
        let normalizedPrompt = prompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedPrompt.isEmpty,
              normalizedPrompt.utf8.count
                <= AITextRuntimeLimits.maximumSourceBytes else {
            throw AITextMailboxGenerationError.invalidMessage
        }
        let selection = try AITextGenerationPreferenceStore.normalized(
            AITextGenerationSelection(
                connectorKind: connectorKind,
                modelID: modelID,
                mode: .ask,
                destination: .inline,
                format: .plain
            )
        )
        let plan = RequestPlan(
            requestID: UUID(),
            sourceText: normalizedPrompt,
            connectorKind: selection.connectorKind,
            modelID: selection.modelID,
            format: .plain,
            preparedPrompt: try AITextRequestPlanner.initialPrompt(
                sourceText: normalizedPrompt,
                mode: .ask,
                format: .plain
            )
        )
        return try persistAndStartConversation(plan)
    }

    private func persistAndStartConversation(
        _ plan: RequestPlan
    ) throws -> MailboxGenerationHandle {
        dispatchPrecondition(condition: .onQueue(.main))
        let provider = try resolvedProvider(for: plan.connectorKind)
        let handle: MailboxGenerationHandle
        do {
            handle = try dependencies.store.beginAIConversation(
                source: mailboxSource(
                    connectorKind: plan.connectorKind,
                    modelID: plan.modelID
                ),
                title: nil,
                prompt: plan.sourceText,
                author: "你",
                format: plan.format
            )
        } catch {
            throw persistenceError(error)
        }
        startProvider(
            plan: plan,
            handle: handle,
            provider: provider
        )
        return handle
    }

    /// AI-backed threads rebuild a bounded provider-neutral transcript. One-way
    /// HTTP/MCP/etc. threads take the local-note path and issue no provider call.
    @discardableResult
    func submitComposer(threadID: UUID,
                        body: String,
                        author: String = "你") throws
        -> AITextMailboxComposerResult {
        dispatchPrecondition(condition: .onQueue(.main))
        let normalized = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= AITextRuntimeLimits.maximumSourceBytes else {
            throw AITextMailboxGenerationError.invalidMessage
        }
        guard let thread = dependencies.store.thread(id: threadID) else {
            throw AITextMailboxGenerationError.persistence(
                MailboxStoreError.missingThread.localizedDescription
            )
        }
        switch thread.source.replyCapability {
        case .localNotesOnly:
            do {
                return .localNoteAdded(try dependencies.store.addLocalNote(
                    threadID: threadID,
                    body: normalized,
                    author: author
                ))
            } catch {
                throw persistenceError(error)
            }
        case .aiContinuation:
            guard let connectorKind = providerKind(for: thread.source) else {
                throw AITextMailboxGenerationError.unsupportedConversationSource
            }
            let provider = try resolvedProvider(for: connectorKind)
            let turns = try conversationTurns(thread: thread, appendingUser: normalized)
            let responseFormat = thread.messages.reversed().first(where: {
                $0.role == .inbound && $0.kind == .content
            })?.format ?? thread.generation?.expectedFormat ?? .plain
            let preparedPrompt = try AITextRequestPlanner.continuationPrompt(
                turns: turns,
                format: responseFormat
            )
            let selection = AITextGenerationSelection(
                connectorKind: connectorKind,
                modelID: thread.source.model,
                mode: .ask,
                destination: .inline,
                format: responseFormat
            )
            let plan = RequestPlan(
                requestID: UUID(),
                sourceText: normalized,
                connectorKind: selection.connectorKind,
                modelID: try AITextGenerationPreferenceStore.normalized(selection)
                    .modelID,
                format: responseFormat,
                preparedPrompt: preparedPrompt
            )
            let handle: MailboxGenerationHandle
            do {
                handle = try dependencies.store.beginAIReply(
                    threadID: threadID,
                    body: normalized,
                    author: author,
                    format: responseFormat
                )
            } catch {
                throw persistenceError(error)
            }
            startProvider(
                plan: plan,
                handle: handle,
                provider: provider
            )
            return .generationStarted(handle)
        }
    }

    private func startProvider(
        plan: RequestPlan,
        handle: MailboxGenerationHandle,
        provider: any AITextProvider
    ) {
        let relay = AITextCancellationRelay()
        jobs[handle.generationID] = Job(
            handle: handle,
            plan: plan,
            relay: relay
        )
        let task = provider.generate(
            AITextProviderRequest(
                requestID: plan.requestID,
                sourceText: plan.sourceText,
                preparedPrompt: plan.preparedPrompt,
                modelID: plan.modelID
            ),
            onEvent: { [weak self] event in
                self?.performOnMain { coordinator in
                    coordinator.receive(
                        event,
                        generationID: handle.generationID
                    )
                }
            },
            completion: { [weak self] result in
                self?.performOnMain { coordinator in
                    coordinator.finish(result, generationID: handle.generationID)
                }
            }
        )
        // Some providers may fail synchronously before returning a no-op task.
        // The relay is installed after the job boundary is visible so either
        // callback ordering remains safe.
        relay.install(task)
    }

    /// Provider block snapshots contain only the connector's validated public
    /// output channel; activity/reasoning events are never rendered as message
    /// content. Previews remain process-local and are coalesced to keep AppKit
    /// layout work bounded while retaining a prompt first update.
    private func receive(_ event: AITextProviderEvent,
                         generationID: UUID) {
        guard let job = jobs[generationID] else { return }
        // Every Mailbox format may show provider progress, but the transient
        // row is deliberately plain text. This makes incomplete Markdown/JSON
        // visible without presenting it as valid structured content; only the
        // terminal response receives the selected format and reaches disk.
        guard case let .blockSnapshot(block) = event,
              block.index >= 0,
              block.index < AITextRuntimeLimits.maximumModelBlockCount,
              let validated = try? AITextResultDecoder
                .validateLogicalBlocks([block]).first else {
            return
        }
        job.streamingBlocks[validated.index] = validated
        let body = job.streamingBlocks.values
            .sorted(by: { $0.index < $1.index })
            .map(\.text)
            .joined(separator: "\n\n")
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.utf8.count <= AITextRuntimeLimits.maximumWireBytes,
              body != job.lastPublishedPreview,
              body != job.pendingPreviewBody else {
            return
        }
        schedulePreview(body, for: job)
    }

    private func schedulePreview(_ body: String, for job: Job) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = job.lastPreviewPublishUptime,
           now - last < Self.previewMinimumInterval {
            job.pendingPreviewBody = body
            job.pendingPreviewWorkItem?.cancel()
            let delay = Self.previewMinimumInterval - (now - last)
            let workItem = DispatchWorkItem { [weak self, weak job] in
                guard let self, let job,
                      self.jobs[job.handle.generationID] === job,
                      let pending = job.pendingPreviewBody else {
                    return
                }
                self.publishPreview(pending, for: job)
            }
            job.pendingPreviewWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay,
                                          execute: workItem)
            return
        }
        publishPreview(body, for: job)
    }

    private func publishPreview(_ body: String, for job: Job) {
        guard jobs[job.handle.generationID] === job,
              body != job.lastPublishedPreview else {
            return
        }
        job.pendingPreviewWorkItem = nil
        job.pendingPreviewBody = nil
        do {
            _ = try dependencies.store.updateGenerationPreview(
                job.handle,
                response: body,
                author: mailboxSource(
                    connectorKind: job.plan.connectorKind,
                    modelID: job.plan.modelID
                ).displayName,
                format: .plain
            )
            job.lastPublishedPreview = body
            job.lastPreviewPublishUptime = ProcessInfo.processInfo.systemUptime
        } catch {
            // A preview is best-effort. Terminal validation/persistence remains
            // authoritative and will surface its own user-facing failure.
            IMELog.write("mailbox streaming preview failed kind=store")
        }
    }

    private func finish(
        _ result: Result<[AITextProviderBlock], AITextProviderError>,
        generationID: UUID
    ) {
        guard let job = jobs.removeValue(forKey: generationID) else { return }
        job.pendingPreviewWorkItem?.cancel()
        job.pendingPreviewWorkItem = nil
        job.pendingPreviewBody = nil
        switch result {
        case let .success(blocks):
            do {
                let response = try terminalResponse(
                    from: blocks,
                    format: job.plan.format
                )
                _ = try dependencies.store.completeGeneration(
                    job.handle,
                    response: response,
                    author: mailboxSource(
                        connectorKind: job.plan.connectorKind,
                        modelID: job.plan.modelID
                    ).displayName,
                    format: job.plan.format
                )
                dependencies.notice(.completed(
                    threadID: job.handle.threadID,
                    sequence: job.handle.sequence,
                    unreadCount: dependencies.store.snapshot.unreadCount
                ))
            } catch {
                fail(job, message: userFacingMessage(for: error))
            }
        case let .failure(error):
            fail(job, message: error.userFacingMessage)
        }
    }

    /// A failed Mailbox generation never reaches Buffer. If persistence of the
    /// failure marker itself is unavailable, the notice still reports the
    /// provider or storage error while the durable user turn remains in Mailbox.
    private func fail(_ job: Job, message: String) {
        var resolvedMessage = message
        do {
            try dependencies.store.failGeneration(job.handle, message: message)
        } catch {
            resolvedMessage = userFacingMessage(for: error)
        }
        dependencies.notice(.failed(
            threadID: job.handle.threadID,
            message: resolvedMessage
        ))
    }

    private func resolvedProvider(
        for kind: AITextProviderKind
    ) throws -> any AITextProvider {
        guard let provider = dependencies.providerResolver(kind) else {
            throw AITextMailboxGenerationError.connectorUnavailable(
                "连接器不可用：\(kind.displayName)"
            )
        }
        switch provider.availability {
        case .ready:
            return provider
        case let .unavailable(message):
            throw AITextMailboxGenerationError.connectorUnavailable(message)
        }
    }

    private func terminalResponse(
        from blocks: [AITextProviderBlock],
        format: AITextContentFormat
    ) throws -> String {
        let validated: [AITextProviderBlock]
        do {
            validated = try AITextResultDecoder.validateLogicalBlocks(blocks)
        } catch {
            throw AITextMailboxGenerationError.invalidTerminalResponse
        }
        let response = validated.sorted(by: { $0.index < $1.index })
            .map(\.text)
            .joined(separator: "\n\n")
        guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              response.utf8.count <= AITextRuntimeLimits.maximumWireBytes else {
            throw AITextMailboxGenerationError.invalidTerminalResponse
        }
        if format == .json {
            guard let data = response.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(
                    with: data,
                    options: [.fragmentsAllowed]
                  )) != nil else {
                throw AITextMailboxGenerationError.invalidTerminalResponse
            }
        }
        return response
    }

    private func mailboxSource(
        connectorKind: AITextProviderKind,
        modelID: String?
    ) -> MailboxSource {
        switch connectorKind {
        case .codexCLI:
            return .codexCLI(model: modelID)
        case .claudeCodeCLI:
            return .claudeCodeCLI(model: modelID)
        case .openAICompatible:
            return .openAICompatible(model: modelID)
        }
    }

    private func providerKind(for source: MailboxSource) -> AITextProviderKind? {
        switch source.kind {
        case .codexCLI: return .codexCLI
        case .claudeCodeCLI: return .claudeCodeCLI
        case .openAICompatible: return .openAICompatible
        case .mcp, .http, .sse, .ssh, .plugin, .other: return nil
        }
    }

    private func conversationTurns(
        thread: MailboxThread,
        appendingUser userText: String
    ) throws -> [AITextConversationPromptTurn] {
        var turns = thread.messages.compactMap { message -> AITextConversationPromptTurn? in
            guard message.kind == .content else { return nil }
            switch message.role {
            case .user:
                return AITextConversationPromptTurn(role: .user,
                                                    content: message.body)
            case .inbound:
                return AITextConversationPromptTurn(role: .assistant,
                                                    content: message.body)
            case .system:
                return nil
            }
        }
        turns.append(AITextConversationPromptTurn(role: .user, content: userText))
        guard !turns.isEmpty else {
            throw AITextGenerationPlanError.invalidConversation
        }
        return turns
    }

    private func persistenceError(_ error: Error) -> AITextMailboxGenerationError {
        .persistence(userFacingMessage(for: error))
    }

    private func userFacingMessage(for error: Error) -> String {
        if let error = error as? AITextMailboxGenerationError {
            return error.localizedDescription
        }
        if let error = error as? AITextGenerationPlanError {
            return error.localizedDescription
        }
        if let error = error as? MailboxStoreError {
            return error.localizedDescription
        }
        if let error = error as? AITextProviderError {
            return error.userFacingMessage
        }
        return "Mailbox 暂时无法保存生成结果"
    }

    private func performOnMain(
        _ operation: @escaping (AITextMailboxGenerationCoordinator) -> Void
    ) {
        if Thread.isMainThread {
            operation(self)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                operation(self)
            }
        }
    }
}

extension AITextMailboxGenerationCoordinator: MailboxAIReplyCoordinating {
    /// Accepts the first Mailbox turn from either the standalone window's main
    /// thread or another UI bridge. Success means the trimmed prompt and frozen
    /// connector/model selection are durable and the provider job is owned by
    /// this coordinator; the terminal answer is delivered later through Store.
    func startMailboxConversation(
        selection: MailboxNewConversationSelection,
        body: String,
        completion: @escaping (
            Result<MailboxGenerationHandle, Error>
        ) -> Void
    ) {
        let submit = { [weak self] in
            guard let self else {
                completion(.failure(
                    AITextMailboxGenerationError.connectorUnavailable(
                        "AI 连接器暂时不可用"
                    )
                ))
                return
            }
            do {
                let handle = try self.startConversation(
                    connectorKind: selection.connectorKind,
                    modelID: selection.modelID,
                    prompt: body
                )
                completion(.success(handle))
            } catch {
                completion(.failure(error))
            }
        }
        if Thread.isMainThread {
            submit()
        } else {
            DispatchQueue.main.async(execute: submit)
        }
    }

    /// The Mailbox composer clears its draft once the continuation has been
    /// durably recorded and its provider task is owned by this coordinator.
    /// Terminal success/failure is delivered later through MailboxStore.
    func sendMailboxReply(
        threadID: UUID,
        body: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let submit = { [weak self] in
            guard let self else {
                completion(.failure(
                    AITextMailboxGenerationError.connectorUnavailable(
                        "AI 连接器暂时不可用"
                    )
                ))
                return
            }
            do {
                _ = try self.submitComposer(threadID: threadID, body: body)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
        if Thread.isMainThread {
            submit()
        } else {
            DispatchQueue.main.async(execute: submit)
        }
    }
}
