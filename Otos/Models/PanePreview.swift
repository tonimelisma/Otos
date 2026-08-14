import CoreGraphics
import Foundation

/// Which full-size preview slot a decode belongs to. Loupe and compare-left are
/// distinct slots even when they happen to show the same asset across mode switches.
nonisolated enum PaneSlot: CaseIterable, Hashable {
    case loupe
    case compareLeft
    case compareRight
}

/// A full-size decode bound to the asset it belongs to. Views render `image` only
/// when `id` matches the pane's expected asset; otherwise they fall back to the
/// id-keyed enrichment thumbnail. That identity check is what makes stale decodes
/// harmless — no generation counters required.
nonisolated struct PanePreview: Equatable {
    let id: MediaAssetID
    let image: CGImage
    let mediaChoice: MediaChoice?

    init(id: MediaAssetID, image: CGImage, mediaChoice: MediaChoice? = nil) {
        self.id = id
        self.image = image
        self.mediaChoice = mediaChoice
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.image === rhs.image && lhs.mediaChoice == rhs.mediaChoice
    }
}
