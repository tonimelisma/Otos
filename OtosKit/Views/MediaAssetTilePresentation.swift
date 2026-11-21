import AppKit
import CoreGraphics
import Foundation

// Pure tile presentation guide
//
// These helpers keep kind-badge policy, placeholder glyph selection (loading vs
// broken-media slash icons), thumbnail face geometry, and thumbnail-load policy
// independent from reusable AppKit view state. The AppKit tile calls into this
// file, and tests assert these value-level decisions directly. Lower-right badges
// appear only after a real thumbnail has painted; broken/unavailable tiles never
// show a corner badge. Accessibility is derived from detail + badge content so
// loading placeholders keep kind labels for VoiceOver.

struct LoadedTile {
    let image: DisplayImage?
    let pixelSize: CGSize?
}

/// Lower-right shaded badge content for a painted tile face.
nonisolated enum TileBadgeContent: Equatable {
    case none
    case durationText(String)
    case filmIcon
    case rawLabel
    /// A stack's badge (DES-116): a member's own file type on an expanded pair, the number of
    /// photos on a burst. A collapsed pair is one photo and has none. It is the stack's
    /// expand-and-collapse control.
    case stackLabel(String)
}

/// How a tile shows the stacks it is in (ADR 0052, DES-116): the badge that is its stacks'
/// expand-and-collapse control, whether it sits on an expanded stack's band, and whether it
/// is that stack's key, outlined.
nonisolated struct TileStackPresentation: Equatable {
    var badgeLabel: String?
    var onBand = false
    var isKey = false
    /// What VoiceOver says for the badge: the label, except a burst's count, which the
    /// suffix says in words.
    var spokenBadge: String?
    /// What VoiceOver adds after the tile's own description.
    var accessibilitySuffix = ""

    static let none = TileStackPresentation()

    /// The stack presentation `stacks` gives the tile showing `id`. A collapsed burst wins
    /// over the pair its shown frame is, since the tile stands for the whole burst; on an
    /// expanded burst's band, a frame that is a pair shows the pair's own badge.
    static func of(_ id: MediaAssetID, in stacks: CatalogGridStacks) -> TileStackPresentation {
        guard let tile = stacks.tiles[id] else { return .none }
        var presentation = TileStackPresentation()
        presentation.onBand = tile.expanded != nil
        if let collapsed = tile.collapsed {
            switch collapsed.id.kind {
            case .pair:
                // A RAW and its processed file are one photo, unmarked, as Lightroom shows
                // them (owner, 2026-11-19: "let's not mark the pairs at all"); the loupe's and
                // the edit panel's switch tell the files apart (DES-117).
                break
            case .burst:
                presentation.badgeLabel = collapsed.label
                presentation.accessibilitySuffix = ", burst of \(collapsed.photos.count) photos"
            }
        } else if let pair = tile.pair, tile.pairExpanded {
            presentation.badgeLabel = pair.label(of: id)
            presentation.spokenBadge = presentation.badgeLabel
        } else if let burst = tile.burst, tile.burstExpanded, burst.key == id {
            // An expanded burst's key frame keeps the count: the badge that collapses it.
            presentation.badgeLabel = burst.label
        }
        if let expanded = tile.expanded {
            presentation.isKey = expanded.key == id
            presentation.accessibilitySuffix += presentation.isKey
                ? ", in an expanded stack, key photo" : ", in an expanded stack"
        }
        return presentation
    }
}

extension PhotoStack {
    /// A member's own badge, and its segment in the `JPG`/`RAW` switch (DES-116, DES-117):
    /// `RAW` for a RAW file, else the file's own extension (`JPG`, `HEIC`), so the user can
    /// tell the files apart.
    nonisolated func label(of member: MediaAssetID) -> String {
        isRaw(member) ? "RAW" : member.relativePath.fileExtension.uppercased()
    }

    /// A collapsed burst's badge (DES-116): the number of photos.
    nonisolated var label: String {
        "\(photos.count)"
    }
}

nonisolated enum MediaAssetTileLayout {
    static let contentCornerRadius: CGFloat = 4
    static let badgeCornerRadius: CGFloat = 3
    static let badgeHorizontalPadding: CGFloat = 5
    static let badgeHeight: CGFloat = 20
    static let badgeMinWidth: CGFloat = 22
    static let badgeTextY: CGFloat = 3
    static let badgeTextHeight: CGFloat = 14
    static let filmIconSize: CGFloat = 13
    static let placeholderIconAlpha: CGFloat = 0.35
    static let placeholderIconMinSide: CGFloat = 16
    static let placeholderIconMaxSide: CGFloat = 40
    static let rawLabel = "RAW"
    /// DES-067 floor: every curation act stays individually targetable at the
    /// smallest configured filmstrip size.
    static let choiceButtonSize: CGFloat = 28
    static let choiceButtonSpacing: CGFloat = 1
    /// Margin from the thumbnail's own corner. Matches `kindBadge`'s inset on the
    /// opposite corner so the two overlays read as one system.
    static let choiceGroupInset: CGFloat = 4

    /// A quarter of the shorter content dimension, clamped to a legible range — big
    /// enough to read as a deliberate kind indicator on a small tile, small enough to
    /// stay a quiet placeholder rather than a dominant glyph.
    static func placeholderIconSide(contentBounds: CGRect) -> CGFloat {
        let side = min(contentBounds.width, contentBounds.height) / 4
        return min(max(side, placeholderIconMinSide), placeholderIconMaxSide)
    }

    static func placeholderIconFrame(contentBounds: CGRect) -> CGRect {
        let side = placeholderIconSide(contentBounds: contentBounds)
        return CGRect(
            x: (contentBounds.width - side) / 2,
            y: (contentBounds.height - side) / 2,
            width: side,
            height: side
        )
    }

    static func kindBadgeFrame(
        contentBounds: CGRect,
        badgeWidth: CGFloat,
        badgeHeight: CGFloat = badgeHeight
    ) -> CGRect? {
        guard contentBounds.width >= badgeWidth,
              contentBounds.height >= badgeHeight
        else {
            return nil
        }
        return CGRect(
            x: contentBounds.width - badgeWidth,
            y: contentBounds.height - badgeHeight,
            width: badgeWidth,
            height: badgeHeight
        )
    }

    static func kindBadgeWidth(textWidth: CGFloat?) -> CGFloat {
        guard let textWidth else {
            return badgeMinWidth
        }
        return max(
            badgeMinWidth,
            ceil(textWidth) + badgeHorizontalPadding * 2
        )
    }

    /// Centers the measured text within the badge. When the min-width clamp wins,
    /// the label is still centered on the actual text width rather than inset by
    /// the fixed padding alone.
    static func kindBadgeLabelFrame(badgeWidth: CGFloat, textWidth: CGFloat) -> CGRect {
        let clampedTextWidth = min(max(ceil(textWidth), 0), badgeWidth)
        let originX = max((badgeWidth - clampedTextWidth) / 2, 0)
        return CGRect(
            x: originX,
            y: badgeTextY,
            width: clampedTextWidth,
            height: badgeTextHeight
        )
    }
}

nonisolated enum MediaAssetTilePresentation {
    static func isVideo(_ detail: MediaTileDetail) -> Bool {
        detail.bestKind == .video
    }

    /// Formats known finite video duration for the lower-right badge.
    static func videoBadgeText(_ detail: MediaTileDetail) -> String? {
        guard detail.bestKind == .video,
              let durationSeconds = detail.durationSeconds,
              durationSeconds.isFinite
        else {
            return nil
        }
        let wholeSeconds = max(0, Int64(durationSeconds.rounded(.down)))
        let duration = Duration.seconds(wholeSeconds)
        if wholeSeconds >= 3600 {
            return duration.formatted(.time(pattern: .hourMinuteSecond))
        }
        return duration.formatted(.time(pattern: .minuteSecond))
    }

    /// Lower-right badge policy. Broken / not-yet-enriched tiles never get a
    /// badge; painted video shows duration or a film-icon fallback; painted raw
    /// shows `RAW`. `thumbnailUnavailable` is an explicit gate so a future paint
    /// of non-thumbnail content cannot resurrect badges on broken tiles.
    static func badgeContent(
        detail: MediaTileDetail,
        thumbnailPainted: Bool,
        formattedDuration: String? = nil,
        stack: TileStackPresentation = .none
    ) -> TileBadgeContent {
        guard thumbnailPainted, !detail.thumbnailUnavailable else {
            return .none
        }
        if let label = stack.badgeLabel {
            return .stackLabel(label)
        }
        switch detail.bestKind {
        case .video:
            if let text = formattedDuration ?? videoBadgeText(detail) {
                return .durationText(text)
            }
            return .filmIcon
        case .raw:
            return .rawLabel
        case .image, .none:
            return .none
        }
    }

    /// Accessibility for the whole tile: filename first — it is the only thing that
    /// distinguishes one tile from another, and a grid where every element announces
    /// "Image" is not navigable — then kind and state. The filename is derived from
    /// `MediaTileDetail.relativePath`, which the tile already holds, so this adds no
    /// query and does not widen `MediaTileDetail` (ENR-005).
    static func accessibilityLabel(
        detail: MediaTileDetail,
        badgeContent: TileBadgeContent,
        stack: TileStackPresentation = .none
    ) -> String {
        let name = detail.relativePath.fileName
        let base: String = if detail.thumbnailUnavailable {
            detail.bestKind == .video
                ? "\(name), video, preview unavailable"
                : "\(name), image, preview unavailable"
        } else {
            switch badgeContent {
            case let .durationText(text): "\(name), video, \(text)"
            case .filmIcon: "\(name), video"
            case .rawLabel: "\(name), RAW image"
            case .stackLabel: stack.spokenBadge.map { "\(name), \($0)" } ?? name
            case .none:
                switch detail.bestKind {
                case .video: "\(name), video"
                case .raw: "\(name), RAW image"
                case .image: "\(name), image"
                case .none: name
                }
            }
        }
        let stackSuffix = stack.accessibilitySuffix
        let editedSuffix = isEdited(detail) ? ", edited" : ""
        let emptySuffix = detail.byteSize == 0 ? ", empty file" : ""
        return "\(base)\(stackSuffix)\(editedSuffix)\(emptySuffix), \(detail.mediaChoice.accessibilityValue)"
    }

    static func accessibilityValue(detail: MediaTileDetail) -> String {
        detail.mediaChoice.accessibilityValue
    }

    /// SF Symbol for the centered placeholder glyph. Loading uses kind glyphs
    /// (`r.square` for RAW); broken uses slash "unavailable" grammar. No spinner.
    static func placeholderIconSystemName(
        for kind: MediaKind?,
        thumbnailUnavailable: Bool
    ) -> String {
        if thumbnailUnavailable {
            return kind == .video ? "video.slash" : "photo.slash"
        }
        switch kind {
        case .video:
            return "film"
        case .raw:
            return "r.square"
        case .image, .none:
            return "photo"
        }
    }

    /// Cached SF Symbol image for placeholder tiles. `NSImage(systemSymbolName:)` creates
    /// a new image per call; resolve once per name and reuse. Main-actor confined —
    /// tiles are `@MainActor` AppKit views.
    @MainActor
    static func placeholderIcon(
        for kind: MediaKind?,
        thumbnailUnavailable: Bool = false
    ) -> NSImage? {
        let name = placeholderIconSystemName(for: kind, thumbnailUnavailable: thumbnailUnavailable)
        if let cached = placeholderIconCache[name] {
            return cached
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        placeholderIconCache[name] = image
        return image
    }

    @MainActor
    private static var placeholderIconCache: [String: NSImage?] = [:]

    /// The selection outline's width, on a grid tile and on Compare's active pane alike
    /// (DES-061): one mark for "this is what the commands act on".
    static let selectionBorderWidth: CGFloat = 3

    static func contentRect(imagePixelSize: CGSize?, bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        guard let imagePixelSize,
              imagePixelSize.width > 0,
              imagePixelSize.height > 0
        else {
            return bounds.integral
        }
        let scale = min(bounds.width / imagePixelSize.width, bounds.height / imagePixelSize.height)
        let fittedWidth = min(bounds.width, max(1, (imagePixelSize.width * scale).rounded()))
        let fittedHeight = min(bounds.height, max(1, (imagePixelSize.height * scale).rounded()))
        return CGRect(
            x: bounds.minX + ((bounds.width - fittedWidth) / 2).rounded(),
            y: bounds.minY + ((bounds.height - fittedHeight) / 2).rounded(),
            width: fittedWidth,
            height: fittedHeight
        )
    }

    /// The hover curation group's frame, in tile coordinates.
    ///
    /// Anchored inside the *thumbnail face* — `contentRect`, the aspect-fit image
    /// the user actually sees — at its upper-left corner plus one margin, so the
    /// group sits on the photo rather than out in the cell's letterbox (DES-066).
    /// Taking the face as a parameter rather than reading a view keeps the
    /// placement a pure function the layout can be tested against.
    static func choiceGroupRect(buttonCount: Int, contentRect: CGRect) -> CGRect {
        let count = CGFloat(max(0, buttonCount))
        let size = MediaAssetTileLayout.choiceButtonSize
        let spacing = MediaAssetTileLayout.choiceButtonSpacing
        let inset = MediaAssetTileLayout.choiceGroupInset
        return CGRect(
            x: contentRect.minX + inset,
            y: contentRect.minY + inset,
            width: size * count + spacing * max(0, count - 1),
            height: count > 0 ? size : 0
        )
    }

    /// The aspect-fit thumbnail face inside `bounds`, used for both rendering and mouse
    /// hit-testing. For a not-yet-decoded placeholder (`imagePixelSize == nil`) the face is
    /// the full bounds, so the whole tile remains selectable.
    static func thumbnailFaceRect(imagePixelSize: CGSize?, bounds: CGRect) -> CGRect {
        contentRect(imagePixelSize: imagePixelSize, bounds: bounds)
    }

    /// Size gate for any lower-right badge content (duration, film icon, RAW).
    /// A photo or video with a saved edit carries the edited mark (DES-099).
    static func isEdited(_ detail: MediaTileDetail) -> Bool {
        detail.editRecipe.map { !$0.isNeutral } ?? false
    }

    static func showsKindBadge(contentRect: CGRect) -> Bool {
        contentRect.width >= 56 && contentRect.height >= 56
    }

    /// Thumbnail path plus rendering stamp; badge updates do not change image identity.
    static func imageContentKey(_ detail: MediaTileDetail) -> String {
        let thumbnail = detail.thumbnailPath ?? ""
        let size = detail.renderedSourceSize ?? -1
        let stamp = detail.renderedSourceMTimeSeconds ?? -1
        // A saved edit re-renders the thumbnail under the same name; its revision is
        // what tells a tile the image changed (ADR 0036).
        return "\(thumbnail)#\(size)#\(stamp)#\(detail.renderedRevision)"
    }

    static func decodedThumbnailImage(detail: MediaTileDetail, thumbnailDirectory: URL?) -> DisplayImage? {
        loadImage(detail: detail, thumbnailDirectory: thumbnailDirectory).image
    }

    static func loadImage(detail: MediaTileDetail, thumbnailDirectory: URL?) -> LoadedTile {
        let image = detail.thumbnailPath.flatMap { name in
            thumbnailDirectory.flatMap { ThumbnailStore.load(name, in: $0) }
        }
        return LoadedTile(
            image: image,
            pixelSize: image.map { CGSize(width: CGFloat($0.width), height: CGFloat($0.height)) }
        )
    }
}
