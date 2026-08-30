import Foundation
@testable import OtosKit
import Testing

/// A video's filesystem mtime is when recording *stopped*, so a clip named from it
/// is wrong by its own length. Where no local-authority embedded timestamp exists —
/// 100% of two roots' videos in one production catalog — the capture instant is
/// still computable: `mtime − duration` (plan 0099 D7/O7).
struct DerivedVideoCaptureWallTests {
    private let zone = TimeZone(secondsFromGMT: 0) ?? .current
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    @Test func derivesTheInstantRecordingStarted() throws {
        // Recording stopped at 2026-04-26 15:01:52 after 17 seconds.
        let stopped = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 4, day: 26, hour: 15, minute: 1, second: 52
        )))
        let selection = try #require(CaptureWallClock.derivedFromDuration(
            modifiedAt: stopped,
            durationSeconds: 17,
            calendar: calendar,
            timeZone: zone
        ))
        #expect(selection.compact == 20_260_426_150_135)
        #expect(selection.precision == CaptureWallClock.derivedFromDurationPrecision)
    }

    @Test func refusesToDeriveWithoutBothFacts() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(CaptureWallClock.derivedFromDuration(modifiedAt: nil, durationSeconds: 17) == nil)
        #expect(CaptureWallClock.derivedFromDuration(modifiedAt: now, durationSeconds: nil) == nil)
        // A zero or nonsensical duration derives nothing: a fabricated date is worse
        // than none, and the planner already blocks an entry it cannot name.
        #expect(CaptureWallClock.derivedFromDuration(modifiedAt: now, durationSeconds: 0) == nil)
        #expect(CaptureWallClock.derivedFromDuration(modifiedAt: now, durationSeconds: .infinity) == nil)
    }

    /// The design's hard edge. The derivation is `mtime − duration`, so stamping the
    /// destination with the derived wall would make the copy's own mtime that value;
    /// enriching the copy would derive `wall − duration` again and drift by one
    /// duration per import generation. Overlay reuse cannot prevent it either —
    /// `settleImport` short-circuits reuse for `.removableVolume` sources, so the copy
    /// is enriched afresh. Stamping the source's real mtime instead is idempotent.
    @Test func aDerivedWallNamesTheFileButDoesNotStampIt() throws {
        let stopped = Date(timeIntervalSince1970: 1_700_000_017)
        let derived = try #require(CaptureWallClock.derivedFromDuration(
            modifiedAt: stopped,
            durationSeconds: 17,
            calendar: calendar,
            timeZone: zone
        ))
        let facts = PlanningFileFacts(
            id: MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/Volumes/Card"),
                relativePath: MediaRelativePath(rawValue: "clip.mov")
            ),
            sourceURL: URL(fileURLWithPath: "/Volumes/Card/clip.mov"),
            relativePath: MediaRelativePath(rawValue: "clip.mov"),
            byteSize: 1024,
            contentModifiedAt: stopped,
            captureWallCompact: derived.compact,
            captureWallPrecision: derived.precision,
            namingFactState: .terminal,
            mediaKind: .video,
            fileExtension: "mov",
            companions: [],
            contentTypeIdentifier: "public.mpeg-4"
        )
        // Stamped with the source's real mtime, so the copy reproduces the same
        // derivation instead of drifting one duration further each generation.
        #expect(ImportDestinationDate.expected(for: facts) == stopped)
    }

    /// An *embedded* wall still stamps, unchanged — only the derived one is withheld.
    @Test func anEmbeddedWallStillStampsTheDestination() {
        let compact: Int64 = 20_260_426_145_735
        let facts = PlanningFileFacts(
            id: MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/Volumes/Card"),
                relativePath: MediaRelativePath(rawValue: "still.jpg")
            ),
            sourceURL: URL(fileURLWithPath: "/Volumes/Card/still.jpg"),
            relativePath: MediaRelativePath(rawValue: "still.jpg"),
            byteSize: 1024,
            contentModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            captureWallCompact: compact,
            captureWallPrecision: "localFloating",
            namingFactState: .terminal,
            mediaKind: .image,
            fileExtension: "jpg",
            companions: [],
            contentTypeIdentifier: "public.jpeg"
        )
        #expect(ImportDestinationDate.expected(for: facts) == CaptureWallClock.date(fromCompact: compact))
    }
}
