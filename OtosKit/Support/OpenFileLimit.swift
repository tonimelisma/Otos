import Darwin
import OSLog

/// Open-file limit guide
///
/// A Mac app starts with the soft open-file limit launchd gives it: 256. Otos holds about 130
/// open at rest (its catalog's connections, its caches, the frameworks it maps) and opens more
/// in bursts — downloads it watches, decodes, the search index — and the system frameworks it
/// hosts open their own files inside its process. On the owner's Mac (2026-11-26) Apple
/// Intelligence's model service, opening its asset lock inside Otos, failed with "Too many
/// open files", so every description request failed (`ModelManagerError` 1026) and the
/// Activity surface said Apple Intelligence was not responding
/// (`docs/research/2026-11-26-copy-paste-and-cloud-originals.md`).
///
/// The machine's resources are for the work (ADR 0057), so the soft limit is raised once, at
/// launch, to the most macOS lets a process set: `OPEN_MAX`, or the hard limit when that is
/// lower. `setrlimit(2)` refuses anything above `OPEN_MAX` for `RLIMIT_NOFILE`, including
/// `RLIM_INFINITY`. A limit that cannot be raised is logged and left as it is.
nonisolated enum OpenFileLimit {
    /// The soft limit to ask for: `OPEN_MAX`, or the hard limit when lower, and never less
    /// than the limit already in force.
    static func target(current: rlim_t, hard: rlim_t) -> rlim_t {
        max(current, min(hard, rlim_t(OPEN_MAX)))
    }

    /// Raises the process's soft open-file limit to `target`, once, at launch.
    static func raise() {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else {
            OtosLog.app.errorOperation("app.openFiles", phase: "unread", fields: ["errno": "\(errno)"])
            return
        }
        let before = limits.rlim_cur
        let wanted = target(current: before, hard: limits.rlim_max)
        guard wanted > before else {
            OtosLog.app.noticeOperation("app.openFiles", phase: "kept", fields: ["limit": "\(before)"])
            return
        }
        limits.rlim_cur = wanted
        guard setrlimit(RLIMIT_NOFILE, &limits) == 0 else {
            OtosLog.app.errorOperation("app.openFiles", phase: "refused", fields: [
                "from": "\(before)", "to": "\(wanted)", "errno": "\(errno)",
            ])
            return
        }
        OtosLog.app.noticeOperation("app.openFiles", phase: "raised", fields: [
            "from": "\(before)", "to": "\(wanted)",
        ])
    }
}
