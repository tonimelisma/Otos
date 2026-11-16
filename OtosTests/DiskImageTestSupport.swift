import Foundation
import Testing

enum DiskImageTestSupportError: Error {
    case hdiutilFailed(String)
    case unreadableAttachReport
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
/// and no assertion can reach another run's volume.
///
/// The image is detached by its device node, not by its mount path: once its volume is
/// unmounted the mount path is gone while the image can stay attached, and a detach by path
/// then fails and leaves the device behind until the Mac restarts. An eject may detach the
/// image itself, so teardown first asks `hdiutil info` whether it is still attached.
struct MountedTestDiskImage {
    let mountURL: URL
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
            // Attached, but its report names nothing: `hdiutil info` still finds it by its file.
            detachAndDelete(dmgPath)
            throw DiskImageTestSupportError.unreadableAttachReport
        }
        let mountPath = entities.lazy.compactMap { $0["mount-point"] as? String }.first
        let image = MountedTestDiskImage(
            mountURL: URL(fileURLWithPath: mountPath ?? "/", isDirectory: true),
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
        Self.detachAndDelete(dmgPath)
    }

    /// How many times a detach refused as busy is tried again. Each try follows a forced
    /// unmount that returns once DiskArbitration reports the image's volumes unmounted, so a
    /// retry waits on that fact, never on time.
    private static let busyDetachAttempts = 3
    /// `hdiutil detach`'s status when a volume or the device is still held open (`EBUSY`).
    private static let busyStatus: Int32 = 16

    /// Detaches whatever disk `hdiutil info` lists as backed by `dmgPath`, then deletes the
    /// file. A test that ejected the disk itself has already detached the image, and its old
    /// device node may by now name another disk, so the device is read afresh from `hdiutil
    /// info` before each try. Under load a reader of the fresh volume (Spotlight, a DiskArbitration
    /// client) can hold it busy for a moment: the volumes are force-unmounted first, and a busy
    /// refusal is tried again after the next forced unmount. Anything left attached or on disk
    /// is a recorded issue: it outlives the test run.
    private static func detachAndDelete(_ dmgPath: URL) {
        do {
            for attempt in 1 ... busyDetachAttempts {
                guard let device = try attachedDevice(of: dmgPath) else {
                    break
                }
                _ = try run("/usr/sbin/diskutil", ["unmountDisk", "force", device])
                let detach = try hdiutil(["detach", device, "-force"])
                guard detach.status != 0, try attachedDevice(of: dmgPath) != nil else {
                    break
                }
                if detach.status != busyStatus || attempt == busyDetachAttempts {
                    Issue.record("hdiutil detach \(device) exited \(detach.status): \(detach.errorText)")
                    break
                }
            }
            if let device = try attachedDevice(of: dmgPath) {
                Issue.record("disk image \(dmgPath.lastPathComponent) is still attached as \(device) after detach")
            }
        } catch {
            Issue.record(error, "detaching disk image \(dmgPath.lastPathComponent)")
        }
        do {
            try FileManager.default.removeItem(at: dmgPath)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            Issue.record(error, "deleting disk image \(dmgPath.path(percentEncoded: false))")
        }
    }

    /// The whole disk `hdiutil info` lists for an image backed by `dmgPath`, or nil when none
    /// is attached.
    private static func attachedDevice(of dmgPath: URL) throws -> String? {
        let info = try hdiutil(["info", "-plist"])
        guard info.status == 0,
              let report = try PropertyListSerialization.propertyList(from: info.output, format: nil)
              as? [String: Any],
              let images = report["images"] as? [[String: Any]]
        else {
            throw DiskImageTestSupportError.hdiutilFailed("info: \(info.errorText)")
        }
        let file = dmgPath.resolvingSymlinksInPath().path(percentEncoded: false)
        let image = images.first { image in
            guard let path = image["image-path"] as? String else { return false }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path(percentEncoded: false) == file
        }
        guard let image else {
            return nil
        }
        // An APFS image lists its own disk, its partition, and the container disk APFS
        // synthesizes on it, in no fixed order; the image's own disk is the whole disk that
        // carries the partition scheme `hdiutil create` wrote, and failing a hint, the
        // lowest-numbered whole disk, which the container disk comes after.
        let entities = image["system-entities"] as? [[String: Any]] ?? []
        let wholeDisks = entities.compactMap { entity -> (entry: String, hint: String?)? in
            guard let entry = entity["dev-entry"] as? String, entry.isWholeDiskNode else { return nil }
            return (entry, entity["content-hint"] as? String)
        }
        return wholeDisks.first { $0.hint?.hasSuffix("_partition_scheme") == true }?.entry
            ?? wholeDisks.map(\.entry).min { $0.diskNumber < $1.diskNumber }
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
        try run("/usr/bin/hdiutil", arguments)
    }

    /// Runs a tool to its end (`hdiutil`, `diskutil`).
    private static func run(_ executable: String, _ arguments: [String]) throws -> Run {
        let errorFile = FileManager.default.temporaryDirectory
            .appending(path: "otos-test-hdiutil-\(UUID().uuidString).txt", directoryHint: .notDirectory)
        guard FileManager.default.createFile(atPath: errorFile.path(percentEncoded: false), contents: nil) else {
            throw DiskImageTestSupportError.hdiutilFailed("no file for its error text at \(errorFile.path)")
        }
        defer { try? FileManager.default.removeItem(at: errorFile) }
        let errorHandle = try FileHandle(forWritingTo: errorFile)
        defer { try? errorHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
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

    /// N of a whole disk node `/dev/diskN`.
    var diskNumber: Int {
        Int(dropFirst("/dev/disk".count)) ?? .max
    }
}
