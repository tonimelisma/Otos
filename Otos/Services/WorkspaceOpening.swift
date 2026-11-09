import AppKit
import Foundation
import UniformTypeIdentifiers

/// Workspace opening boundary guide
///
/// The one seam between Otos and LaunchServices for "open these files in that app".
/// Every method takes and returns file URLs and app URLs only: Otos reads no media
/// bytes here, requests no materialization, and never learns whether the receiving
/// app downloaded a dataless cloud original — that download is the receiver's own
/// act on a file the user named, the same rule ⌘C works under (ADR 0012).
///
/// It is a protocol because tests substitute a recorder for LaunchServices; the app
/// has exactly one conformer.
nonisolated protocol WorkspaceOpening: Sendable {
    /// Apps able to open `url`, best match first. A dataless cloud placeholder exists, so
    /// it answers without a byte read. A file not on disk yet — a staged original Otos has
    /// not copied, which a hand-off fetches first (ADR 0046 §4) — answers by its file type.
    func applicationURLs(toOpen url: URL) -> [URL]
    /// The app a Finder double-click would use for `url`, or nil when none is registered;
    /// by its file type while the file is not on disk yet.
    func defaultApplicationURL(toOpen url: URL) -> URL?
    /// The user-facing name of the app bundle at `url`, extension stripped.
    func displayName(forApplicationAt url: URL) -> String
    /// One launch-services call for the whole list; the app decides how to present it.
    func open(_ urls: [URL], withApplicationAt applicationURL: URL) async throws
    /// Shows `urls` selected in Finder. Passes URLs only, so a dataless original is
    /// never materialized; a staged original not copied yet is fetched by the hand-off
    /// lane before it gets here (ADR 0046 §4).
    func revealInFinder(_ urls: [URL])
}

/// The production conformer over `NSWorkspace.shared`. Its query methods are
/// thread-safe per AppKit and are called from the menu builder's `@concurrent` function, off the MainActor.
nonisolated struct LaunchServicesWorkspace: WorkspaceOpening {
    func applicationURLs(toOpen url: URL) -> [URL] {
        if let type = Self.typeOfAbsentFile(url) {
            return NSWorkspace.shared.urlsForApplications(toOpen: type)
        }
        return NSWorkspace.shared.urlsForApplications(toOpen: url)
    }

    func defaultApplicationURL(toOpen url: URL) -> URL? {
        if let type = Self.typeOfAbsentFile(url) {
            return NSWorkspace.shared.urlForApplication(toOpen: type)
        }
        return NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    /// LaunchServices answers nothing for a path with no file, so one is asked about by
    /// the type its extension names; nil when the file exists and answers for itself.
    private static func typeOfAbsentFile(_ url: URL) -> UTType? {
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }
        return UTType(filenameExtension: url.pathExtension)
    }

    func displayName(forApplicationAt url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
    }

    func open(_ urls: [URL], withApplicationAt applicationURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        _ = try await NSWorkspace.shared.open(urls, withApplicationAt: applicationURL, configuration: configuration)
    }

    func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
