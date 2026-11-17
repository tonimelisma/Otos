import Darwin
import Foundation
import Synchronization
import UniformTypeIdentifiers

// Media operation planning models (ARC-046).
//
// Immutable Sendable values only. The pure planner consumes these; the
// coordinator (ARC-047) owns lifecycle. No I/O, no actor hops, no logging.

nonisolated enum MediaOperationMode: Equatable, Sendable {
    case `import`(source: LibraryRootPath, destination: LibraryRootPath)
    case reorganize(library: LibraryRootPath)

    /// The library an import plan copies into; `nil` for a reorganization.
    var importDestination: LibraryRootPath? {
        if case let .import(_, destination) = self {
            return destination
        }
        return nil
    }
}

/// Which fact changed between what a plan expected and what the live source
/// reports.
nonisolated enum ChangedFact: Equatable, Sendable {
    case size
    case date
}

/// Why a plan entry's live source does or does not still match what the plan
/// captured. One typed answer for every "does this still match" check
/// (`MediaImportExecutor.sourceStillMatches`, `DeviceCameraSession.revalidate`),
/// so a systemic cause (the source itself wasn't ready) can be told apart from
/// an ordinary per-file one — a `Bool` would collapse the two.
nonisolated enum SourceValidation: Equatable, Sendable {
    case matches
    /// The device session or volume mount wasn't ready to answer at all —
    /// true for every entry from this source simultaneously, not a fact
    /// about any one file.
    case sourceNotReady
    case changed(ChangedFact)
    case absent
}

nonisolated struct ImportPolicy: Equatable, Sendable {
    var destinationFolderPolicy: DestinationFolderPolicy
    var destinationNamePolicy: DestinationNamePolicy
    var importSidecarFiles: Bool
    var deleteSourceAfterImport: Bool
    var autoEjectAfterImport: Bool

    static func from(_ preferences: ImportPreferences) -> ImportPolicy {
        ImportPolicy(
            destinationFolderPolicy: preferences.destinationFolderPolicy,
            destinationNamePolicy: preferences.destinationNamePolicy,
            importSidecarFiles: preferences.importSidecarFiles,
            deleteSourceAfterImport: preferences.deleteSourceAfterImport,
            autoEjectAfterImport: preferences.autoEjectAfterImport
        )
    }
}

/// How much the catalog knows about the fact an import plan names a file by.
/// Distinct from enrichment staleness, which asks whether enrichment should run
/// again — a file can be permanently "stale" (no mtime to compare against) while
/// its naming fact is fully known. `MediaOperationGateway` derives this.
nonisolated enum NamingFactState: Equatable, Sendable {
    /// No date of any kind yet. Planning waits (`import-bar.md` state A).
    case pending
    /// Enrichment is current for these exact file facts; nothing is outstanding.
    case settled
    /// Not enrichment-complete, but the naming fact cannot improve: either the
    /// capture wall is already known, or a durable filesystem mtime is the only
    /// fallback there will ever be. Planning proceeds.
    case terminal
}

nonisolated struct PlanningFileFacts: Equatable, Sendable, Identifiable {
    let id: MediaAssetID
    let sourceURL: URL
    let relativePath: MediaRelativePath
    let byteSize: Int64?
    let contentModifiedAt: Date?
    let captureWallCompact: Int64?
    /// How `captureWallCompact` was established. A wall Otos *derived* (a video's
    /// mtime less its duration) names the file but must not stamp the destination
    /// mtime — see `ImportDestinationDate`.
    let captureWallPrecision: String?
    let namingFactState: NamingFactState
    /// The source bytes could not be opened when enrichment tried. Such a file cannot
    /// be enriched *or* copied, so it must neither hold the naming gate open nor be
    /// silently skipped — the planner blocks it and the bar shows it (ARC-057).
    let isSourceUnreadable: Bool
    let mediaKind: MediaKind?
    let contentTypeIdentifier: String?
    let fileExtension: String
    let companions: [MediaCompanion]
    /// For a Live Photo's motion movie, its still (ADR 0041): the two name as one bundle,
    /// so the movie never leaves its still's folder or name.
    let livePhotoStillPath: MediaRelativePath?
    /// The source's digest, present only while it is current for `byteSize` and
    /// `contentModifiedAt` (ADR 0018). The import compares the staged copy's digest with it.
    let contentHash: ContentDigest?

    init(
        id: MediaAssetID,
        sourceURL: URL,
        relativePath: MediaRelativePath,
        byteSize: Int64?,
        contentModifiedAt: Date?,
        captureWallCompact: Int64?,
        captureWallPrecision: String? = nil,
        namingFactState: NamingFactState = .settled,
        isSourceUnreadable: Bool = false,
        mediaKind: MediaKind?,
        fileExtension: String,
        companions: [MediaCompanion],
        contentTypeIdentifier: String? = nil,
        livePhotoStillPath: MediaRelativePath? = nil,
        contentHash: ContentDigest? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.contentModifiedAt = contentModifiedAt
        self.captureWallCompact = captureWallCompact
        self.captureWallPrecision = captureWallPrecision
        self.namingFactState = namingFactState
        self.isSourceUnreadable = isSourceUnreadable
        self.mediaKind = mediaKind
        self.contentTypeIdentifier = contentTypeIdentifier
        self.fileExtension = fileExtension
        self.companions = companions
        self.livePhotoStillPath = livePhotoStillPath
        self.contentHash = contentHash
    }

    /// Best planning date: embedded capture wall when present, else source mtime.
    var hasAnyDate: Bool {
        captureWallCompact != nil || contentModifiedAt != nil
    }
}

/// Chooses a destination extension only when Otos authors a new date/time leaf
/// name. The scanner's filesystem content type is authoritative; parser output
/// is deliberately absent from this boundary.
nonisolated enum CanonicalMediaExtension {
    static func forDateTimeName(
        contentTypeIdentifier: String?,
        sourceExtension: String
    ) -> String {
        guard let contentTypeIdentifier,
              let contentType = UTType(contentTypeIdentifier),
              !contentType.isDynamic,
              MediaKind.classify(contentType) != nil,
              let preferred = contentType.preferredFilenameExtension,
              !preferred.isEmpty
        else {
            return sourceExtension
        }
        return preferred.lowercased()
    }
}

nonisolated struct DestinationOccupantFacts: Equatable, Sendable {
    let relativePath: MediaRelativePath
    let byteSize: Int64?
    let contentModifiedAt: Date?
}

nonisolated enum MediaOperationDisposition: Equatable, Sendable {
    case copy(destination: MediaRelativePath)
    case skipPreexisting(destination: MediaRelativePath)
    /// A library already holds this item's bytes (its current digest matches a library
    /// row's, ADR 0018), wherever and under whatever name, so it is not copied again.
    case skipInLibrary(library: LibraryRootPath)
    case excluded(ExclusionReason)
    case blocked(MediaOperationBlockReason)
}

nonisolated enum ExclusionReason: Equatable, Sendable {
    case empty
    case cruft(SourceFileClass)
}

nonisolated enum MediaOperationBlockReason: Equatable, Sendable {
    case noUsableDate
    /// The destination folder this candidate would land in could not be read
    /// when the plan was built, so its freeness is unproven. The planner's
    /// safety net (ADR 0019) — the coordinator never presents a plan built on
    /// an unread folder; it retries the build and holds the last proven plan.
    case filesystemObservationUnavailable(destination: MediaRelativePath)
    /// Every suffix the naming policy allows is taken in the destination folder.
    case noFreeDestinationName(destination: MediaRelativePath)
    /// A file in the destination holds the name of the folder this item would go in
    /// (or of a folder above it), so the folder cannot be created. Waiting does not
    /// change it; the user moves or renames that file.
    case destinationFolderOccupied(occupant: String)
    /// The source file's bytes could not be opened, so enrichment could not read it
    /// and a copy could not read it either. On a card this is a failing card or a
    /// file that vanished — never a transient condition worth waiting out, since a
    /// removable volume's bytes are local (ARC-057).
    case sourceUnreadable
}

/// One blocked plan entry the user can act on via "Show them" (state D). Carries
/// identity, not just a count, so the ViewModel can select and scroll the affected
/// tiles (`import-bar.md` state D).
nonisolated struct MediaAttentionItem: Equatable, Sendable, Identifiable {
    let id: MediaAssetID
    let reason: MediaOperationBlockReason
}

/// Why a run ended before attempting every entry it planned (`import-bar.md`
/// state F, Stopped). A stop is a stop — nothing went wrong that `Try Again`
/// could fix — and the reason is data the bar names at L3. Distinct from
/// `MediaOperationFailureReason` on purpose: a stopped run is a partial
/// success with a real batch, a remainder, and no auto-eject or erase.
nonisolated enum ImportStopReason: Equatable, Sendable {
    /// The user pressed Cancel.
    case user
    /// The next entry would have left the destination volume below
    /// `FreeSpaceFloor.bytes`, or a write refused for space first
    /// (ADR 0027). `bytesFree` is the capacity read at the stop, for the
    /// bar's clause; `nil` when the volume did not report it.
    case diskFloor(bytesFree: Int64?)
}

/// Reads the free space on a URL's volume, `nil` when the volume does not answer. Every
/// owner that applies `FreeSpaceFloor` takes one as a required dependency: the app's
/// composition root (`OtosApp`) passes `FreeSpaceFloor.availableBytes(onVolumeOf:)`, and a
/// test passes the figure it runs under, so no outcome depends on how full the machine
/// running it is (ADR 0027).
typealias VolumeCapacityReader = @Sendable (URL) -> Int64?

/// The free space Otos never takes a volume below (ADR 0027), and the one way every
/// writer asks about it: import admits an entry, Move to Trash starts a download, and
/// `MaterializationCoordinator` starts a background or device download only while the
/// volume keeps this much after that write lands, counted through the owner's
/// `FreeSpaceLedger` when it has several writes at once.
/// One constant and one check with one home — the promise is the same wherever Otos
/// writes.
nonisolated enum FreeSpaceFloor {
    static let bytes: Int64 = 5 * 1024 * 1024 * 1024

    /// CacheDelete's figure for important usage on `url`'s volume, through the app's one
    /// hold (`VolumeCapacityHold`): it counts purgeable space and can lag the truth in either
    /// direction (research 2026-09-09, finding 4), which the floor tolerates in the
    /// conservative direction only — a stale-low figure stops a little early and the work is
    /// offered again; a stale-high one is caught by the write's own `ENOSPC`. `nil` when the
    /// volume does not answer.
    static func availableBytes(onVolumeOf url: URL) -> Int64? {
        VolumeCapacityHold.shared.available(onVolumeOf: url)
    }

    /// The volume `url` lies on, which keys a `FreeSpaceLedger`: one volume's projection
    /// never gates a write to another. `url` itself when the volume does not answer.
    static func volume(of url: URL) -> URL {
        (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume ?? url
    }

    /// Whether one write of `bytes` keeps a volume reporting `available` at or above the
    /// floor. For a single write with nothing else of Otos's in flight; an owner with
    /// several writes at once asks its `FreeSpaceLedger`. An unknown capacity admits: it
    /// is not evidence of room, but neither is it evidence of none, and the write's
    /// `ENOSPC` is the backstop.
    static func admits(_ bytes: Int64, available: Int64?) -> Bool {
        guard let available else {
            return true
        }
        return available - bytes >= Self.bytes
    }

    /// Whether a write failed because its volume was out of space — the floor reached the
    /// hard way. Classified by the error's typed chain, never by its wording: Foundation's
    /// `NSFileWriteOutOfSpaceError` or a POSIX `ENOSPC` anywhere in the underlying-error
    /// chain. An error that carries neither is not, whatever it says.
    static func refusedForSpace(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return refusedForSpace(underlying)
        }
        return false
    }
}

/// The free space each volume reports for important use (`FreeSpaceFloor.availableBytes`),
/// at the cost of one CacheDelete calculation per volume per `refresh` rather than per
/// decision: the calculation takes about 15 ms of CPU, and a session asked for it once per
/// background download and once per page of People's vectors, about a second in every two
/// minutes (`docs/research/2026-11-16-idle-disk-read-attribution.md`).
///
/// Between two calculations, the figure held is lowered at once by every byte the volume's
/// own free count (`statfs`, microseconds) has lost since it was read, so a write that
/// reaches the disk, Otos's or anyone's, shows in the next decision as it did with a fresh
/// figure. Space freed since — a file deleted, a purge — shows only at the next calculation:
/// the held figure can be low for up to `refresh`, never high, which is the direction the
/// floor tolerates (ADR 0027).
final nonisolated class VolumeCapacityHold: Sendable {
    /// What `statfs` says of the volume a URL lies on: which volume, and its free bytes.
    struct Free: Equatable, Sendable {
        let volume: [Int32]
        let bytes: Int64
    }

    /// The app's one hold, which every owner's floor reads through.
    static let shared = VolumeCapacityHold()

    /// How long a calculation is used before the next. time: poll — CacheDelete reports no
    /// change of the purgeable space it counts, so the figure is asked again this often.
    static let refresh: Duration = .seconds(60)

    private struct Held {
        let important: Int64
        let free: Int64
        let at: ContinuousClock.Instant
    }

    private let held = Mutex<[[Int32]: Held]>([:])
    private let readImportant: @Sendable (URL) -> Int64?
    private let readFree: @Sendable (URL) -> Free?
    private let now: @Sendable () -> ContinuousClock.Instant
    private let refresh: Duration

    init(
        readImportant: @escaping @Sendable (URL) -> Int64? = VolumeCapacityHold.importantUsage,
        readFree: @escaping @Sendable (URL) -> Free? = VolumeCapacityHold.statfsFree,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        refresh: Duration = VolumeCapacityHold.refresh
    ) {
        self.readImportant = readImportant
        self.readFree = readFree
        self.now = now
        self.refresh = refresh
    }

    /// The figure for `url`'s volume: the held calculation less what the volume's free count
    /// has lost since, or a new calculation once the held one is `refresh` old. A volume
    /// `statfs` cannot read is asked directly every time; nil when it does not answer.
    func available(onVolumeOf url: URL) -> Int64? {
        guard let free = readFree(url) else {
            return readImportant(url)
        }
        let instant = now()
        if let figure = held.withLock({ held -> Int64? in
            guard let last = held[free.volume], instant - last.at < refresh else { return nil }
            return last.important + min(0, free.bytes - last.free)
        }) {
            return figure
        }
        guard let important = readImportant(url) else {
            return nil
        }
        held.withLock { $0[free.volume] = Held(important: important, free: free.bytes, at: instant) }
        return important
    }

    /// CacheDelete's figure for important usage on `url`'s volume.
    @Sendable static func importantUsage(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// The volume's free bytes as the file system counts them, and its identity.
    @Sendable static func statfsFree(_ url: URL) -> Free? {
        var status = statfs()
        guard statfs(url.path(percentEncoded: false), &status) == 0 else {
            return nil
        }
        return Free(volume: [status.f_fsid.val.0, status.f_fsid.val.1], bytes: Int64(status.f_bavail) * Int64(status.f_bsize))
    }
}

/// One owner's account of the space its own writes have taken on a volume, so the floor
/// (ADR 0027) is checked against neither more nor less than is really free.
///
/// The volume's figure alone undercounts: a write admitted a moment ago may not have
/// reached the disk yet. Subtracting every in-flight write from the figure overcounts:
/// `copyfile` reserves a file's whole size when it starts (research 2026-11-10), so a
/// started write is in the figure *and* in the subtraction, and a run of eight workers
/// stops up to eight files early. The ledger holds two views and checks against the
/// lesser:
///
/// - the figure now, which sees every write that has reached the disk, Otos's and
///   everyone else's;
/// - the first figure this ledger read, less every byte it has committed since, which
///   sees every write of Otos's whether or not the figure has caught up.
///
/// A fresh figure makes the two agree except for writes not yet started, which is exact.
/// A figure that lags or never moves (CacheDelete) leaves the second view in charge,
/// which still counts every landed write. That is safer than a figure less what is in
/// flight now, which forgets an entry the moment it lands.
///
/// A figure that rises above the one read before it is live — a figure that lags or never
/// moves does not rise — and space was freed: the user emptied the Trash, or a write was
/// given back. The projection is then re-based on it, the figure less every byte still in
/// flight, if that is more, so the freed space is admitted before the stretch ends.
///
/// A write settles with the bytes it landed (`settle`): those stay subtracted, since they
/// are on the disk, and the rest are given back — all of a write that failed, was
/// cancelled or refused, or found its file already local. The owner sets the ledger's
/// lifetime: one import run, or one busy stretch of downloads that ends when nothing is in
/// flight, after which the next write reads the figure afresh.
nonisolated struct FreeSpaceLedger: Equatable, Sendable {
    /// The first figure read, less every byte committed since and not given back; `nil`
    /// until a reading.
    private var projected: Int64?
    /// The figure read for the newest decision.
    private var lastReported: Int64?
    /// Every byte this ledger has committed whose write has not settled.
    private(set) var inFlightBytes: Int64 = 0

    /// The free space the floor is checked against, given the figure read now: the
    /// lesser of that figure and the projection. `nil` when neither is known.
    func available(reported: Int64?) -> Int64? {
        switch (reported, projected) {
        case let (reported?, projected?): min(reported, projected)
        case let (reported?, nil): reported
        case let (nil, projected?): projected
        case (nil, nil): nil
        }
    }

    /// Admits a write of `bytes` if it keeps the floor, and commits it. `reported` is the
    /// volume's figure read for this decision. The first one read sets the projection,
    /// less whatever is in flight: those bytes are assumed not to be in it yet. A figure
    /// above the last one re-bases the projection the same way.
    mutating func admit(_ bytes: Int64, reported: Int64?) -> Bool {
        if let reported {
            let rebased = reported - inFlightBytes
            if let current = projected {
                if let lastReported, reported > lastReported {
                    projected = max(current, rebased)
                }
            } else {
                projected = rebased
            }
            lastReported = reported
        }
        guard FreeSpaceFloor.admits(bytes, available: available(reported: reported)) else {
            return false
        }
        commit(bytes)
        return true
    }

    /// Commits a write that does not wait for the floor (the photo on screen, a command
    /// the user gave), so the writes that do wait still count it.
    mutating func commit(_ bytes: Int64) {
        projected = projected.map { $0 - bytes }
        inFlightBytes += bytes
    }

    /// Settles a committed write of `committed` bytes that left `landed` of them on the
    /// disk: those stay subtracted, the rest are given back.
    mutating func settle(committed: Int64, landed: Int64) {
        projected = projected.map { $0 + committed - landed }
        inFlightBytes -= committed
    }
}

/// Causes of an import failure a user can act on (DES-035/DES-039 forbid
/// publishing internal vocabulary to the bar). `.unexpected` is the one case
/// whose detail is for the log, never the bar (`import-bar.md` state G).
nonisolated enum MediaOperationFailureReason: Equatable, Sendable {
    case sourceRemoved
    case destinationUnavailable
    /// Every attempted entry failed `SourceValidation` with the same
    /// non-per-file reason — the source itself wasn't ready, not any one
    /// file. Per the owner decision, `ImportSourceReadiness` (ADR 0024)
    /// should make this unreachable in practice; it exists so that if it
    /// ever happens, the bar says something true instead of "Done".
    case sourceNotReady
    case unexpected(detail: String)

    /// Classifies why an import-planning snapshot came back empty: whichever of
    /// the two roots is missing from the currently available set, or unexpected
    /// when both are present. `blocked` is never "can't be read"
    /// (`MediaOperationBlockReason`); this applies the same discipline to a
    /// failed plan build instead of guessing (trap #3).
    static func forMissingSnapshot(
        source: LibraryRootPath,
        destination: LibraryRootPath,
        availableRoots: Set<LibraryRootPath>
    ) -> MediaOperationFailureReason {
        if !availableRoots.contains(source) {
            return .sourceRemoved
        }
        if !availableRoots.contains(destination) {
            return .destinationUnavailable
        }
        return .unexpected(detail: "snapshotUnavailable")
    }
}

nonisolated struct MediaOperationPlanEntry: Equatable, Sendable {
    let source: PlanningFileFacts
    let companionDestinations: [MediaRelativePath: MediaRelativePath]
    let disposition: MediaOperationDisposition

    /// Where the entry lands in the library: the copy's destination, or the file that is
    /// already there. A blocked or excluded entry has none.
    var destination: MediaRelativePath? {
        switch disposition {
        case let .copy(destination), let .skipPreexisting(destination):
            destination
        case .skipInLibrary, .blocked, .excluded:
            nil
        }
    }

    var isSkipPreexisting: Bool {
        if case .skipPreexisting = disposition {
            return true
        }
        return false
    }
}

nonisolated struct EraseManifestEntry: Equatable, Sendable, Identifiable {
    let relativePath: MediaRelativePath
    let byteSize: Int64?
    let fileClass: SourceFileClass

    var id: String {
        relativePath.rawValue
    }
}

/// The immutable, planner-owned set of source paths that may be erased after
/// execution. Execution never walks the source volume looking for extra files.
nonisolated struct EraseManifest: Equatable, Sendable {
    let entries: [EraseManifestEntry]

    var count: Int {
        entries.count
    }

    static func from(
        planEntries: [MediaOperationPlanEntry],
        sourceMedia: [PlanningFileFacts] = []
    ) -> Self {
        var byPath: [MediaRelativePath: EraseManifestEntry] = [:]
        for entry in planEntries {
            // A content match is eligible here and re-checked against the catalog at erase
            // time (`MediaImportExecutor.sourceDeletionCandidates`): the library row it
            // matched may have gone since the plan was built.
            let eligible = switch entry.disposition {
            case .copy, .skipPreexisting, .skipInLibrary, .excluded: true
            case .blocked: false
            }
            guard eligible else { continue }
            byPath[entry.source.relativePath] = EraseManifestEntry(
                relativePath: entry.source.relativePath,
                byteSize: entry.source.byteSize,
                fileClass: .classify(relativePath: entry.source.relativePath)
            )
            for companion in entry.source.companions {
                byPath[companion.relativePath] = EraseManifestEntry(
                    relativePath: companion.relativePath,
                    byteSize: companion.byteSize,
                    fileClass: .classify(relativePath: companion.relativePath)
                )
            }
        }
        for fact in sourceMedia {
            let fileClass = SourceFileClass.classify(relativePath: fact.relativePath)
            let eligible = switch fileClass {
            case .usefulSidecar, .cruftSidecar, .sourceArtifact: true
            case .media, .unknown: false
            }
            guard eligible, byPath[fact.relativePath] == nil
            else { continue }
            byPath[fact.relativePath] = EraseManifestEntry(
                relativePath: fact.relativePath,
                byteSize: fact.byteSize,
                fileClass: fileClass
            )
        }
        return EraseManifest(entries: byPath.values.sorted { $0.relativePath.rawValue < $1.relativePath.rawValue })
    }
}

nonisolated func throughputMBps(bytes: Int64, elapsedMs: Int) -> String {
    let megabytes = Double(bytes) / 1_000_000
    return String(format: "%.2f", megabytes / (Double(max(elapsedMs, 1)) / 1000))
}

nonisolated func elapsedMilliseconds(
    from start: ContinuousClock.Instant,
    to end: ContinuousClock.Instant
) -> String {
    "\(DiagnosticsTiming.milliseconds(from: start, to: end))"
}

/// A byte total that may leave some items unsized: `knownBytes` sums the sizes that are
/// known and `unknownCount` counts the items whose size is not. It is exact only when
/// nothing is unsized, and a lower bound otherwise; an unknown size is never taken as zero.
nonisolated struct PartialByteCount: Equatable, Sendable, ExpressibleByIntegerLiteral {
    var knownBytes: Int64
    var unknownCount: Int

    static let zero = PartialByteCount(knownBytes: 0, unknownCount: 0)

    init(knownBytes: Int64, unknownCount: Int) {
        self.knownBytes = knownBytes
        self.unknownCount = unknownCount
    }

    /// An exact count: every size known.
    init(integerLiteral value: Int64) {
        self.init(knownBytes: value, unknownCount: 0)
    }

    init(sizes: some Sequence<Int64?>) {
        self = .zero
        for size in sizes {
            add(size)
        }
    }

    var isExact: Bool {
        unknownCount == 0
    }

    mutating func add(_ size: Int64?) {
        if let size {
            knownBytes += size
        } else {
            unknownCount += 1
        }
    }

    static func + (lhs: PartialByteCount, rhs: PartialByteCount) -> PartialByteCount {
        PartialByteCount(knownBytes: lhs.knownBytes + rhs.knownBytes, unknownCount: lhs.unknownCount + rhs.unknownCount)
    }
}

nonisolated struct MediaOperationPlanTotals: Equatable, Sendable {
    var copyCount: Int
    /// Items not copied because a library already holds them: at their destination path, or
    /// by content anywhere in a library.
    var skipCount: Int
    /// The part of `skipCount` held by a library other than the destination, so the bar
    /// says where they are truthfully (`import-bar.md`).
    var skipElsewhereCount: Int
    var blockedCount: Int
    var companionCopyCount: Int
    /// The sizes of the items to copy that the plan knows. An item whose size is unknown
    /// is counted in `unknownSizeCopyCount` instead, and the executor refuses it before it
    /// copies a byte, so this is what the run can copy.
    var copyBytes: Int64
    var unknownSizeCopyCount: Int
    var excludedCount: Int

    /// What the items to copy weigh, as far as it is known.
    var copyByteCount: PartialByteCount {
        PartialByteCount(knownBytes: copyBytes, unknownCount: unknownSizeCopyCount)
    }

    init(
        copyCount: Int,
        skipCount: Int,
        blockedCount: Int,
        companionCopyCount: Int,
        copyBytes: Int64,
        unknownSizeCopyCount: Int = 0,
        excludedCount: Int = 0,
        skipElsewhereCount: Int = 0
    ) {
        self.copyCount = copyCount
        self.skipCount = skipCount
        self.skipElsewhereCount = skipElsewhereCount
        self.blockedCount = blockedCount
        self.companionCopyCount = companionCopyCount
        self.copyBytes = copyBytes
        self.unknownSizeCopyCount = unknownSizeCopyCount
        self.excludedCount = excludedCount
    }
}

nonisolated struct MediaOperationPlan: Equatable, Sendable {
    let generation: UInt64
    let mode: MediaOperationMode
    let sourceNamespaceRevision: UInt64
    let sourceNamingRevision: UInt64
    let destinationNamespaceRevision: UInt64
    let policy: ImportPolicy
    let entries: [MediaOperationPlanEntry]
    let eraseManifest: EraseManifest
    let totals: MediaOperationPlanTotals

    init(
        generation: UInt64,
        mode: MediaOperationMode,
        sourceNamespaceRevision: UInt64,
        sourceNamingRevision: UInt64,
        destinationNamespaceRevision: UInt64,
        policy: ImportPolicy,
        entries: [MediaOperationPlanEntry],
        eraseManifest: EraseManifest? = nil,
        totals: MediaOperationPlanTotals
    ) {
        self.generation = generation
        self.mode = mode
        self.sourceNamespaceRevision = sourceNamespaceRevision
        self.sourceNamingRevision = sourceNamingRevision
        self.destinationNamespaceRevision = destinationNamespaceRevision
        self.policy = policy
        self.entries = entries
        self.eraseManifest = eraseManifest ?? EraseManifest.from(planEntries: entries)
        self.totals = totals
    }

    /// Blocked entries' identities and reasons, for state D's "Show them"
    /// (`import-bar.md` state D). `totals.blockedCount` is a count only; this is
    /// what lets the ViewModel select and scroll the affected tiles.
    var attentionItems: [MediaAttentionItem] {
        entries.compactMap { entry in
            guard case let .blocked(reason) = entry.disposition else { return nil }
            return MediaAttentionItem(id: entry.source.id, reason: reason)
        }
    }
}

/// The pair of revisions an import plan's staleness is judged against, sampled
/// together so the two halves cannot be read across a suspension.
nonisolated struct RootPlanningRevisions: Equatable, Sendable {
    let namespaceRevision: UInt64
    let namingRevision: UInt64
}

/// Import-planning wake published on the Store's planning-change stream. Carries
/// both of the root's planning revisions so the import coordinator can decide, per
/// role, whether this wake invalidates anything:
///
/// - `namespaceRevision` — which paths the root occupies. Invalidates a plan that
///   reads this root as **source or destination**.
/// - `namingRevision` — what Otos would call this root's assets. Invalidates a plan
///   that reads this root as **source only**; enriching an asset already in the
///   destination renames nothing on disk (ARC-046).
///
/// The Store emits one only for a root an import plans against (a card, a camera or a
/// library; never an Immich account) and only when one of the two moved: `planRevision`,
/// which only reorganization reads, wakes no one.
nonisolated struct RootPlanningChange: Equatable, Sendable {
    let rootPath: LibraryRootPath
    let namespaceRevision: UInt64
    let namingRevision: UInt64

    var revisions: RootPlanningRevisions {
        RootPlanningRevisions(namespaceRevision: namespaceRevision, namingRevision: namingRevision)
    }
}

/// Per-source import lifecycle published to the footer (ARC-047).
nonisolated enum MediaOperationSourceState: Equatable, Sendable {
    case inventory
    case waitingForMetadata(done: Int, total: Int)
    case planning
    case ready(
        summary: MediaOperationPlanTotals,
        generation: UInt64,
        skippedPackageCount: Int,
        attentionItems: [MediaAttentionItem] = []
    )
    case executing(progress: MediaOperationProgress)
    case completed(
        summary: MediaOperationPlanTotals,
        skippedForeignCount: Int = 0,
        failedCount: Int = 0,
        incompleteItems: [MediaAssetID] = []
    )
    /// A run the user started ended in failure (`import-bar.md` state G,
    /// "Couldn't finish the import").
    case failed(reason: MediaOperationFailureReason, publishedCount: Int = 0)
    /// No plan could be made, so nothing was attempted — the destination folder
    /// stayed unreadable past the retry budget, a root vanished between the wake
    /// and the snapshot, or the builder threw. Distinct from `failed` because the
    /// bar names the stage honestly: "Couldn't prepare the import", never
    /// "finish" for a run that never started (state G, planning variant).
    case planningFailed(reason: MediaOperationFailureReason)
    /// Source kind cannot execute import (for example a fixed library selected as source).
    case executionUnavailable(
        summary: MediaOperationPlanTotals,
        generation: UInt64,
        attentionItems: [MediaAttentionItem] = []
    )
}

nonisolated struct MediaOperationProgress: Equatable, Sendable {
    let completedCount: Int
    let totalCount: Int
    let completedBytes: Int64
    let totalBytes: Int64
    /// Milliseconds since this execution started. The time base `import-bar.md`
    /// state E needs to compute "about N seconds left" from bytes-over-elapsed;
    /// the mapper omits the estimate until this and `completedBytes` are large
    /// enough for a rate to be meaningful, never guessing one.
    let elapsedMs: Int

    /// Whether this sample would move either counter backwards relative to `other`.
    ///
    /// Both counters are monotonic where they are produced (`ByteProgressTracker`), so a
    /// decrease in either never means progress reversed — it identifies a sample that lost
    /// its ordering in transit between the worker thread that computed it and the actor
    /// that applies it. Stating the rule on the type keeps it with the values it constrains,
    /// rather than leaving each consumer to rediscover that these samples can arrive
    /// shuffled.
    nonisolated func isStale(comparedTo other: MediaOperationProgress) -> Bool {
        completedBytes < other.completedBytes || completedCount < other.completedCount
    }
}

/// Process-local identity of one removable-source attachment. It is owned by
/// `CatalogStore` and carried through operation publication; it is not durable
/// media identity and never becomes a card fingerprint or sidecar value.
nonisolated struct MediaOperationAttachmentGeneration: Equatable, Hashable, Sendable {
    let rawValue: UInt64
}

nonisolated struct MediaOperationSourcePresentation: Equatable, Sendable, Identifiable {
    let sourcePath: LibraryRootPath
    let attachmentGeneration: MediaOperationAttachmentGeneration
    /// Chooses "the camera" vs. "the card" wording while preparing
    /// (`import-bar.md` state A) without the mapper re-deriving it.
    let sourceKind: LibraryRootKind
    let destinationPath: LibraryRootPath?
    /// The destination library's display name, so the bar states it without a
    /// second lookup at the view layer (`import-bar.md` "What the presentation
    /// must carry").
    let destinationDisplayName: String?
    let state: MediaOperationSourceState
    /// Import was pressed and the coordinator is holding the click until the
    /// plan is ready (`queueImport` on a session that is not `.ready`, or a
    /// Ready plan that went stale before execution began). Not a state: the
    /// bar keeps drawing whatever `state` says — count, track and choices
    /// included — and disables Import, which is the click's acknowledgement
    /// (`import-bar.md` row 7). Cleared when execution starts or the request
    /// is refused.
    let importRequested: Bool
    let attachToReadyMs: Int?
    /// The batch this attachment's run is copying into, present only while it
    /// executes and once the batch holds at least one durably-published asset
    /// — the moment its sidebar row exists. The batch row's progress indicator
    /// reads it (`import-bar.md` "Ownership of status"); the bar itself is drawn
    /// only on the card's row and never needs it.
    let batchID: ImportBatchID?
    /// Count copied by the most recent *settled* (completed or cancelled)
    /// execution in this attachment, and whether that run was fully clean (no
    /// skips, failures, or blocked entries) — the auto-dismiss gate. Both
    /// persist across the post-settlement re-plan so state F keeps reporting
    /// what it just copied instead of that fact vanishing once `state` leaves
    /// `.completed`; `nil` until the first execution in this attachment
    /// settles (`import-bar.md` "What the presentation must carry").
    ///
    /// Deliberately independent of a *subsequently failed* retry: if a clean
    /// run lands 5 items and a later retry in the same attachment fails before
    /// copying anything, these still report the 5 that really did land —
    /// `state`'s own `.failed(reason:publishedCount:)` carries that failed
    /// attempt's own count separately (`import-bar.md` state G: "nothing
    /// already copied is lost").
    let copiedJustNow: Int?
    /// Whether that same settled run was fully clean — the choice between
    /// state F's clean wording and its incomplete or still-blocked variants.
    let isFullyClean: Bool?
    /// Why that same settled execution stopped before attempting everything it
    /// planned, or `nil` for a run that attempted every entry (whether or not
    /// every entry landed). Set, the bar draws state F's Stopped variant from
    /// this and `copiedJustNow` of `plannedCount` — the run's own facts, not the
    /// re-plan's, which describes the remainder and moves if the card gains
    /// files. Persists across the post-settlement re-plan like the rest of the
    /// completion (`import-bar.md` state F, Stopped).
    let stopReason: ImportStopReason?
    /// How many entries that same settled execution set out to copy — the "of
    /// 42" in `Stopped — 12 of 42 items copied`. `nil` exactly when
    /// `copiedJustNow` is.
    let plannedCount: Int?
    /// The destination volume's available capacity, sampled by the coordinator
    /// when this Ready presentation was published, so the bar can say *before*
    /// the click that not everything will fit (`import-bar.md` state C). A
    /// measured value with the same reader the floor uses, not a forecast:
    /// stale by construction, it gates nothing, and the Stopped bar states what
    /// actually happened afterwards (ADR 0027). `nil` when the volume did not
    /// answer or the state has no plan to compare against.
    let destinationAvailableBytes: Int64?
    /// This attachment's live session preferences, read directly off the
    /// coordinator's own `SourceSession.preferences` rather than mirrored into a
    /// second ViewModel-owned dictionary. `setSessionPreferences` writes only to
    /// the coordinator; the next `publish()` carrying the new value here is the
    /// confirmation — eliminates the two-owner race where a per-frame refresh
    /// could revert an in-flight optimistic write.
    let sessionPreferences: ImportPreferences
    /// Items from that same settled execution that started but did not land —
    /// failed mid-copy, or skipped because an identical file already exists in
    /// a *different* library — so state F's incomplete variant can select and
    /// scroll them the same way state D does for blocked items
    /// (`import-bar.md` state F, "couldn't be copied · Show them"). Blocked
    /// entries (never attempted; state D) are a separate population with their
    /// own reason and are not included here. Persists across the
    /// post-settlement re-plan alongside `copiedJustNow`/`isFullyClean`.
    let incompleteItems: [MediaAssetID]
    let eraseOutcome: EraseOutcome?

    init(
        sourcePath: LibraryRootPath,
        attachmentGeneration: MediaOperationAttachmentGeneration = .init(rawValue: 0),
        sourceKind: LibraryRootKind,
        destinationPath: LibraryRootPath?,
        destinationDisplayName: String?,
        state: MediaOperationSourceState,
        importRequested: Bool = false,
        attachToReadyMs: Int?,
        batchID: ImportBatchID?,
        copiedJustNow: Int?,
        isFullyClean: Bool?,
        stopReason: ImportStopReason?,
        plannedCount: Int?,
        destinationAvailableBytes: Int64? = nil,
        sessionPreferences: ImportPreferences,
        incompleteItems: [MediaAssetID],
        eraseOutcome: EraseOutcome? = nil
    ) {
        self.sourcePath = sourcePath
        self.attachmentGeneration = attachmentGeneration
        self.sourceKind = sourceKind
        self.destinationPath = destinationPath
        self.destinationDisplayName = destinationDisplayName
        self.state = state
        self.importRequested = importRequested
        self.attachToReadyMs = attachToReadyMs
        self.batchID = batchID
        self.copiedJustNow = copiedJustNow
        self.isFullyClean = isFullyClean
        self.stopReason = stopReason
        self.plannedCount = plannedCount
        self.destinationAvailableBytes = destinationAvailableBytes
        self.sessionPreferences = sessionPreferences
        self.incompleteItems = incompleteItems
        self.eraseOutcome = eraseOutcome
    }

    var id: String {
        "\(sourcePath.rawValue)#\(attachmentGeneration.rawValue)"
    }
}

nonisolated enum NamespaceOccupancyResult: Equatable, Sendable {
    case absent
    case regularFile(byteSize: Int64?, contentModifiedAt: Date?)
    case foreign(kind: ForeignOccupantKind)
}

nonisolated enum ForeignOccupantKind: String, Equatable, Sendable {
    case symlink
    case directory
    case package
    case other
}

nonisolated struct ImportPlanningSnapshot: Equatable, Sendable {
    let generation: UInt64
    let sourceRoot: LibraryRootPath
    let destinationRoot: LibraryRootPath
    let sourceNamespaceRevision: UInt64
    let sourceNamingRevision: UInt64
    let destinationNamespaceRevision: UInt64
    let sourceMedia: [PlanningFileFacts]
    let destinationOccupants: [MediaRelativePath: DestinationOccupantFacts]
    let destinationOccupantKeys: Set<FilesystemNameKey>
    /// Every current digest the fixed libraries hold, and one library holding it — only rows
    /// in an available library, not pending trash, with a digest current for their file.
    let libraryContent: [ContentDigest: LibraryRootPath]
    let policy: ImportPolicy
    let calendar: Calendar
    let timeZone: TimeZone
    let destinationCapabilities: VolumeNamespaceCapabilities

    init(
        generation: UInt64,
        sourceRoot: LibraryRootPath,
        destinationRoot: LibraryRootPath,
        sourceNamespaceRevision: UInt64,
        sourceNamingRevision: UInt64,
        destinationNamespaceRevision: UInt64,
        sourceMedia: [PlanningFileFacts],
        destinationOccupants: [MediaRelativePath: DestinationOccupantFacts],
        libraryContent: [ContentDigest: LibraryRootPath] = [:],
        policy: ImportPolicy,
        calendar: Calendar,
        timeZone: TimeZone,
        destinationCapabilities: VolumeNamespaceCapabilities
    ) {
        self.generation = generation
        self.sourceRoot = sourceRoot
        self.destinationRoot = destinationRoot
        self.sourceNamespaceRevision = sourceNamespaceRevision
        self.sourceNamingRevision = sourceNamingRevision
        self.destinationNamespaceRevision = destinationNamespaceRevision
        self.sourceMedia = sourceMedia
        self.destinationOccupants = destinationOccupants
        destinationOccupantKeys = Set(destinationOccupants.keys.map {
            FilesystemNamespaceSemantics.nameKey(relativePath: $0, capabilities: destinationCapabilities)
        })
        self.libraryContent = libraryContent
        self.policy = policy
        self.calendar = calendar
        self.timeZone = timeZone
        self.destinationCapabilities = destinationCapabilities
    }
}

/// Complete live occupancy for the destination folders an import plan can touch.
///
/// Import planning needs to know which candidate names are free. Candidate folders
/// are derivable from source facts plus policy alone (a suffix changes the file
/// name, never the folder), so every question a plan can ask is answered by
/// enumerating that bounded folder set once. The planner then runs as one pure
/// pass instead of a probe-per-candidate fixed point.
///
/// Absence is a claim about a folder that was actually read: `occupancy(of:)`
/// returns `nil` for a path whose folder was never enumerated, so a caller can
/// never silently mistake ignorance for a free name.
nonisolated struct DestinationNamespace: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        let path: MediaRelativePath
        let result: NamespaceOccupancyResult
    }

    private let entries: [FilesystemNameKey: Entry]
    private let enumeratedFolders: Set<String>
    /// Folders that exist but could not be listed, with the error each gave.
    /// Absence is a claim about a folder that was actually read (ADR 0019);
    /// these were not, so every candidate in them answers `nil` — and the
    /// coordinator treats a build carrying any of these as a transient
    /// condition to retry, not a plan to present.
    let unreadableFolders: [String: String]
    /// Folders a file makes impossible: the file holds the folder's own name or an
    /// ancestor's, keyed by folder, valued by that file's path. A fact about the
    /// library, not a failed read, so it blocks the candidates in it rather than
    /// being retried.
    let occupiedFolders: [String: String]
    let capabilities: VolumeNamespaceCapabilities

    init(
        entries: [MediaRelativePath: NamespaceOccupancyResult],
        enumeratedFolders: Set<String>,
        unreadableFolders: [String: String] = [:],
        occupiedFolders: [String: String] = [:],
        capabilities: VolumeNamespaceCapabilities
    ) {
        var keyed: [FilesystemNameKey: Entry] = [:]
        for (path, result) in entries {
            let key = FilesystemNamespaceSemantics.nameKey(relativePath: path, capabilities: capabilities)
            if keyed[key] != nil {
                keyed[key] = Entry(path: path, result: .foreign(kind: .other))
            } else {
                keyed[key] = Entry(path: path, result: result)
            }
        }
        self.entries = keyed
        self.enumeratedFolders = enumeratedFolders
        self.unreadableFolders = unreadableFolders
        self.occupiedFolders = occupiedFolders
        self.capabilities = capabilities
    }

    /// The file that makes `relativePath`'s folder impossible, if one does.
    func folderOccupant(of relativePath: MediaRelativePath) -> String? {
        occupiedFolders[relativePath.folder]
    }

    static let empty = DestinationNamespace(entries: [:], enumeratedFolders: [], capabilities: .unknown)

    var entryCount: Int {
        entries.count
    }

    var folderCount: Int {
        enumeratedFolders.count
    }

    /// Live occupancy of one candidate, or `nil` when its folder was not enumerated.
    func occupancy(of relativePath: MediaRelativePath) -> NamespaceOccupancyResult? {
        let key = FilesystemNamespaceSemantics.nameKey(relativePath: relativePath, capabilities: capabilities)
        if let entry = entries[key] {
            return entry.result
        }
        guard enumeratedFolders.contains(Self.folder(of: relativePath)) else {
            return nil
        }
        return .absent
    }

    /// Folder component under the destination root; `""` addresses the root itself,
    /// matching `ImportNaming.folder` under `DestinationFolderPolicy.none`.
    static func folder(of relativePath: MediaRelativePath) -> String {
        relativePath.folder
    }
}
