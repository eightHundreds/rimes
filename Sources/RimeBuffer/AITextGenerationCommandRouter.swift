import Foundation

/// Result shared by the workbench button and Buffer Return command. The caller
/// owns window policy: a Mailbox start is already durable and may immediately
/// be followed by `closeAndPause()`, while an inline start keeps Buffer open.
enum AITextGenerationCommandResult: Equatable {
    case rejected(String)
    case inlineStarted
    case mailboxStarted(MailboxGenerationHandle)

    var didStart: Bool {
        switch self {
        case .inlineStarted, .mailboxStarted:
            return true
        case .rejected:
            return false
        }
    }
}

enum AITextGenerationCommandRouter {
    struct Dependencies {
        let sourceModel: BufferModel
        let selectionResolver:
            (AITextProviderKind) throws -> AITextGenerationSelection
        let startMailbox:
            (AITextGenerationPlan) throws -> MailboxGenerationHandle

        init(
            sourceModel: BufferModel = .shared,
            selectionResolver: @escaping
                (AITextProviderKind) throws -> AITextGenerationSelection = {
                    try AITextGenerationPreferenceStore.shared.requestSelection(
                        connectorKind: $0
                    )
                },
            startMailbox: @escaping
                (AITextGenerationPlan) throws -> MailboxGenerationHandle = {
                    try AITextMailboxGenerationCoordinator.shared.start($0)
                }
        ) {
            self.sourceModel = sourceModel
            self.selectionResolver = selectionResolver
            self.startMailbox = startMailbox
        }
    }

    /// Routes only a request-generation gesture. Non-AI controls retain their
    /// established inline behavior. For AI, the same frozen selection resolver
    /// is used by both this router and `AITextPluginWorkspace.generate()`.
    static func request(
        controls: any WorkbenchManualGenerationControls,
        dependencies: Dependencies = Dependencies()
    ) -> AITextGenerationCommandResult {
        guard controls.primaryAction == .requestGeneration else {
            return .rejected("当前状态不能开始生成")
        }
        guard let workspace = controls as? AITextPluginWorkspace else {
            return controls.generate()
                ? .inlineStarted
                : .rejected("生成请求未启动")
        }

        do {
            let selection = try dependencies.selectionResolver(workspace.kind)
            guard selection.destination == .mailbox else {
                return workspace.generate()
                    ? .inlineStarted
                    : .rejected("生成请求未启动")
            }
            let plan = try AITextGenerationPlan.capture(
                sourceModel: dependencies.sourceModel,
                selection: selection
            )
            return .mailboxStarted(try dependencies.startMailbox(plan))
        } catch {
            return .rejected(error.localizedDescription)
        }
    }
}
