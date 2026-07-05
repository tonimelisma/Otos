import CoreGraphics
import Foundation

// Pure tile presentation guide
//
// These helpers keep content-type, fallback-title, capture-date, overlay geometry,
// and thumbnail-load policy independent from reusable AppKit view state. The AppKit
// tile calls into this file, and tests assert these value-level decisions directly.

struct LoadedTile {
    let image: CGImage?
    let pixelSize: CGSize?
}

nonisolated struct MediaAssetTileTextScrimFrames: Equatable {
    let scrim: CGRect
    let title: CGRect
    let date: CGRect?
}

nonisolated enum MediaAssetTileLayout {
    static let contentCornerRadius: CGFloat = 4
    static let scrimCornerRadius: CGFloat = 3
    static let overlayInset: CGFloat = 0
    static let scrimPaddingX: CGFloat = 5
    static let scrimPaddingY: CGFloat = 4
    static let titleHeight: CGFloat = 14
    static let dateHeight: CGFloat = 12
    static let lineGap: CGFloat = 1
    static let badgeHeight: CGFloat = 20
    static let badgeMinWidth: CGFloat = 22
    static let filmIconSize: CGFloat = 13

    static func textScrimFrames(
        contentBounds: CGRect,
        titleTextWidth: CGFloat,
        dateTextWidth: CGFloat,
        showsDate: Bool
    ) -> MediaAssetTileTextScrimFrames? {
        let availableWidth = max(contentBounds.width - overlayInset * 2, 0)
        let availableHeight = max(contentBounds.height - overlayInset * 2, 0)
        guard availableWidth > 0, availableHeight > 0 else {
            return nil
        }

        let measuredTextWidth = ceil(max(titleTextWidth, showsDate ? dateTextWidth : 0))
        let scrimWidth = min(max(1, measuredTextWidth + scrimPaddingX), availableWidth)
        let desiredHeight = titleHeight
            + (showsDate ? lineGap + dateHeight : 0)
            + scrimPaddingY
        let scrimHeight = min(desiredHeight, availableHeight)
        guard scrimWidth > 0, scrimHeight > 0 else {
            return nil
        }

        let lineWidth = max(scrimWidth - scrimPaddingX, 0)
        let title = CGRect(x: 0, y: 0, width: lineWidth, height: titleHeight)
        let date = showsDate
            ? CGRect(x: 0, y: titleHeight + lineGap, width: lineWidth, height: dateHeight)
            : nil
        return MediaAssetTileTextScrimFrames(
            scrim: CGRect(x: overlayInset, y: overlayInset, width: scrimWidth, height: scrimHeight),
            title: title,
            date: date
        )
    }

    static func videoBadgeFrame(
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
}

nonisolated struct MediaAssetTileOverlayVisibility: Equatable {
    let showsDate: Bool
    let showsVideoBadge: Bool
}

nonisolated struct TilePaintContext {
    let incomingKey: String
    let incomingThumbnailPath: String?
    let currentKey: String?
    let currentAssetID: MediaAssetID?
    let incomingAssetID: MediaAssetID
    let cacheHasImage: Bool
    let hasPaintedImage: Bool
}

nonisolated enum TilePaintDecision: Equatable {
    case paintCached
    case keepCurrent
    case loadAsync(retainsCurrentImage: Bool)
    case placeholder
}

enum MediaAssetTilePresentation {
    static func isVideo(_ asset: MediaAsset) -> Bool {
        asset.bestKind == .video
    }

    static func title(_ asset: MediaAsset) -> String {
        if let name = asset.name {
            return name
        }
        return URL(fileURLWithPath: asset.relativePath.rawValue).lastPathComponent
    }

    /// Empty when nothing is known; never a fabricated capture date.
    nonisolated static func captureDateText(_ asset: MediaAsset) -> String {
        guard let date = asset.bestCaptureDate else {
            return ""
        }
        return RelativeDateText.string(for: date)
    }

    nonisolated static func captureDateText(
        _ asset: MediaAsset,
        now: Date,
        calendar: Calendar
    ) -> String {
        guard let date = asset.bestCaptureDate else {
            return ""
        }
        return RelativeDateText.string(for: date, now: now, calendar: calendar)
    }

    nonisolated static func videoBadgeText(_ asset: MediaAsset) -> String? {
        guard showsVideoBadge(asset),
              let durationSeconds = asset.durationSeconds,
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

    nonisolated static func showsVideoBadge(_ asset: MediaAsset) -> Bool {
        asset.bestKind == .video
    }

    nonisolated static func contentRect(imagePixelSize: CGSize?, bounds: CGRect) -> CGRect {
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

    nonisolated static func overlayVisibility(contentRect: CGRect) -> MediaAssetTileOverlayVisibility {
        MediaAssetTileOverlayVisibility(
            showsDate: contentRect.width >= 44 && contentRect.height >= 31,
            showsVideoBadge: contentRect.width >= 56 && contentRect.height >= 56
        )
    }

    nonisolated static func paintDecision(_ context: TilePaintContext) -> TilePaintDecision {
        if context.cacheHasImage {
            return .paintCached
        }
        if context.incomingKey == context.currentKey {
            return .keepCurrent
        }
        let sameIdentity = context.currentAssetID == context.incomingAssetID
        if context.incomingThumbnailPath == nil {
            return sameIdentity && context.hasPaintedImage ? .keepCurrent : .placeholder
        }
        return .loadAsync(retainsCurrentImage: sameIdentity && context.hasPaintedImage)
    }

    /// Thumbnail path plus source stamp; overlay-only updates do not change image identity.
    nonisolated static func imageContentKey(_ asset: MediaAsset) -> String {
        let thumbnail = asset.thumbnailPath ?? ""
        let size = asset.enrichedSourceSize ?? -1
        let stamp = asset.enrichedSourceMTimeSeconds ?? -1
        return "\(thumbnail)#\(size)#\(stamp)"
    }

    nonisolated static func decodedThumbnailImage(asset: MediaAsset, thumbnailDirectory: URL?) -> CGImage? {
        loadImage(asset: asset, thumbnailDirectory: thumbnailDirectory).image
    }

    nonisolated static func loadImage(asset: MediaAsset, thumbnailDirectory: URL?) -> LoadedTile {
        let image = asset.thumbnailPath.flatMap { name in
            thumbnailDirectory.flatMap { ThumbnailStore.load(name, in: $0) }
        }
        return LoadedTile(
            image: image,
            pixelSize: image.map { CGSize(width: CGFloat($0.width), height: CGFloat($0.height)) }
        )
    }
}
