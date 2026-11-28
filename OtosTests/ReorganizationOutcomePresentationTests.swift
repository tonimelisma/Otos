import Foundation
@testable import OtosKit
import Testing

struct ReorganizationOutcomePresentationTests {
    // Validates: ARC-052
    @Test func aRunThatCouldNotStartSaysSoInItsTitle() {
        #expect(ReorganizationOutcomePresentation.alert(for: .libraryBusy(.importPublication)) == ReorganizationAlert(
            title: "Couldn’t Reorganize Library",
            message: "This library is busy with an import. Try again when it finishes."
        ))
    }

    // Validates: ARC-052
    @Test func aRunThatStoppedSaysSoInItsTitleAndTheMessageDoesNotRepeatIt() {
        let path = MediaRelativePath(rawValue: "2024/05")
        let none = ReorganizationStop(
            fault: .folderUnavailable(path),
            progress: ReorganizationStop.Progress(settledComponentCount: 0, componentCount: 2, relocatedCount: 0),
            libraryRestored: true
        )
        #expect(ReorganizationOutcomePresentation.alert(for: none) == ReorganizationAlert(
            title: "Reorganization Stopped",
            message: "No item moved because a folder couldn’t be created at “2024/05”. The other items were left as they were."
        ))

        let some = ReorganizationStop(
            fault: .destinationTaken(path),
            progress: ReorganizationStop.Progress(settledComponentCount: 1, componentCount: 2, relocatedCount: 3),
            libraryRestored: false
        )
        #expect(ReorganizationOutcomePresentation.alert(for: some).message
            == "3 items were reorganized before it stopped because another file is already at “2024/05”. "
            + "Some files couldn’t be moved back. Otos will try again the next time it opens.")
    }
}
