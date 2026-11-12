@testable import OtosKit
import Testing

/// The capability table in ADR 0046 §3, as the code answers it. Each row is a question
/// callers ask instead of comparing kinds; a change to any answer changes which roots a
/// scope spans, which roots an import reads or writes, or whether Move to Trash applies,
/// so the whole table is stated here once.
struct LibraryRootKindCapabilityTests {
    private struct Row: Equatable, CustomStringConvertible {
        let userChosenFolder: Bool
        let librariesSection: Bool
        let allMedia: Bool
        let importDestination: Bool
        let removable: Bool
        let filesystemNamespace: Bool
        let moveToTrash: Bool
        let sourceListing: Bool
        let stagesOriginals: Bool
        let pausesEnrichmentWhileImporting: Bool
        let rowsWhileUnreachable: Bool

        init(_ kind: LibraryRootKind) {
            userChosenFolder = kind.isUserChosenFolder
            librariesSection = kind.isInLibrariesSection
            allMedia = kind.isMemberOfAllMedia
            importDestination = kind.isImportDestination
            removable = kind.isRemovable
            filesystemNamespace = kind.hasFilesystemNamespace
            moveToTrash = kind.supportsMoveToTrash
            sourceListing = kind.rowsComeFromSourceListing
            stagesOriginals = kind.stagesOriginals
            pausesEnrichmentWhileImporting = kind.pausesEnrichmentWhileImporting
            rowsWhileUnreachable = kind.showsRowsWhileUnreachable
        }

        init(
            userChosenFolder: Bool, librariesSection: Bool, allMedia: Bool, importDestination: Bool,
            removable: Bool, filesystemNamespace: Bool, moveToTrash: Bool, sourceListing: Bool,
            stagesOriginals: Bool, pausesEnrichmentWhileImporting: Bool,
            rowsWhileUnreachable: Bool = false
        ) {
            self.userChosenFolder = userChosenFolder
            self.librariesSection = librariesSection
            self.allMedia = allMedia
            self.importDestination = importDestination
            self.removable = removable
            self.filesystemNamespace = filesystemNamespace
            self.moveToTrash = moveToTrash
            self.sourceListing = sourceListing
            self.stagesOriginals = stagesOriginals
            self.pausesEnrichmentWhileImporting = pausesEnrichmentWhileImporting
            self.rowsWhileUnreachable = rowsWhileUnreachable
        }

        var description: String {
            "\(userChosenFolder) \(librariesSection) \(allMedia) \(importDestination) \(removable) "
                + "\(filesystemNamespace) \(moveToTrash) \(sourceListing) \(stagesOriginals) "
                + "\(pausesEnrichmentWhileImporting) \(rowsWhileUnreachable)"
        }
    }

    /// ADR 0046 §3: an account is a library in browsing — the Libraries section and All
    /// Media — and in nothing that changes files. Its rows come from its server's listing,
    /// its originals are staged when fetched, and its rows stay while the server is gone.
    @Test func anImmichAccountIsABrowsableListingThatChangesNoFiles() {
        #expect(Row(.immichAccount) == Row(
            userChosenFolder: false, librariesSection: true, allMedia: true, importDestination: false,
            removable: false, filesystemNamespace: false, moveToTrash: false, sourceListing: true,
            stagesOriginals: true, pausesEnrichmentWhileImporting: false,
            rowsWhileUnreachable: true
        ))
        #expect(LibraryRootKind.allCases.filter(\.supportsReorganization) == [.library])
        #expect(LibraryRootKind.immichAccount.availabilityAtLaunch == .available)
        #expect(LibraryRootKind.library.availabilityAtLaunch == .unknown)
        #expect(LibraryRootKind.removableVolume.availabilityAtLaunch == .unavailable)
        #expect(LibraryRootKind.deviceMTP.availabilityAtLaunch == .unavailable)
    }

    @Test func sqlListNamesExactlyTheKindsWithTheCapability() {
        #expect(LibraryRootKind.sqlLiteralList(\.isUserChosenFolder) == "'library'")
        #expect(LibraryRootKind.sqlLiteralList(\.isRemovable) == "'removableVolume', 'deviceMTP'")
    }
}
