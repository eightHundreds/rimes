import Foundation

/// An immutable description of the exact generated result a copy gesture saw.
/// The snapshot deliberately keeps per-block text as well as the joined value:
/// callers can present one plain-text clipboard item while the final preflight
/// still proves that every ordered delivery block is unchanged.
struct BufferGeneratedResultCopySnapshot: Equatable {
    let sourceIdentity: ObjectIdentifier
    let workspaceID: String
    let generation: UInt64
    let blockIDs: [UUID]
    let blockTexts: [String]
    let text: String
}

/// Read-only boundary for copying a generated Buffer result. It never prepares
/// or consumes delivery state, touches NSPasteboard, closes a window, or calls
/// Delivery.insert. UI/controller code may freeze a snapshot, perform its own
/// protection checks, and ask for one last validation immediately before the
/// clipboard write.
enum BufferGeneratedResultCopyRules {
    static func freeze(
        protected: Bool,
        source: any BufferDeliveryContentSource =
            BufferDeliveryContentRouter.current()
    ) -> BufferGeneratedResultCopySnapshot? {
        guard !protected,
              !(source is BufferModel),
              !source.hasIncompleteDeliveryBlocks else {
            return nil
        }

        let sourceIdentity = ObjectIdentifier(source)
        let workspaceID = source.deliveryWorkspaceID
        let generation = source.deliveryGeneration
        guard !workspaceID.isEmpty else { return nil }

        let pending = source.deliveryPendingBlocks
        let blockIDs = pending.map(\.id)
        let blockTexts = pending.map(\.text)
        guard !pending.isEmpty,
              pending.allSatisfy({
                  $0.pluginMetadata?.stale != true
                      && $0.pluginMetadata?.incomplete != true
                      && BufferClipboardTextRules.validated($0.text) != nil
              }),
              Set(blockIDs).count == blockIDs.count,
              source.deliveryWorkspaceID == workspaceID,
              source.deliveryGeneration == generation,
              !source.hasIncompleteDeliveryBlocks,
              blocksStillMatch(
                source: source,
                generation: generation,
                blockIDs: blockIDs,
                blockTexts: blockTexts
              ) else {
            return nil
        }

        let text = blockTexts.joined()
        guard BufferClipboardTextRules.validated(text) != nil else { return nil }
        return BufferGeneratedResultCopySnapshot(
            sourceIdentity: sourceIdentity,
            workspaceID: workspaceID,
            generation: generation,
            blockIDs: blockIDs,
            blockTexts: blockTexts,
            text: text
        )
    }

    /// Returns the frozen joined text only while the router still resolves the
    /// same concrete source and every ordered block retains its identity and
    /// text. A caller should invoke this immediately before writing NSPasteboard.
    static func revalidatedText(
        for snapshot: BufferGeneratedResultCopySnapshot,
        protected: Bool,
        source: any BufferDeliveryContentSource =
            BufferDeliveryContentRouter.current()
    ) -> String? {
        guard !protected,
              !(source is BufferModel),
              ObjectIdentifier(source) == snapshot.sourceIdentity,
              source.deliveryWorkspaceID == snapshot.workspaceID,
              source.deliveryGeneration == snapshot.generation,
              !source.hasIncompleteDeliveryBlocks else {
            return nil
        }

        let pending = source.deliveryPendingBlocks
        guard pending.map(\.id) == snapshot.blockIDs,
              pending.map(\.text) == snapshot.blockTexts,
              pending.allSatisfy({
                  $0.pluginMetadata?.stale != true
                      && $0.pluginMetadata?.incomplete != true
              }),
              BufferClipboardTextRules.validated(snapshot.text) != nil,
              blocksStillMatch(
                source: source,
                generation: snapshot.generation,
                blockIDs: snapshot.blockIDs,
                blockTexts: snapshot.blockTexts
              ) else {
            return nil
        }
        return snapshot.text
    }

    private static func blocksStillMatch(
        source: any BufferDeliveryContentSource,
        generation: UInt64,
        blockIDs: [UUID],
        blockTexts: [String]
    ) -> Bool {
        guard blockIDs.count == blockTexts.count else { return false }
        for (id, text) in zip(blockIDs, blockTexts) {
            guard let current = source.deliveryBlock(
                id: id,
                generation: generation
            ), current.id == id, current.text == text else {
                return false
            }
        }
        return true
    }
}

private final class BufferGeneratedResultCopyProbeSource:
    BufferDeliveryContentSource {
    let deliveryWorkspaceID: String
    var deliveryGeneration: UInt64
    var hasIncompleteDeliveryBlocks: Bool
    var deliveryPendingBlocks: [BufferModel.Block]
    var returnsStaleBlocks = false

    init(
        workspaceID: String = "copy-probe",
        generation: UInt64 = 1,
        incomplete: Bool = false,
        blocks: [BufferModel.Block]
    ) {
        deliveryWorkspaceID = workspaceID
        deliveryGeneration = generation
        hasIncompleteDeliveryBlocks = incomplete
        deliveryPendingBlocks = blocks
    }

    func deliveryBlock(id: UUID, generation: UInt64) -> BufferModel.Block? {
        guard !returnsStaleBlocks,
              generation == deliveryGeneration else {
            return nil
        }
        return deliveryPendingBlocks.first { $0.id == id }
    }

    func consumeDelivered(blockIDs _: [UUID], generation _: UInt64) {}

    func markDeliveryBlockStale(id _: UUID, generation _: UInt64) -> Bool {
        false
    }
}

/// Pure, side-effect-free coverage for the result-copy identity contract.
/// Runtime smoke commands may call this without reading or replacing the
/// user's clipboard and without touching the shared BufferModel.
func runBufferGeneratedResultCopyRulesProbe() -> Bool {
    let single = BufferGeneratedResultCopyProbeSource(blocks: [
        BufferModel.Block(text: "single"),
    ])
    guard let singleSnapshot = BufferGeneratedResultCopyRules.freeze(
        protected: false,
        source: single
    ), singleSnapshot.text == "single",
       BufferGeneratedResultCopyRules.revalidatedText(
        for: singleSnapshot,
        protected: false,
        source: single
       ) == "single" else {
        return false
    }

    let multi = BufferGeneratedResultCopyProbeSource(blocks: [
        BufferModel.Block(text: "first "),
        BufferModel.Block(text: "second"),
    ])
    guard let multiSnapshot = BufferGeneratedResultCopyRules.freeze(
        protected: false,
        source: multi
    ), multiSnapshot.text == "first second",
       multiSnapshot.blockTexts == ["first ", "second"] else {
        return false
    }

    let ordinary = BufferModel()
    guard BufferGeneratedResultCopyRules.freeze(
        protected: false,
        source: ordinary
    ) == nil else {
        return false
    }

    let incomplete = BufferGeneratedResultCopyProbeSource(
        incomplete: true,
        blocks: [BufferModel.Block(text: "partial")]
    )
    let empty = BufferGeneratedResultCopyProbeSource(blocks: [])
    let stale = BufferGeneratedResultCopyProbeSource(blocks: [
        BufferModel.Block(text: "stale"),
    ])
    stale.returnsStaleBlocks = true
    guard BufferGeneratedResultCopyRules.freeze(
        protected: false,
        source: incomplete
    ) == nil,
    BufferGeneratedResultCopyRules.freeze(
        protected: false,
        source: empty
    ) == nil,
    BufferGeneratedResultCopyRules.freeze(
        protected: false,
        source: stale
    ) == nil,
    BufferGeneratedResultCopyRules.freeze(
        protected: true,
        source: single
    ) == nil else {
        return false
    }

    let generationDrift = BufferGeneratedResultCopyProbeSource(blocks: [
        BufferModel.Block(text: "before"),
    ])
    guard let generationSnapshot = BufferGeneratedResultCopyRules.freeze(
        protected: false,
        source: generationDrift
    ) else {
        return false
    }
    generationDrift.deliveryGeneration &+= 1
    guard BufferGeneratedResultCopyRules.revalidatedText(
        for: generationSnapshot,
        protected: false,
        source: generationDrift
    ) == nil else {
        return false
    }

    let textDrift = BufferGeneratedResultCopyProbeSource(blocks: [
        BufferModel.Block(text: "before"),
    ])
    guard let textSnapshot = BufferGeneratedResultCopyRules.freeze(
        protected: false,
        source: textDrift
    ) else {
        return false
    }
    let changedID = textDrift.deliveryPendingBlocks[0].id
    textDrift.deliveryPendingBlocks = [
        BufferModel.Block(id: changedID, text: "after"),
    ]
    return BufferGeneratedResultCopyRules.revalidatedText(
        for: textSnapshot,
        protected: false,
        source: textDrift
    ) == nil
}
