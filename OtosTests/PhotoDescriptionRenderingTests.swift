import AppKit
import Foundation
@testable import OtosKit
import SwiftUI
import Testing

/// The Info pane's Description section in each state (DES-088, APP-077) and an On This Day
/// card with and without its title (DES-112, APP-078), rendered in light and dark as the design
/// check's screenshots (DES-022), into `build/DesignEvidence/photo-description/` of the checkout
/// that ran the test, for review.
@MainActor
struct PhotoDescriptionRenderingTests {
    private static func evidenceDirectory() -> URL {
        SourceTree.root.appending(path: "build/DesignEvidence/photo-description", directoryHint: .isDirectory)
    }

    private static let still = MediaAssetID(
        libraryRootPath: LibraryRootPath(rawValue: "/Lib"), relativePath: MediaRelativePath(rawValue: "IMG_0001.HEIC")
    )

    private static let states: [(String, PhotoDescriptionReading?, PhotoDescriptionAvailability)] = [
        ("written", .written(
            "Jamie lifts Tyler high under a wide summer hat, both of them grinning by the garden fence. "
                + "Tyler's patterned onesie and Jamie's sunglasses make it look like a day made for the outdoors."
        ), .available),
        ("declined", .declined, .available),
        ("owed", nil, .available),
        ("off", nil, .appleIntelligenceOff),
    ]

    @Test func everyDescriptionStateRenders() throws {
        let directory = Self.evidenceDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, reading, availability) in Self.states {
            let info = PhotoInfo.make(PhotoInfo.Source(
                id: Self.still,
                overlay: PhotoInfoOverlay(companionFileNames: [], importedAt: nil, isEdited: false, photoDescription: reading),
                kind: .image,
                descriptionAvailability: availability
            ))
            for scheme in [ColorScheme.light, .dark] {
                // The inspector's own background, as the window draws it behind the pane.
                let view = InfoPaneView(info: info, people: nil, search: { _ in })
                    .frame(width: 300, height: 360)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme)
                try Self.write(view, scheme: scheme, to: directory.appending(path: "info-\(name)-\(Self.name(scheme)).png"))
            }
        }
    }

    @Test func aCardRendersWithAndWithoutItsTitle() throws {
        let directory = Self.evidenceDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let today = CalendarDay(year: 2026, month: 11, day: 14)
        let day = CalendarDay(year: 2023, month: 11, day: 14)
        let onThisDay = CatalogOnThisDayState(
            day: today,
            anniversaries: [OnThisDayAnniversary(day: day, keyItem: Self.still, firstIndex: 0, count: 14)]
        )
        for (name, titles) in [("untitled", [CalendarDay: String]()), ("titled", [day: "Berry Picking at the Cottage"])] {
            for scheme in [ColorScheme.light, .dark] {
                let view = OnThisDayView(
                    onThisDay: onThisDay, today: today, emptyState: nil, focusRequest: nil, titles: titles, play: { _ in }
                )
                .environment(\.colorScheme, scheme)
                .frame(width: 480, height: 360)
                try Self.write(view, scheme: scheme, to: directory.appending(path: "card-\(name)-\(Self.name(scheme)).png"))
            }
        }
    }

    private static func name(_ scheme: ColorScheme) -> String {
        scheme == .dark ? "dark" : "light"
    }

    private static func write(_ view: some View, scheme: ColorScheme, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}
