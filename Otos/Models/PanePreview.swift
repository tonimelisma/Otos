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
    /// The source's native pixel size when the decode reported one; the loupe sizes its
    /// zoom document from it so 100 percent means native pixels even while the held
    /// `image` is the fit-size decode (APP-040).
    let nativePixelSize: CGSize?
    /// The edit revision the decode shows (ADR 0036): the detail's rendered revision when
    /// it was requested. A live edit render stays on screen until this reaches its save.
    let renderedRevision: Int64

    init(
        id: MediaAssetID,
        image: CGImage,
        mediaChoice: MediaChoice? = nil,
        nativePixelSize: CGSize? = nil,
        renderedRevision: Int64 = 0
    ) {
        self.id = id
        self.image = image
        self.mediaChoice = mediaChoice
        self.nativePixelSize = nativePixelSize
        self.renderedRevision = renderedRevision
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.image === rhs.image && lhs.mediaChoice == rhs.mediaChoice
            && lhs.nativePixelSize == rhs.nativePixelSize && lhs.renderedRevision == rhs.renderedRevision
    }
}
