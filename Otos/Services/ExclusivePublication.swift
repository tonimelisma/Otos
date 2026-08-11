import Darwin
import Foundation
import OSLog

/// Volume rename-exclusivity capability (ARC-048).
///
/// Probes `VOL_CAP_INT_RENAME_EXCL` via `getattrlist`. APFS advertises it; exFAT
/// and many SMB mounts do not. The exclusive-publication ladder uses this bit
/// to choose `renamex_np(RENAME_EXCL)`, hard-link+unlink, or check-then-act.
nonisolated enum VolumeRenameCapability {
    case renameExcl
    case hardLink
    case checkThenAct

    static func probe(url: URL) -> VolumeRenameCapability {
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.volattr = attrgroup_t(UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_CAPABILITIES))

        var buffer = [UInt8](
            repeating: 0,
            count: max(64, MemoryLayout<UInt32>.size + MemoryLayout<vol_capabilities_attr_t>.size + 64)
        )
        let result = buffer.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else {
                return -1
            }
            return getattrlist(url.path, &attrs, base, raw.count, 0)
        }
        guard result == 0 else {
            return .checkThenAct
        }
        // getattrlist succeeded: buffer[0..<4] is the returned length, followed
        // by the vol_capabilities_attr_t. Parse the capability bit rather than
        // assuming APFS.
        let returnedLength: UInt32 = buffer.withUnsafeBytes { raw in
            raw.load(as: UInt32.self)
        }
        let minimumLength = UInt32(MemoryLayout<UInt32>.size + MemoryLayout<vol_capabilities_attr_t>.size)
        guard returnedLength >= minimumLength else {
            return .hardLink
        }
        let caps: vol_capabilities_attr_t = buffer.withUnsafeBytes { raw in
            raw.load(fromByteOffset: MemoryLayout<UInt32>.size, as: vol_capabilities_attr_t.self)
        }
        let valid = caps.valid.1
        let capabilities = caps.capabilities.1
        let renameExclBit = UInt32(VOL_CAP_INT_RENAME_EXCL)
        if (valid & renameExclBit) != 0, (capabilities & renameExclBit) != 0 {
            return .renameExcl
        }
        // Volume does not advertise atomic rename-excl; hard-link+unlink is the
        // next exclusive ladder rung, falling through to check-then-act only if
        // the link itself fails with a non-EEXIST error.
        return .hardLink
    }
}

/// Publishes a staged file to a final absent URL without overwriting.
nonisolated enum ExclusivePublication {
    enum Outcome: Equatable, Sendable {
        case published
        case destinationExists
        case failed(String)
    }

    static func publish(staging: URL, final: URL) -> Outcome {
        let parent = final.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let capability = VolumeRenameCapability.probe(url: parent)
        switch capability {
        case .renameExcl:
            return publishWithRenameExcl(staging: staging, final: final)
        case .hardLink:
            let linked = publishWithHardLink(staging: staging, final: final)
            if case .failed = linked {
                return publishWithCheckThenAct(staging: staging, final: final)
            }
            return linked
        case .checkThenAct:
            return publishWithCheckThenAct(staging: staging, final: final)
        }
    }

    private static func publishWithRenameExcl(staging: URL, final: URL) -> Outcome {
        let result = staging.path.withCString { from in
            final.path.withCString { to in
                renamex_np(from, to, UInt32(RENAME_EXCL))
            }
        }
        if result == 0 {
            return .published
        }
        if errno == EEXIST {
            return .destinationExists
        }
        return .failed("renamex_np errno=\(errno)")
    }

    private static func publishWithHardLink(staging: URL, final: URL) -> Outcome {
        let linkResult = staging.path.withCString { from in
            final.path.withCString { to in
                link(from, to)
            }
        }
        if linkResult == 0 {
            _ = staging.path.withCString { unlink($0) }
            return .published
        }
        if errno == EEXIST {
            return .destinationExists
        }
        return .failed("link errno=\(errno)")
    }

    private static func publishWithCheckThenAct(staging: URL, final: URL) -> Outcome {
        if FileManager.default.fileExists(atPath: final.path) {
            return .destinationExists
        }
        do {
            try FileManager.default.moveItem(at: staging, to: final)
            return .published
        } catch {
            if FileManager.default.fileExists(atPath: final.path) {
                return .destinationExists
            }
            return .failed(String(describing: error))
        }
    }
}
