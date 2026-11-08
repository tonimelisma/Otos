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
        let enrichesFromOriginals: Bool

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
            enrichesFromOriginals = kind.enrichesFromOriginals
        }

        init(
            userChosenFolder: Bool, librariesSection: Bool, allMedia: Bool, importDestination: Bool,
            removable: Bool, filesystemNamespace: Bool, moveToTrash: Bool, sourceListing: Bool,
            stagesOriginals: Bool, pausesEnrichmentWhileImporting: Bool,
            rowsWhileUnreachable: Bool = false, enrichesFromOriginals: Bool = true
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
            self.enrichesFromOriginals = enrichesFromOriginals
        }

        var description: String {
            "\(userChosenFolder) \(librariesSection) \(allMedia) \(importDestination) \(removable) "
                + "\(filesystemNamespace) \(moveToTrash) \(sourceListing) \(stagesOriginals) "
                + "\(pausesEnrichmentWhileImporting) \(rowsWhileUnreachable) \(enrichesFromOriginals)"
        }
    }

    @Test func aLibraryIsAUserChosenFolderInAllMediaThatImportsLand() {
        #expect(Row(.library) == Row(
            userChosenFolder: true, librariesSection: true, allMedia: true, importDestination: true,
            removable: false, filesystemNamespace: true, moveToTrash: true, sourceListing: false,
            stagesOriginals: false, pausesEnrichmentWhileImporting: false
        ))
    }

    @Test func aCardIsARemovableFilesystemThatAnImportReadsInPlace() {
        #expect(Row(.removableVolume) == Row(
            userChosenFolder: false, librariesSection: false, allMedia: false, importDestination: false,
            removable: true, filesystemNamespace: true, moveToTrash: true, sourceListing: false,
            stagesOriginals: false, pausesEnrichmentWhileImporting: true
        ))
    }

    @Test func aCameraIsARemovableListingWhoseOriginalsAreStaged() {
        #expect(Row(.deviceMTP) == Row(
            userChosenFolder: false, librariesSection: false, allMedia: false, importDestination: false,
            removable: true, filesystemNamespace: false, moveToTrash: false, sourceListing: true,
            stagesOriginals: true, pausesEnrichmentWhileImporting: false
        ))
    }

    /// ADR 0046 §3: an account is a library in browsing — the Libraries section and All
    /// Media — and in nothing that changes files. Its rows come from its server's listing,
    /// its originals are staged when fetched, and its rows stay while the server is gone.
    @Test func anImmichAccountIsABrowsableListingThatChangesNoFiles() {
        #expect(Row(.immichAccount) == Row(
            userChosenFolder: false, librariesSection: true, allMedia: true, importDestination: false,
            removable: false, filesystemNamespace: false, moveToTrash: false, sourceListing: true,
            stagesOriginals: true, pausesEnrichmentWhileImporting: false,
            rowsWhileUnreachable: true, enrichesFromOriginals: false
        ))
        #expect(LibraryRootKind.allCases.filter(\.supportsReorganization) == [.library])
        #expect(LibraryRootKind.immichAccount.availabilityAtLaunch == .available)
        #expect(LibraryRootKind.library.availabilityAtLaunch == .unknown)
        #expect(LibraryRootKind.removableVolume.availabilityAtLaunch == .unavailable)
        #expect(LibraryRootKind.deviceMTP.availabilityAtLaunch == .unavailable)
    }

    /// A kind that stages its originals names the container they go into, and only such a
    /// kind does; the staging sweep spans every container.
    @Test func onlyAStagingKindNamesAStagingContainer() {
        #expect(LibraryRootKind.deviceMTP.stagingContainer == .device)
        #expect(LibraryRootKind.immichAccount.stagingContainer == .remote)
        #expect(LibraryRootKind.library.stagingContainer == nil)
        #expect(LibraryRootKind.removableVolume.stagingContainer == nil)
        #expect(StagingContainer.allCases.allSatisfy { container in
            LibraryRootKind.allCases.contains { $0.stagingContainer == container }
        })
    }

    @Test func sqlListNamesExactlyTheKindsWithTheCapability() {
        #expect(LibraryRootKind.sqlLiteralList(\.isUserChosenFolder) == "'library'")
        #expect(LibraryRootKind.sqlLiteralList(\.isRemovable) == "'removableVolume', 'deviceMTP'")
    }
}
