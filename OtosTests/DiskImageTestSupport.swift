import Foundation

enum DiskImageTestSupportError: Error {
    case hdiutilFailed(String)
    case mountPathNotFound
}

/// Mounts a scratch disk image so a test can observe real `DiskArbitration` behavior
/// against an actual disk rather than a mocked resource-value fixture: the facts these
/// tests prove (APP-017's device model, an eject's typed refusal) are live system facts.
///
/// The mount path is shared machine state. `/Volumes/<label>` is chosen by the system
/// from the volume label, and the moment one image leaves it the next image with that
/// label is mounted there — by any process, including another worktree's test run.
/// So every image gets a label of its own: its mount path then names only this image,
/// and neither an assertion nor `detach()` can reach another run's volume.
struct MountedTestDiskImage {
    let mountURL: URL
    private let dmgPath: URL

    static func attach(filesystem: String = "APFS") throws -> MountedTestDiskImage {
        let dmgPath = FileManager.default.temporaryDirectory
            .appending(path: "otos-test-dmg-\(UUID().uuidString).dmg", directoryHint: .notDirectory)
        // An ExFAT label holds at most 11 characters: "Otos" and 7 random hex digits.
        let name = "Otos" + UUID().uuidString.filter(\.isHexDigit).prefix(7)

        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        create.arguments = [
            "create", "-size", "40m", "-fs", filesystem, "-volname", name,
            dmgPath.path(percentEncoded: false),
        ]
        create.standardOutput = FileHandle.nullDevice
        create.standardError = FileHandle.nullDevice
        try create.run()
        create.waitUntilExit()
        guard create.terminationStatus == 0 else {
            throw DiskImageTestSupportError.hdiutilFailed("create")
        }

        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", dmgPath.path(percentEncoded: false), "-nobrowse"]
        let pipe = Pipe()
        attach.standardOutput = pipe
        attach.standardError = FileHandle.nullDevice
        try attach.run()
        attach.waitUntilExit()
        guard attach.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: dmgPath)
            throw DiskImageTestSupportError.hdiutilFailed("attach")
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let mountPath = output
            .split(separator: "\n")
            .compactMap { line -> String? in
                let fields = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
                return fields.last?.hasPrefix("/Volumes/") == true ? fields.last : nil
            }
            .first
        guard let mountPath else {
            try? FileManager.default.removeItem(at: dmgPath)
            throw DiskImageTestSupportError.mountPathNotFound
        }
        return MountedTestDiskImage(mountURL: URL(fileURLWithPath: mountPath, isDirectory: true), dmgPath: dmgPath)
    }

    func detach() {
        let detach = Process()
        detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detach.arguments = ["detach", mountURL.path(percentEncoded: false), "-force"]
        detach.standardOutput = FileHandle.nullDevice
        detach.standardError = FileHandle.nullDevice
        try? detach.run()
        detach.waitUntilExit()
        try? FileManager.default.removeItem(at: dmgPath)
    }
}
