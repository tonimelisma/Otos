import Foundation
@testable import Otos
import Testing

/// These tests cover the two states reproducible without a cloud provider: a local
/// file is always materialized, and a missing path is unknown. The `.dataless`
/// result cannot be produced in a unit test because only a File Provider can create
/// a dataless placeholder; that branch was validated against a real OneDrive library
/// during the spec's proof of concept (see
/// `docs/specs/0016-cloud-materialization-detection.md`).
struct FileMaterializationTests {
    @Test func materializationOutcomeDiagnosticsClassifyTerminalStates() {
        #expect(MaterializationOutcome.alreadyMaterialized.isMaterialized)
        #expect(MaterializationOutcome.materialized.isMaterialized)
        #expect(!MaterializationOutcome.requestFailed.isMaterialized)
        #expect(!MaterializationOutcome.timedOut.isMaterialized)
        #expect(MaterializationOutcome.statusUnavailable.diagnosticDescription == "statusUnavailable")
    }

    @Test func localFileIsMaterialized() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "otos-materialization-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "local.bin")
        try Data([0x01, 0x02, 0x03]).write(to: file)

        // A freshly written local file has its bytes on disk, so it is never a
        // dataless placeholder.
        #expect(FileMaterialization.status(of: file) == .materialized)
    }

    @Test func missingFileIsUnknown() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "otos-missing-\(UUID().uuidString).bin")

        #expect(FileMaterialization.status(of: missing) == .unknown)
    }
}
