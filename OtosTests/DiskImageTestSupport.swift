import Foundation

/// Mounts a scratch APFS disk image so a test can observe real
/// `DiskArbitration` behavior against an actual disk image rather than a
/// mocked resource-value fixture — the qualification predicate this supports
/// (APP-017) is specifically about a live system fact
/// (`kDADiskDescriptionDeviceProtocolKey`), not one `URLResourceValues` alone
/// can answer, so a real mount is what proves the code path, not a stand-in.
enum DiskImageTestSupportError: Error {
    case hdiutilFailed(String)
    case mountPathNotFound
}

struct MountedTestDiskImage {
    let mountURL: URL
    private let dmgPath: URL

    static func attach(named name: String = "OtosTestDMG") throws -> MountedTestDiskImage {
        let dmgPath = FileManager.default.temporaryDirectory
            .appending(path: "otos-test-dmg-\(UUID().uuidString).dmg", directoryHint: .notDirectory)

        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        create.arguments = [
            "create", "-size", "5m", "-fs", "APFS", "-volname", name,
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
