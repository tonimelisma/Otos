import Foundation
import Testing

enum DiskImageTestSupportError: Error {
    case hdiutilFailed(String)
    case unreadableAttachReport
    case mountPathNotFound
    case deviceNotFound
}

/// Mounts a scratch disk image so a test can observe real `DiskArbitration` behavior
/// against an actual disk rather than a mocked resource-value fixture: the facts these
/// tests prove (APP-017's device model, an eject's typed refusal) are live system facts.
///
/// The mount path is shared machine state. `/Volumes/<label>` is chosen by the system
/// from the volume label, and the moment one image leaves it the next image with that
/// label is mounted there — by any process, including another worktree's test run.
/// So every image gets a label of its own: its mount path then names only this image,
/// and no assertion can reach another run's volume.
///
/// The image is detached by its device node, not by its mount path: once its volume is
/// unmounted the mount path is gone while the image can stay attached, and a detach by path
/// then fails and leaves the device behind until the Mac restarts. An eject may detach the
/// image itself, so teardown first asks `hdiutil info` whether it is still attached.
struct MountedTestDiskImage {
    let mountURL: URL
    /// The image's own whole disk (`/dev/diskN`), the one carrying its partition scheme.
    private let device: String
    private let dmgPath: URL

    static func attach(filesystem: String = "APFS") throws -> MountedTestDiskImage {
        let dmgPath = FileManager.default.temporaryDirectory
            .appending(path: "otos-test-dmg-\(UUID().uuidString).dmg", directoryHint: .notDirectory)
        // An ExFAT label holds at most 11 characters: "Otos" and 7 random hex digits.
        let name = "Otos" + UUID().uuidString.filter(\.isHexDigit).prefix(7)

        let create = try hdiutil([
            "create", "-size", "40m", "-fs", filesystem, "-volname", name,
            dmgPath.path(percentEncoded: false),
        ])
        guard create.status == 0 else {
            try? FileManager.default.removeItem(at: dmgPath)
            throw DiskImageTestSupportError.hdiutilFailed("create: \(create.errorText)")
        }

        let attach = try hdiutil(["attach", dmgPath.path(percentEncoded: false), "-nobrowse", "-plist"])
        guard attach.status == 0 else {
            try? FileManager.default.removeItem(at: dmgPath)
            throw DiskImageTestSupportError.hdiutilFailed("attach: \(attach.errorText)")
        }
        guard let report = try? PropertyListSerialization.propertyList(from: attach.output, format: nil)
            as? [String: Any],
            let entities = report["system-entities"] as? [[String: Any]]
        else {
            throw DiskImageTestSupportError.unreadableAttachReport
        }
        // An APFS image lists its own disk, its partition, and the container disk APFS
        // synthesizes on it, in no fixed order; the image's own disk is the whole disk that
        // carries the partition scheme `hdiutil create` wrote.
        let device = entities.first { entity in
            guard let entry = entity["dev-entry"] as? String,
                  let hint = entity["content-hint"] as? String
            else { return false }
            return entry.isWholeDiskNode && hint.hasSuffix("_partition_scheme")
        }?["dev-entry"] as? String
        let mountPath = entities.lazy.compactMap { $0["mount-point"] as? String }.first
        guard let device else {
            // Nothing names the image's disk, so every whole disk it listed goes.
            for entry in entities.compactMap({ $0["dev-entry"] as? String }) where entry.isWholeDiskNode {
                _ = try? hdiutil(["detach", entry, "-force"])
            }
            try? FileManager.default.removeItem(at: dmgPath)
            throw DiskImageTestSupportError.deviceNotFound
        }
        let image = MountedTestDiskImage(
            mountURL: URL(fileURLWithPath: mountPath ?? "/", isDirectory: true),
            device: device,
            dmgPath: dmgPath
        )
        guard mountPath != nil else {
            image.detach()
            throw DiskImageTestSupportError.mountPathNotFound
        }
        return image
    }

    /// Detaches the image, whether or not its volume is still mounted, and deletes its file.
    /// A detach that fails, an image still attached afterwards, or a file left behind is a
    /// recorded issue: each leaves state on the machine that outlives the test run.
    func detach() {
        do {
            // A test that ejected the disk itself has already detached the image, and its
            // device node may by now name another disk: only an image `hdiutil info` still
            // lists by this file is detached.
            if try isAttached() {
                let detach = try Self.hdiutil(["detach", device, "-force"])
                if detach.status != 0 {
                    Issue.record("hdiutil detach \(device) exited \(detach.status): \(detach.errorText)")
                }
                if try isAttached() {
                    Issue.record("disk image \(dmgPath.lastPathComponent) is still attached as \(device) after detach")
                }
            }
        } catch {
            Issue.record(error, "detaching disk image \(dmgPath.lastPathComponent) at \(device)")
        }
        do {
            try FileManager.default.removeItem(at: dmgPath)
        } catch {
            Issue.record(error, "deleting disk image \(dmgPath.path(percentEncoded: false))")
        }
    }

    /// Whether `hdiutil info` still lists an image backed by this image's file.
    private func isAttached() throws -> Bool {
        let info = try Self.hdiutil(["info", "-plist"])
        guard info.status == 0,
              let report = try PropertyListSerialization.propertyList(from: info.output, format: nil)
              as? [String: Any],
              let images = report["images"] as? [[String: Any]]
        else {
            throw DiskImageTestSupportError.hdiutilFailed("info: \(info.errorText)")
        }
        let file = dmgPath.resolvingSymlinksInPath().path(percentEncoded: false)
        return images.contains { image in
            guard let path = image["image-path"] as? String else { return false }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path(percentEncoded: false) == file
        }
    }

    private struct Run {
        let status: Int32
        let output: Data
        let errorText: String
    }

    /// Runs hdiutil to its end. Its report is read to end of file before the wait, so a
    /// report larger than a pipe's buffer cannot stall it; its error text goes to a file,
    /// which never fills.
    private static func hdiutil(_ arguments: [String]) throws -> Run {
        let errorFile = FileManager.default.temporaryDirectory
            .appending(path: "otos-test-hdiutil-\(UUID().uuidString).txt", directoryHint: .notDirectory)
        guard FileManager.default.createFile(atPath: errorFile.path(percentEncoded: false), contents: nil) else {
            throw DiskImageTestSupportError.hdiutilFailed("no file for its error text at \(errorFile.path)")
        }
        defer { try? FileManager.default.removeItem(at: errorFile) }
        let errorHandle = try FileHandle(forWritingTo: errorFile)
        defer { try? errorHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = errorHandle
        try process.run()
        let report = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errorText = try String(decoding: Data(contentsOf: errorFile), as: UTF8.self)
        return Run(
            status: process.terminationStatus,
            output: report,
            errorText: errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

private extension String {
    /// `/dev/diskN`: a whole disk, not one of its slices (`/dev/diskNsM`).
    var isWholeDiskNode: Bool {
        let number = dropFirst("/dev/disk".count)
        return hasPrefix("/dev/disk") && !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
