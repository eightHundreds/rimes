import InputMethodKit
import Carbon.HIToolbox
import Foundation

/// One-shot authority for the sole deliberate secure-field exception: an
/// encrypted Capsule password selected by title and confirmed with the user's
/// physical unlock chord. The permit is bound to one record, FocusToken and
/// IMK client proxy, expires almost immediately, and consumes before insert.
final class CapsulePasswordDeliveryPermit {
    fileprivate let recordID: UUID
    fileprivate let targetToken: FocusToken
    fileprivate let clientIdentity: ObjectIdentifier
    fileprivate let expiresAt: CFAbsoluteTime
    fileprivate var consumed = false

    fileprivate init(recordID: UUID,
                     target: FocusLease,
                     lifetime: TimeInterval = 2.0) {
        self.recordID = recordID
        targetToken = target.token
        clientIdentity = target.clientIdentity
        expiresAt = CFAbsoluteTimeGetCurrent() + lifetime
    }

    fileprivate func consume(recordID: UUID,
                             targetToken: FocusToken,
                             client: IMKTextInput) -> Bool {
        guard !consumed,
              CFAbsoluteTimeGetCurrent() <= expiresAt,
              self.recordID == recordID,
              self.targetToken == targetToken,
              clientIdentity == ObjectIdentifier(client as AnyObject) else {
            return false
        }
        consumed = true
        return true
    }
}

enum CapsulePasswordDeliveryAuthorization {
    static func issue(recordID: UUID,
                      target: FocusLease) -> CapsulePasswordDeliveryPermit {
        CapsulePasswordDeliveryPermit(recordID: recordID, target: target)
    }
}

/// The SOLE place text reaches the client. Every commit — ordinary, chord
/// release, or raw fallback — goes through here so ordering is guaranteed.
enum Delivery {
    /// Inserts `text` into `client`, unless macOS secure input is active.
    ///
    /// Secure input (password fields, and any app that opted in) blocks third-
    /// party input methods from *seeing* keystrokes, but it does NOT stop us
    /// pushing already-buffered text into whatever field is focused. This gate
    /// is the security backstop: when secure input is on, refuse to deliver so
    /// buffered content can never land in a password field. It is queried at the
    /// delivery moment (cheap, authoritative) rather than polled.
    ///
    /// Returns whether the text was actually inserted, so the buffer can keep
    /// unsent blocks instead of dropping them (see BufferDeliveryCoordinator).
    /// Does NOT cover apps that draw their own password fields without enabling
    /// secure input — that is out of this backstop's reach.
    @discardableResult
    static func insert(_ text: String, into client: IMKTextInput) -> Bool {
        guard !text.isEmpty else { return true }
        guard !IsSecureEventInputEnabled() else {
            IMELog.write("delivery blocked: secure input active len=\(text.count)")
            return false
        }
        client.insertText(text as NSString, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }

    /// Inserts one locally encrypted Capsule password after consuming an exact
    /// physical-chord permit. Ordinary callers cannot use this overload and
    /// the standard secure-input guard above remains unchanged.
    @discardableResult
    static func insert(_ text: String,
                       into client: IMKTextInput,
                       capsulePasswordRecordID recordID: UUID,
                       targetToken: FocusToken,
                       permit: CapsulePasswordDeliveryPermit) -> Bool {
        guard !text.isEmpty,
              permit.consume(
                recordID: recordID,
                targetToken: targetToken,
                client: client
              ) else {
            IMELog.write("capsule password delivery blocked: invalid one-shot permit")
            return false
        }
        client.insertText(
            text as NSString,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        return true
    }
}
