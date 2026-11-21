import DiskArbitration
import Foundation
import OSLog

/// Ejects a removable volume through DiskArbitration: unmount every volume on its whole
/// disk, then eject the media — what Finder's Eject does.
///
/// DiskArbitration reports a refusal as a dissenter with a typed status, so the outcome
/// is read from that status and never from an error message. Measured on macOS 27.0.1
/// against a held file on a scratch ExFAT volume
/// (`docs/research/2026-10-23-diskarbitration-eject-status.md`): a busy volume refuses
/// with `unix_err(EBUSY)` (`0xC010`) and no status string. Another DiskArbitration client
/// asked to approve the unmount can dissent with `kDAReturnBusy`, and that is `.busy` too: a
/// holder outside Otos, which the caller asks again after its backoff
/// (`docs/research/2026-11-15-a-released-card-refused-by-another-client.md`).
nonisolated enum DiskEjector {
    enum Outcome: Equatable, Sendable {
        case ejected
        /// A file on the volume is open. Something holds it; retrying may succeed.
        case busy
        /// Any other refusal, with DiskArbitration's status.
        case refused(status: DAReturn)
        /// The volume is not a disk DiskArbitration knows, or no session could be made.
        case diskUnavailable
    }

    @concurrent
    static func eject(volumeAt url: URL) async -> Outcome {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            return unavailable(step: "session", url: url)
        }
        let queue = DispatchQueue(label: "net.melisma.Otos.disk-eject")
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else {
            return unavailable(step: "volumeDisk", url: url)
        }
        guard let whole = DADiskCopyWholeDisk(disk) else {
            return unavailable(step: "wholeDisk", url: url)
        }
        if let status = await request({ context in
            DADiskUnmount(whole, DADiskUnmountOptions(kDADiskUnmountOptionWhole), requestFinished, context)
        }) {
            return refused(status, step: "unmount", url: url)
        }
        if let status = await request({ context in
            DADiskEject(whole, DADiskEjectOptions(kDADiskEjectOptionDefault), requestFinished, context)
        }) {
            return refused(status, step: "eject", url: url)
        }
        return .ejected
    }

    /// A refusal's outcome, logged with the step that was refused and DiskArbitration's
    /// status, so a refusal can be told apart from another after the fact.
    private static func refused(_ status: DAReturn, step: String, url: URL) -> Outcome {
        let outcome = outcome(refusal: status)
        OtosLog.fileAccess.noticeOperation("disk.eject", phase: "refused", fields: [
            "step": step,
            "status": "0x" + String(UInt32(bitPattern: status), radix: 16),
            "outcome": "\(outcome)",
            "volume": url.path(percentEncoded: false),
        ])
        return outcome
    }

    /// No disk to eject, logged with the step that found none.
    private static func unavailable(step: String, url: URL) -> Outcome {
        OtosLog.fileAccess.noticeOperation("disk.eject", phase: "unavailable", fields: [
            "step": step,
            "volume": url.path(percentEncoded: false),
        ])
        return .diskUnavailable
    }

    /// `unix_err(errno)` from `<mach/error.h>`: `err_kern | err_sub(3) | errno`, the
    /// encoding DiskArbitration uses for a BSD error.
    static func unixError(_ code: Int32) -> DAReturn {
        DAReturn(3 << 14) | DAReturn(code)
    }

    /// The BSD error a status encodes, if it encodes one.
    static func bsdError(in status: DAReturn) -> Int32? {
        status & ~DAReturn(0x3FFF) == DAReturn(3 << 14) ? Int32(status & 0x3FFF) : nil
    }

    static func outcome(refusal status: DAReturn) -> Outcome {
        if status == unixError(EBUSY) || status == DAReturn(truncatingIfNeeded: kDAReturnBusy) {
            return .busy
        }
        return .refused(status: status)
    }

    /// Starts one DiskArbitration request and waits for its completion. The status is
    /// `nil` when the request succeeded.
    private static func request(_ start: (UnsafeMutableRawPointer) -> Void) async -> DAReturn? {
        await withCheckedContinuation { continuation in
            start(Unmanaged.passRetained(RequestCompletion(continuation)).toOpaque())
        }
    }
}

private final nonisolated class RequestCompletion {
    let continuation: CheckedContinuation<DAReturn?, Never>

    init(_ continuation: CheckedContinuation<DAReturn?, Never>) {
        self.continuation = continuation
    }
}

/// DiskArbitration calls this exactly once per request, on the session's queue.
private nonisolated func requestFinished(_: DADisk, _ dissenter: DADissenter?, _ context: UnsafeMutableRawPointer?) {
    guard let context else {
        return
    }
    let completion = Unmanaged<RequestCompletion>.fromOpaque(context).takeRetainedValue()
    completion.continuation.resume(returning: dissenter.map(DADissenterGetStatus))
}
