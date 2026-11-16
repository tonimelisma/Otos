import Foundation

/// The plan the confirmation dialog shows. Confirming runs exactly this library at
/// exactly this revision (`LibraryReorganizationRunner.run(libraryRoot:confirmedRevision:)`),
/// whatever the sidebar selects by then.
struct ReorganizationConfirmation: Equatable {
    let libraryRoot: LibraryRootPath
    let rootRevision: UInt64
    let summaryText: String

    init(summary: LibraryReorganizationRunner.ReorganizationPlanSummary) {
        libraryRoot = summary.libraryRoot
        rootRevision = summary.rootRevision
        summaryText = ReorganizationSummaryPresentation.string(for: summary)
    }
}

/// Pure display mapper for `LibraryReorganizationRunner.ReorganizationPlanSummary`,
/// beside `ContentView`'s confirmation dialog the same way `ImportBarPresentation`
/// sits beside `ImportPlanFooter`: the runner reports typed counts, this is the one
/// place that turns them into the dialog's message (complete sentences, DES-037; DES-035 user
/// vocabulary — never the planner's own "relocate"/"no-op"/"components" words).
/// `noOpCount` and `componentCount` are not decision-relevant to the user
/// confirming a reorganization and are intentionally left out.
enum ReorganizationSummaryPresentation {
    static func string(for summary: LibraryReorganizationRunner.ReorganizationPlanSummary) -> String {
        guard summary.blockedCount > 0 else {
            return "\(summary.relocateCount) items will be renamed or moved."
        }
        return "\(summary.relocateCount) items will be renamed or moved. \(summary.blockedCount) can’t be processed."
    }
}

/// The alert a reorganization that could not start or stopped partway shows: one value,
/// so its title and message always describe the same outcome.
nonisolated struct ReorganizationAlert: Equatable, Sendable {
    let title: String
    let message: String
}

/// The alert text for a reorganization that could not start or stopped partway, in the
/// user's vocabulary (DES-035): items, files and folders, never journal, component or
/// lease. The runner's typed outcome is the only input; its log code stays in the log.
/// Each title is a fragment saying what happened, so it takes title case and no ending
/// punctuation (DES-037).
nonisolated enum ReorganizationOutcomePresentation {
    static func alert(for reason: ReorganizationUnavailability) -> ReorganizationAlert {
        ReorganizationAlert(title: "Couldn’t Reorganize Library", message: message(for: reason))
    }

    static func alert(for stop: ReorganizationStop) -> ReorganizationAlert {
        ReorganizationAlert(title: "Reorganization Stopped", message: message(for: stop))
    }

    private static func message(for reason: ReorganizationUnavailability) -> String {
        switch reason {
        case let .libraryBusy(owner):
            switch owner {
            case .importPublication, .sourceErase:
                "This library is busy with an import. Try again when it finishes."
            case .mediaTrash:
                "This library is busy moving items to the Trash. Try again when it finishes."
            case .reorganization:
                "This library is already being reorganized."
            case .libraryRemoval:
                "This library is being removed from Otos."
            }
        case .libraryUnavailable:
            "This library is no longer in Otos."
        case .catalogUnreadable:
            "Otos couldn’t read this library’s catalog, so nothing was changed."
        case .planInconsistent:
            "Otos couldn’t work out the new names for this library, so nothing was changed."
        }
    }

    private static func message(for stop: ReorganizationStop) -> String {
        let relocated = stop.progress.relocatedCount
        let stopped = switch relocated {
        case 0: "No item moved because \(cause(stop.fault))."
        case 1: "1 item was reorganized before it stopped because \(cause(stop.fault))."
        default: "\(relocated) items were reorganized before it stopped because \(cause(stop.fault))."
        }
        let remainder = stop.libraryRestored
            ? "The other items were left as they were."
            : "Some files couldn’t be moved back. Otos will try again the next time it opens."
        return "\(stopped) \(remainder)"
    }

    private static func cause(_ fault: ReorganizationFault) -> String {
        switch fault {
        case .journalWrite:
            "the catalog couldn’t be updated"
        case let .folderUnavailable(path):
            "a folder couldn’t be created at “\(path.rawValue)”"
        case let .destinationTaken(path):
            "another file is already at “\(path.rawValue)”"
        case let .moveRefused(path):
            "“\(path.rawValue)” couldn’t be moved"
        case let .fileChanged(path):
            "“\(path.rawValue)” changed while it was being moved"
        case .libraryChanged:
            "the library changed while it was being reorganized"
        }
    }
}
