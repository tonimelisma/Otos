import Foundation
import OSLog

/// Duplicates Projection guide
/// This actor owns the catalog's duplicate groups (ADR 0042): identical copies by digest,
/// then versions of the same photo. The groups are a fact about the whole catalog, not about
/// what the window shows, so they have their own owner and their own loop: the window's
/// publication never waits for a build, and a change of scope, filter or sort never starts
/// one.
///
/// `CatalogProjection` asks for a build with `request()` after a publication that took up a
/// catalog change of a kind the groups are built from (`inputs`), so requests arrive no faster than the window's own cadence for store
/// changes. A request only adds to `requested`; a pass records the value it started from
/// and covers exactly that when its build succeeds, so a request made while a build runs is
/// never lost and runs next (ADR 0032). One loop task runs every pass off a
/// `bufferingNewest(1)` doorbell, so builds never overlap. A build reads the catalog
/// through the Store, then compares pixels off this actor (`@concurrent`), so a `request()`
/// never waits behind the comparison.
///
/// A build costs what changed (plan 0116 bet 3). It reads the identical copies and the
/// compared stills' column facts, both from indexes that hold only those rows, and leaves a
/// `SamePhotoMemory` for the next: what it paired from, which stills that joined, and the
/// evidence (render and sub-seconds) it read with the stamp each was read at. The next build
/// pairs again only when the stills, the identical copies or the reach differ, and reads
/// evidence only for a proposed still whose stamp moved. The copies a group lists are read
/// every build, for its members alone. The memory is this owner's: only a pass replaces it,
/// once its build succeeded, so a failed build leaves the last one.
///
/// A failed build publishes nothing and leaves its request outstanding for the next
/// request to retry. `stop()` is teardown: it ends both streams, so the loop and the
/// consumer end with them. Every build whose groups differ from the last published ones is
/// yielded on `builds`, which `CatalogProjection` merges into the window state.
actor DuplicatesProjection {
    typealias Builder = @Sendable (CatalogStore, [CatalogLibraryState]) async throws -> CatalogDuplicatesState

    /// What the groups are built from, so `CatalogProjection` asks for a build only when one
    /// of these moved: which rows are shown and which movies a Live Photo hides; digests and
    /// the copies they make; the user's choices; and `.duplicateFacts` — the reach, the pairs
    /// kept together, render signatures, and a date, kind, record or image of a row Duplicates
    /// compares or lists (`DuplicatesHoldSQL`). A write of those kinds to a row Duplicates
    /// cannot see — an Immich external asset's record, a video, a still with no signature —
    /// names no `.duplicateFacts`, so it does not ask for a build. Faces, places, search
    /// readings and enrichment's own stamps are not among them.
    static let inputs: CatalogChangedFacts = [.membership, .grouping, .copies, .duplicateFacts, .choices]

    /// Built groups, each differing from the one before; only the newest matters. One
    /// consumer: `CatalogProjection`.
    nonisolated let builds: AsyncStream<CatalogDuplicatesState>
    private nonisolated let buildsContinuation: AsyncStream<CatalogDuplicatesState>.Continuation
    private nonisolated let bell: AsyncStream<Void>
    private nonisolated let doorbell: AsyncStream<Void>.Continuation
    private let store: CatalogStore
    /// Tests replace the build to hold it at its suspension; production builds the groups.
    private let builder: Builder?
    /// Bumped by every request. Nothing decrements or clears it.
    private var requested: UInt64 = 0
    /// The `requested` value the last successful build started from.
    private var covered: UInt64 = 0
    private var runningPasses = 0
    private var published: CatalogDuplicatesState?
    /// What the last successful build leaves the next one.
    private var memory = SamePhotoMemory.empty
    private var loopTask: Task<Void, Never>?

    /// True when every request has been covered by a successful build and none is running.
    /// Lets a test wait for settlement instead of guessing a sleep duration.
    var isQuiescent: Bool {
        requested == covered && runningPasses == 0
    }

    /// Runs each build one heavy load at a time with the other owners' (`LoadAdmission`).
    private let admission: LoadAdmission

    init(store: CatalogStore, builder: Builder?, admission: LoadAdmission = LoadAdmission(isOpen: true)) {
        self.store = store
        self.builder = builder
        self.admission = admission
        (builds, buildsContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (bell, doorbell) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Starts the loop. It holds this owner weakly and ends when the doorbell finishes.
    func start() {
        guard loopTask == nil else {
            return
        }
        let bell = bell
        loopTask = Task { [weak self] in
            for await _ in bell {
                guard let self else {
                    return
                }
                await pass()
            }
        }
    }

    /// The catalog may have changed: the groups are owed a build.
    func request() {
        requested &+= 1
        doorbell.yield()
    }

    /// Teardown, callable from anywhere: ends the loop and the stream of builds. A build in
    /// flight finishes, and what it yields goes nowhere.
    nonisolated func stop() {
        doorbell.finish()
        buildsContinuation.finish()
    }

    private func pass() async {
        guard requested != covered else {
            return
        }
        runningPasses += 1
        defer { runningPasses -= 1 }
        let startedFrom = requested
        let built: CatalogDuplicatesState
        do {
            // Before the catalog's first load there is nothing to build; the load is a
            // catalog change, so a request follows it.
            guard let libraries = await store.loadedLibraries() else {
                return
            }
            // One heavy load at a time with the other owners, none before the first grid.
            built = try await admission.run(.duplicates) {
                if let builder {
                    return try await builder(store, libraries)
                }
                let result = try await Self.build(store: store, libraries: libraries, memory: memory)
                try Task.checkCancellation()
                // The only writer of `memory` is this loop's pass, one at a time.
                memory = result.memory
                return result.state
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            return
        } catch {
            OtosLog.catalog.errorOperation("duplicates.build", phase: "failed", fields: [
                "error": String(describing: error),
            ])
            return
        }
        // Synchronous from here: nothing interleaves between covering the request and
        // publishing what covers it.
        covered = startedFrom
        if built != published {
            published = built
            buildsContinuation.yield(built)
        }
        if requested != covered {
            doorbell.yield()
        }
    }
}

/// What one build leaves the next (ADR 0042): the same-photo rule's inputs, the stills it
/// joined from them, and the evidence read for each proposed still with the stamp it was read
/// at. A build pairs again only when its inputs differ, and reads evidence only for a proposed
/// still whose stamp moved.
nonisolated struct SamePhotoMemory: Sendable {
    /// What the rule pairs from: the compared stills, the copies an identical group already
    /// holds, and the reach.
    struct Inputs: Equatable, Sendable {
        let candidates: [SamePhotoCandidate]
        let excluded: Set<MediaAssetID>
        let reach: DuplicatesReach
    }

    struct HeldEvidence: Sendable {
        let stamp: SamePhotoEvidenceStamp
        let evidence: SamePhotoEvidence
    }

    let pairedFrom: Inputs?
    let members: SamePhotoMembers
    let evidence: [MediaAssetID: HeldEvidence]

    static let empty = SamePhotoMemory(pairedFrom: nil, members: .none, evidence: [:])
}

extension DuplicatesProjection {
    /// A build's groups and what it leaves the next build.
    struct Built: Sendable {
        let state: CatalogDuplicatesState
        let memory: SamePhotoMemory
        /// Whether the build paired the stills again, rather than keeping what the memory held.
        let paired: Bool
        /// How many stills' evidence the build read, rather than kept.
        let evidenceRead: Int
    }

    /// Duplicate groups in the available fixed libraries — within each, or across them, as
    /// the Store's reach says: identical copies by digest, then versions of the same photo
    /// among the rest — built from what `memory` holds where its inputs still hold.
    static func build(
        store: CatalogStore,
        libraries: [CatalogLibraryState],
        memory: SamePhotoMemory = .empty
    ) async throws -> Built {
        let signpost = OtosSignpost.performance.beginInterval("DuplicatesBuild")
        defer { OtosSignpost.performance.endInterval("DuplicatesBuild", signpost) }
        let start = ContinuousClock.now
        let availableLibraryPaths = CatalogWindowPolicy.availablePaths(from: libraries)
        let duplicates = try await store.duplicateCopies(availableLibraryPaths: availableLibraryPaths)
        let identical = DuplicateGroupPolicy.groups(
            copies: duplicates.copies, keptPairs: duplicates.keptPairs, reach: duplicates.reach
        )
        let identicalMs = DiagnosticsTiming.milliseconds(since: start)

        let candidatesStart = ContinuousClock.now
        let inputs = try await SamePhotoMemory.Inputs(
            candidates: store.samePhotoCandidates(availableLibraryPaths: availableLibraryPaths),
            excluded: Set(identical.flatMap(\.copies).map(\.id)),
            reach: duplicates.reach
        )
        let candidatesMs = DiagnosticsTiming.milliseconds(since: candidatesStart)

        let pairingStart = ContinuousClock.now
        let next: SamePhotoMemory
        var pairCount: Int?
        var evidenceRead = 0
        var evidenceKept = 0
        if inputs == memory.pairedFrom {
            next = memory
            evidenceKept = memory.evidence.count
        } else {
            let pairs = await proposePairs(inputs)
            pairCount = pairs.count
            let stamps = Dictionary(
                inputs.candidates.map { ($0.id, $0.evidenceStamp) }, uniquingKeysWith: { first, _ in first }
            )
            let involved = Set(pairs.flatMap { [$0.left.id, $0.right.id] })
            var held: [MediaAssetID: SamePhotoMemory.HeldEvidence] = [:]
            var owed: [MediaAssetID] = []
            for id in involved {
                guard let stamp = stamps[id] else { continue }
                if let kept = memory.evidence[id], kept.stamp == stamp {
                    held[id] = kept
                    evidenceKept += 1
                } else {
                    owed.append(id)
                }
            }
            if !owed.isEmpty {
                let fresh = try await store.samePhotoEvidence(for: owed)
                evidenceRead = owed.count
                for (id, evidence) in fresh {
                    if let stamp = stamps[id] {
                        held[id] = SamePhotoMemory.HeldEvidence(stamp: stamp, evidence: evidence)
                    }
                }
            }
            let members = await confirm(pairs, evidence: held.mapValues(\.evidence))
            next = SamePhotoMemory(pairedFrom: inputs, members: members, evidence: held)
        }
        let pairingMs = DiagnosticsTiming.milliseconds(since: pairingStart)

        let copiesStart = ContinuousClock.now
        let memberIDs = next.members.ids
        let copies = memberIDs.isEmpty ? [:] : try await store.samePhotoCopies(for: memberIDs)
        let samePhoto = SamePhotoPolicy.groups(next.members, copies: copies, keptPairs: duplicates.keptPairs)
        let copiesMs = DiagnosticsTiming.milliseconds(since: copiesStart)

        let groups = identical + samePhoto
        let state = CatalogDuplicatesState(groups: groups)
        OtosLog.catalog.debugOperation("duplicates.groups", phase: "built", fields: [
            "copies": "\(groups.reduce(0) { $0 + $1.copies.count })",
            "groups": "\(groups.count)",
            "kept": "\(state.keptGroups.count)",
            "preselected": "\(groups.count { !$0.isKept && $0.defaultKeep != nil })",
            "waiting": "\(groups.count { !$0.isKept && $0.defaultKeep == nil })",
            "samePhoto": "\(samePhoto.count)",
            "reach": "\(duplicates.reach)",
            "choose": "\(state.layout.choose.count)",
            "different": "\(state.layout.different.count)",
            "folders": "\(state.layout.buckets.count)",
            "stills": "\(inputs.candidates.count)",
            "pairing": pairCount == nil ? "held" : "paired",
            "pairs": pairCount.map { "\($0)" } ?? "held",
            "evidenceKept": "\(evidenceKept)",
            "evidenceRead": "\(evidenceRead)",
            "members": "\(memberIDs.count)",
            "identicalMs": "\(identicalMs)",
            "candidatesMs": "\(candidatesMs)",
            "pairingMs": "\(pairingMs)",
            "copiesMs": "\(copiesMs)",
            "totalMs": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
        return Built(state: state, memory: next, paired: pairCount != nil, evidenceRead: evidenceRead)
    }

    /// The column pass over every still, off the actor: a file without capture metadata is
    /// tested against its whole aspect bucket.
    @concurrent
    private static func proposePairs(_ inputs: SamePhotoMemory.Inputs) async -> [SamePhotoPair] {
        SamePhotoPolicy.candidatePairs(inputs.candidates, excluding: inputs.excluded, reach: inputs.reach)
    }

    /// The stills joined into versions of one photo from the proposed pairs, off the actor.
    @concurrent
    private static func confirm(
        _ pairs: [SamePhotoPair],
        evidence: [MediaAssetID: SamePhotoEvidence]
    ) async -> SamePhotoMembers {
        SamePhotoPolicy.members(pairs: pairs, evidence: evidence)
    }
}
