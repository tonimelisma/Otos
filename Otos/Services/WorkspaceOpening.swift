import AppKit
import Foundation

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
    /// Apps able to open `url`, best match first. Empty when the file does not exist.
    /// A dataless cloud placeholder exists, so it answers without a byte read.
    func applicationURLs(toOpen url: URL) -> [URL]
    /// The app a Finder double-click would use for `url`, or nil when none is registered.
    func defaultApplicationURL(toOpen url: URL) -> URL?
    /// The user-facing name of the app bundle at `url`, extension stripped.
    func displayName(forApplicationAt url: URL) -> String
    /// One launch-services call for the whole list; the app decides how to present it.
    func open(_ urls: [URL], withApplicationAt applicationURL: URL) async throws
}

/// The production conformer over `NSWorkspace.shared`. Its query methods are
/// thread-safe per AppKit and are called from the menu builder's `@concurrent` function, off the MainActor.
nonisolated struct LaunchServicesWorkspace: WorkspaceOpening {
    func applicationURLs(toOpen url: URL) -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: url)
    }

    func defaultApplicationURL(toOpen url: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    func displayName(forApplicationAt url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
    }

    func open(_ urls: [URL], withApplicationAt applicationURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        _ = try await NSWorkspace.shared.open(urls, withApplicationAt: applicationURL, configuration: configuration)
    }
}
