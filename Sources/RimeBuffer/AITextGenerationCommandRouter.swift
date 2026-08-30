import Foundation

/// Result shared by the workbench button and Buffer Return command. AI
/// Generation always stays in its inline workspace; Mailbox owns its separate
/// new-conversation and reply commands.
enum AITextGenerationCommandResult: Equatable {
    case rejected(String)
    case inlineStarted

    var didStart: Bool {
        switch self {
        case .inlineStarted:
            return true
        case .rejected:
            return false
        }
    }
}

enum AITextGenerationCommandRouter {
    /// Routes only a request-generation gesture. Non-AI controls retain their
    /// established inline behavior. Mailbox generation is intentionally absent
    /// from this boundary so neither Return nor the workbench button can create
    /// a Mailbox thread.
    static func request(
        controls: any WorkbenchManualGenerationControls
    ) -> AITextGenerationCommandResult {
        guard controls.primaryAction == .requestGeneration else {
            return .rejected("当前状态不能开始生成")
        }
        return controls.generate()
            ? .inlineStarted
            : .rejected("生成请求未启动")
    }
}
