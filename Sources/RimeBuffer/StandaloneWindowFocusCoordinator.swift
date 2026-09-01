import Cocoa

struct StandaloneWindowFocusIdentity: Equatable {
    let bundleID: String?
    let processIdentifier: pid_t

    init(application: NSRunningApplication) {
        bundleID = application.bundleIdentifier
        processIdentifier = application.processIdentifier
    }

    init(bundleID: String?, processIdentifier: pid_t) {
        self.bundleID = bundleID
        self.processIdentifier = processIdentifier
    }
}

/// Pure gates for returning activation after a key-capable RIMES window closes.
/// FocusToken and Buffer capture are deliberately absent: AppKit restores only
/// the foreground application, then InputMethodKit must establish a fresh text
/// focus lease through its normal lifecycle.
enum StandaloneWindowFocusReturnRules {
    static func isExternalReturnTarget(
        _ candidate: StandaloneWindowFocusIdentity?,
        own: StandaloneWindowFocusIdentity
    ) -> Bool {
        guard let candidate,
              candidate.processIdentifier > 0,
              candidate.processIdentifier != own.processIdentifier else {
            return false
        }
        if let candidateBundleID = candidate.bundleID,
           let ownBundleID = own.bundleID,
           candidateBundleID == ownBundleID {
            return false
        }
        return true
    }

    static func closeHasCompleted(windowIsVisible: Bool) -> Bool {
        !windowIsVisible
    }

    static func shouldRestore(
        closeCompleted: Bool,
        remainingTrackedWindowCount: Int,
        frontmost: StandaloneWindowFocusIdentity?,
        own: StandaloneWindowFocusIdentity,
        returnTarget: StandaloneWindowFocusIdentity,
        returnTargetIsRunning: Bool,
        returnTargetIdentityMatches: Bool,
        hasOtherVisibleKeyCapableOwnWindow: Bool
    ) -> Bool {
        closeCompleted
            && remainingTrackedWindowCount == 0
            && sameProcess(frontmost, own)
            && isExternalReturnTarget(returnTarget, own: own)
            && returnTargetIsRunning
            && returnTargetIdentityMatches
            && !hasOtherVisibleKeyCapableOwnWindow
    }

    static func sameProcess(
        _ lhs: StandaloneWindowFocusIdentity?,
        _ rhs: StandaloneWindowFocusIdentity
    ) -> Bool {
        guard let lhs,
              lhs.processIdentifier > 0,
              lhs.processIdentifier == rhs.processIdentifier else {
            return false
        }
        if let leftBundleID = lhs.bundleID,
           let rightBundleID = rhs.bundleID {
            return leftBundleID == rightBundleID
        }
        return true
    }
}

/// Coordinates the activation lifetime shared by RIMES utility windows and
/// modal alerts. Multiple RIMES windows form one foreground visit: the most
/// recent real external app is retained until the last tracked window closes.
/// Closing from another app never steals focus back, and a still-visible RIMES
/// editor keeps activation.
final class StandaloneWindowFocusCoordinator {
    static let shared = StandaloneWindowFocusCoordinator()

    private final class ReturnTarget {
        let application: NSRunningApplication
        let identity: StandaloneWindowFocusIdentity

        init(application: NSRunningApplication) {
            self.application = application
            identity = StandaloneWindowFocusIdentity(application: application)
        }
    }

    private var trackedWindows = Set<ObjectIdentifier>()
    private var returnTarget: ReturnTarget?

    private init() {}

    /// Presents a modal RIMES utility alert under the same foreground lease as
    /// the standalone key windows. Background callbacks must not surface an
    /// alert after the user has switched to another input method. Explicitly
    /// ordering the alert out before retiring it also makes NSAlert's modal
    /// lifetime observable to the common close coordinator.
    @discardableResult
    func runModalAlertIfRIMESActive(
        _ alert: NSAlert
    ) -> NSApplication.ModalResponse? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard RimeInputSourceAuthority.currentSourceIsOwn() else {
            IMELog.write("standalone alert suppressed; RIMES is not selected")
            return nil
        }

        let alertWindow = alert.window
        windowWillPresent(alertWindow)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        alertWindow.orderOut(nil)
        windowWillClose(alertWindow)
        guard RimeInputSourceAuthority.currentSourceIsOwn() else {
            IMELog.write(
                "standalone alert response ignored; RIMES is not selected"
            )
            return nil
        }
        return response
    }

    func windowWillPresent(_ window: NSWindow) {
        dispatchPrecondition(condition: .onQueue(.main))
        trackedWindows.insert(ObjectIdentifier(window))

        let own = ownIdentity
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return
        }
        let candidate = StandaloneWindowFocusIdentity(application: application)
        guard StandaloneWindowFocusReturnRules.isExternalReturnTarget(
            candidate,
            own: own
        ) else { return }

        // Re-presenting an already-visible window from a newer external app
        // updates the destination. Presenting one RIMES window from another
        // keeps the original destination because the current app is our own.
        returnTarget = ReturnTarget(application: application)
    }

    /// NSWindow has a will-close delegate callback but no did-close counterpart.
    /// `windowWillClose` is emitted only after `windowShouldClose` accepts the
    /// close, so defer one main-loop turn and require the window to be hidden.
    /// A Capsule discard cancellation therefore never reaches restoration.
    func windowWillClose(_ window: NSWindow) {
        dispatchPrecondition(condition: .onQueue(.main))
        let windowIdentity = ObjectIdentifier(window)
        guard trackedWindows.contains(windowIdentity) else { return }

        DispatchQueue.main.async { [weak self, weak window] in
            guard let self else { return }
            let closeCompleted = StandaloneWindowFocusReturnRules
                .closeHasCompleted(windowIsVisible: window?.isVisible == true)
            guard closeCompleted else { return }

            self.trackedWindows.remove(windowIdentity)
            guard self.trackedWindows.isEmpty,
                  let target = self.returnTarget else { return }
            self.returnTarget = nil

            let own = self.ownIdentity
            let frontmost = NSWorkspace.shared.frontmostApplication.map(
                StandaloneWindowFocusIdentity.init(application:)
            )
            let currentTargetIdentity = StandaloneWindowFocusIdentity(
                application: target.application
            )
            let hasOtherKeyCapableWindow = NSApp.windows.contains { candidate in
                ObjectIdentifier(candidate) != windowIdentity
                    && candidate.isVisible
                    && candidate.canBecomeKey
            }
            guard StandaloneWindowFocusReturnRules.shouldRestore(
                closeCompleted: closeCompleted,
                remainingTrackedWindowCount: self.trackedWindows.count,
                frontmost: frontmost,
                own: own,
                returnTarget: target.identity,
                returnTargetIsRunning: !target.application.isTerminated,
                returnTargetIdentityMatches: currentTargetIdentity == target.identity,
                hasOtherVisibleKeyCapableOwnWindow: hasOtherKeyCapableWindow
            ) else {
                return
            }

            let activated = target.application.activate(
                options: [.activateIgnoringOtherApps]
            )
            IMELog.write(
                "standalone window returned foreground target="
                    + (target.identity.bundleID ?? "unknown")
                    + " activated=\(activated)"
            )
        }
    }

    private var ownIdentity: StandaloneWindowFocusIdentity {
        StandaloneWindowFocusIdentity(
            bundleID: Bundle.main.bundleIdentifier,
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        )
    }
}
