import Foundation
import OSLog

/// What Otos knows of an account's sync (ADR 0046 §6): what its server last answered,
/// whether a pass is applying its stream now, and when a pass last applied it to its end.
/// Learned from requests, never assumed from elapsed time.
nonisolated struct ImmichAccountStatus: Equatable, Sendable {
    /// What the server last answered.
    enum Reach: Equatable, Sendable {
        /// No pass has answered yet this launch.
        case connecting
        /// The server answered: the running pass has applied a batch of its stream, or the
        /// last pass applied it to its end.
        case online
        /// The last request did not reach a server that answered. The account's rows,
        /// thumbnails and previews stay browsable.
        case offline
        /// The server refused the session (logged out, revoked), or the account has no
        /// saved session Otos can read. Signing in again saves a new one and resumes it.
        case signedOut
    }

    var reach: Reach
    /// A pass whose server answered is running: applying its stream, then fetching the
    /// server's images for the rows still owed them.
    var isSyncing = false
    /// When a pass last applied the stream to its end, kept across launches; nil when none
    /// has, or when the catalog could not say (logged), which the status shows alike: it
    /// then names no time.
    var lastSynced: Date?
}

/// What adding an account did, in the terms the sheet shows.
nonisolated enum ImmichAddAccountOutcome: Equatable, Sendable {
    case added(LibraryRootPath)
    /// The address is not an http or https URL with a host.
    case invalidServer
    /// Nothing answered at the address.
    case unreachable
    /// The address answered, but not as Immich's API.
    case notImmich
    /// The server is an Immich major version Otos does not speak.
    case unsupportedVersion(major: Int)
    case wrongCredentials
    /// The session was opened but could not be kept: the Keychain or the catalog refused.
    case notSaved
}

/// Immich accounts guide
///
/// The one owner of every Immich account's session and sync (ADR 0046 §5, §6). It adds
/// an account by logging in, keeps its token in the Keychain, runs one
/// `ImmichCatalogSync` loop per account, and learns each account's status from that
/// loop's pass outcomes. After a pass it rings the next one on a timer: a poll while the
/// server answers, because Immich offers no change notification a native client can
/// subscribe to, and a growing backoff while it does not. A refused session stops the
/// account's passes until it signs in again. Each report names the sync it came from, so
/// a loop being replaced (signing in again) never speaks for its successor.
///
/// Statuses are published newest-wins on `statuses` for the window to show.
actor ImmichAccounts {
    struct Schedule: Sendable {
        /// Between passes while the server answers.
        let poll: Duration
        /// Between passes while it does not, growing to the last.
        let backoff: [Duration]

        static let production = Schedule(
            poll: .seconds(300),
            backoff: [.seconds(15), .seconds(30), .seconds(60), .seconds(120), .seconds(300)]
        )
    }

    private struct Account {
        let root: LibraryRoot
        let client: ImmichClient
        let token: String
        let sync: ImmichCatalogSync
        let loop: Task<Void, Never>
        var timer: Task<Void, Never>?
        var failures = 0
    }

    nonisolated let statuses: AsyncStream<[LibraryRootPath: ImmichAccountStatus]>
    private let publish: AsyncStream<[LibraryRootPath: ImmichAccountStatus]>.Continuation
    /// Answering facts for the Store, in the order the statuses changed: one consumer, so
    /// an outage and a recovery never reach the Store reversed.
    private let storeUpdates: AsyncStream<@Sendable () async -> Void>.Continuation
    private let storeUpdateLoop: Task<Void, Never>

    private let store: CatalogStore
    private let sessions: any ImmichSessionStoring
    private let urlSession: URLSession
    /// Reads a volume's free space for the floor every account's sync keeps (ADR 0027).
    private let volumeCapacity: VolumeCapacityReader
    private let schedule: Schedule
    /// Where new accounts' staging folders go: the app's Caches `RemoteStaging`, or a test's
    /// own folder.
    private let stagingContainer: URL
    private let clock = ContinuousClock()
    private var accounts: [LibraryRootPath: Account] = [:]
    private var status: [LibraryRootPath: ImmichAccountStatus] = [:]

    init(
        store: CatalogStore,
        sessions: any ImmichSessionStoring = ImmichKeychainSessionStore(),
        urlSession: URLSession = .shared,
        schedule: Schedule = .production,
        stagingContainer: URL = StagingLocation.containerURL(.remote),
        volumeCapacity: @escaping VolumeCapacityReader
    ) {
        self.volumeCapacity = volumeCapacity
        self.stagingContainer = stagingContainer
        self.store = store
        self.sessions = sessions
        self.urlSession = urlSession
        self.schedule = schedule
        (statuses, publish) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (updates, continuation) = AsyncStream<@Sendable () async -> Void>.makeStream(bufferingPolicy: .unbounded)
        storeUpdates = continuation
        storeUpdateLoop = Task {
            for await update in updates {
                await update()
            }
        }
    }

    /// Starts every saved account's sync: one with a saved session at once, one without
    /// as signed out. Each account's staging tree is claimed, signed in or not, so another
    /// instance's sweep never deletes originals this one staged.
    func start() async {
        let roots = await store.currentLibraries().map(\.root).filter { $0.remoteBaseURL != nil }
        for root in roots {
            StagingLocation.claimOwnership(of: root.path.url)
        }
        for root in roots where accounts[root.path] == nil {
            let token: String?
            do {
                token = try root.deviceIdentity.flatMap(sessions.token(for:))
            } catch {
                OtosLog.catalog.errorOperation("immich.session", phase: "readFailed", fields: [
                    "rootPath": root.path.rawValue, "error": String(describing: error),
                ])
                token = nil
            }
            let lastSynced = await lastSynced(of: root.path)
            // Read after the await: an account added meanwhile already runs.
            guard accounts[root.path] == nil else {
                continue
            }
            if let token, let server = root.remoteBaseURL {
                begin(root, token: token, server: server, lastSynced: lastSynced)
            } else {
                update(ImmichAccountStatus(reach: .signedOut, lastSynced: lastSynced), for: root.path)
            }
        }
    }

    /// Logs in, checks the server speaks Immich's supported major version, adds the
    /// account's root, saves its session, and starts its sync. Signing in again to an
    /// account Otos already has replaces its session and resumes it.
    ///
    /// A new session's cursor is empty, and nothing establishes that the server resets it
    /// (its age check skips a session that never completed a stream,
    /// `docs/research/2026-11-13-immich-sync-reset.md`), so the stream it starts proves
    /// nothing about rows it does not list: deletions while signed out, past the server's
    /// audit retention, would never be purged. A full resync is recorded as owed before the
    /// session is saved, so the first pass of every session reads the stream from zero and
    /// purges what it no longer lists.
    func add(server: URL, email: String, password: String) async -> ImmichAddAccountOutcome {
        guard let address = ImmichServerAddress.normalized(server) else {
            return .invalidServer
        }
        let client = ImmichClient(server: address, session: urlSession)
        let login: ImmichLogin
        do {
            let version = try await client.serverVersion()
            guard version.major == ImmichClient.supportedMajorVersion else {
                return .unsupportedVersion(major: version.major)
            }
            login = try await client.login(email: email, password: password)
        } catch let error as ImmichClientError {
            return Self.addOutcome(error)
        } catch {
            return .notImmich
        }
        let rootPath: LibraryRootPath
        do {
            rootPath = try await store.addImmichAccount(
                server: address, userID: login.userID, displayName: login.name, stagingContainer: stagingContainer
            )
            guard let root = await store.currentLibraries().first(where: { $0.path == rootPath })?.root,
                  let identity = root.deviceIdentity
            else {
                return .notSaved
            }
            StagingLocation.claimOwnership(of: root.path.url)
            try await store.requestSourceResync(rootPath: rootPath)
            try sessions.saveToken(login.accessToken, for: identity)
            let lastSynced = await lastSynced(of: rootPath)
            stop(rootPath)
            begin(root, token: login.accessToken, server: address, lastSynced: lastSynced)
        } catch {
            OtosLog.catalog.errorOperation("immich.account.add", phase: "notSaved", fields: [
                "server": address.absoluteString, "error": String(describing: error),
            ])
            return .notSaved
        }
        OtosLog.catalog.noticeOperation("immich.account.add", phase: "finish", fields: [
            "rootPath": rootPath.rawValue, "server": address.absoluteString,
        ])
        return .added(rootPath)
    }

    /// Ends an account before its root is removed: stops its sync, releases its staging
    /// tree, logs its session out when the server answers, and deletes its Keychain item. A
    /// root that is not an account is left alone.
    func forget(_ root: LibraryRoot) async {
        guard let identity = root.deviceIdentity, let server = root.remoteBaseURL else {
            return
        }
        stop(root.path)
        StagingLocation.releaseOwnership(of: root.path.url)
        status[root.path] = nil
        publish.yield(status)
        await answeringApplied(false, for: root.path)
        do {
            if let token = try sessions.token(for: identity) {
                do {
                    try await ImmichClient(server: server, session: urlSession).logout(token: token)
                } catch {
                    // The token is deleted either way; a server that is offline keeps a
                    // session nothing will use again.
                    OtosLog.catalog.noticeOperation("immich.account.forget", phase: "logoutFailed", fields: [
                        "rootPath": root.path.rawValue, "error": String(describing: error),
                    ])
                }
            }
            try sessions.deleteToken(for: identity)
        } catch {
            OtosLog.catalog.errorOperation("immich.account.forget", phase: "keychainFailed", fields: [
                "rootPath": root.path.rawValue, "error": String(describing: error),
            ])
        }
    }

    func shutdown() async {
        let running = accounts.values.map(\.loop)
        for path in Array(accounts.keys) {
            stop(path)
        }
        for loop in running {
            await loop.value
        }
        publish.finish()
        storeUpdates.finish()
        await storeUpdateLoop.value
    }

    // MARK: - Originals (ADR 0046 §4, §7)

    /// Downloads an account row's original into its staging folder, for work that needs
    /// its bytes: full-resolution zoom, an edit, export, hand-off. Background and device
    /// demand is refused: an account's originals are downloaded only when the user's work
    /// needs them, never to render a library (owner, 2026-11-09). A download that lands is
    /// handed to enrichment, which makes every product the row still owes from it.
    func downloadOriginal(_ request: MaterializationCoordinator.Request) async -> MaterializationResult {
        let started = ContinuousClock.now
        let id = request.id
        func result(_ outcome: MaterializationOutcome) -> MaterializationResult {
            MaterializationResult(
                outcome: outcome, rerequestCount: 0, elapsedMs: DiagnosticsTiming.milliseconds(since: started)
            )
        }
        switch request.priority {
        case .interactive, .command:
            break
        case .background, .device:
            OtosLog.mediaIO.noticeOperation("immich.original", phase: "refused", fields: [
                "reason": "notUserWork", "relativePath": id.relativePath.rawValue,
            ])
            return result(.requestFailed)
        }
        guard let assetID = await sourceItemID(for: id) else {
            OtosLog.mediaIO.noticeOperation("immich.original", phase: "refused", fields: [
                "reason": "notListed", "relativePath": id.relativePath.rawValue,
            ])
            return result(.requestFailed)
        }
        // Read after the lookup's await, so the session is the one current now.
        guard let account = accounts[id.libraryRootPath] else {
            OtosLog.mediaIO.noticeOperation("immich.original", phase: "refused", fields: [
                "reason": "noSession", "relativePath": id.relativePath.rawValue,
            ])
            return result(.requestFailed)
        }
        let downloaded: URL
        do {
            downloaded = try await account.client.downloadOriginal(assetID: assetID, token: account.token)
        } catch {
            return result(downloadFailed(error, for: id))
        }
        // Read after the download's await: an account forgotten or replaced meanwhile
        // places nothing into a folder that is no longer its.
        guard accounts[id.libraryRootPath]?.sync === account.sync else {
            ImmichClient.discardDownload(downloaded, op: "immich.original")
            OtosLog.mediaIO.noticeOperation("immich.original", phase: "refused", fields: [
                "reason": "accountChanged", "relativePath": id.relativePath.rawValue,
            ])
            return result(.requestFailed)
        }
        do {
            try await StagingLocation.placeDownloaded(downloaded, at: id.fileURL, inside: id.libraryRootPath.url)
        } catch {
            OtosLog.mediaIO.errorOperation("immich.original", phase: "placeFailed", fields: [
                "relativePath": id.relativePath.rawValue, "error": String(describing: error),
            ])
            return result(.requestFailed)
        }
        OtosLog.mediaIO.noticeOperation("immich.original", phase: "staged", fields: [
            "relativePath": id.relativePath.rawValue,
            "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: started))",
        ])
        await store.originalBecameLocal(id)
        return result(.materialized)
    }

    /// What a failed download tells the materializer: a server that did not answer is
    /// unavailable, a refused session signs the account out, anything else failed.
    private func downloadFailed(_ error: any Error, for id: MediaAssetID) -> MaterializationOutcome {
        OtosLog.mediaIO.noticeOperation("immich.original", phase: "failed", fields: [
            "relativePath": id.relativePath.rawValue, "error": String(describing: error),
        ])
        if error is CancellationError {
            return .cancelled
        }
        switch error as? ImmichClientError {
        case .unreachable:
            return .serverUnreachable
        case .unauthorized:
            setReach(.signedOut, for: id.libraryRootPath)
            return .requestFailed
        case .refused, .malformedResponse, .unsupportedVersion, nil:
            return .requestFailed
        }
    }

    // MARK: - Ranged reads (ADR 0046 §5)

    /// How enrichment reads an account row's original in ranges: through the account's
    /// session, and only while its server answers.
    nonisolated func rangeAccess() -> RemoteRangeAccess {
        RemoteRangeAccess(
            serves: { [weak self] rootPath in
                await self?.isAnswering(rootPath) ?? false
            },
            resolve: { [weak self] id, size in
                await self?.rangeReader(for: id, size: size)
            }
        )
    }

    private func isAnswering(_ rootPath: LibraryRootPath) -> Bool {
        accounts[rootPath] != nil && status[rootPath]?.reach == .online
    }

    private func rangeReader(for id: MediaAssetID, size: UInt64) async -> RemoteRangeReader? {
        guard let asset = await sourceItemID(for: id) else {
            return nil
        }
        // Read after the lookup's await, so the session and status are the current ones.
        guard let account = accounts[id.libraryRootPath], status[id.libraryRootPath]?.reach == .online else {
            return nil
        }
        let client = account.client
        let token = account.token
        return RemoteRangeReader(size: size) { offset, length, completion in
            client.originalRange(assetID: asset, token: token, offset: offset, length: length, completion: completion)
        }
    }

    /// The Immich asset a row is (ADR 0046 §2): its stored source item ID, never parsed
    /// from its path, because a Live Photo's motion part lives in its still's folder. Nil,
    /// logged, when the catalog cannot say.
    private func sourceItemID(for id: MediaAssetID) async -> String? {
        do {
            return try await store.sourceItemID(for: id)
        } catch {
            OtosLog.mediaIO.errorOperation("immich.sourceItem", phase: "readFailed", fields: [
                "relativePath": id.relativePath.rawValue, "error": String(describing: error),
            ])
            return nil
        }
    }

    // MARK: - Loops

    private func begin(_ root: LibraryRoot, token: String, server: URL, lastSynced: Date?) {
        let client = ImmichClient(server: server, session: urlSession)
        let sync = ImmichCatalogSync(
            rootPath: root.path,
            source: ImmichSessionSyncSource(client: client, token: token),
            store: store,
            volumeCapacity: volumeCapacity
        )
        let path = root.path
        // The loop holds the sync, never this owner: a weak reference per pass report.
        let loop = Task { [sync] in
            await sync.run { [weak self, weak sync] report in
                guard let sync else {
                    return
                }
                await self?.received(report, for: path, from: sync)
            }
        }
        accounts[path] = Account(root: root, client: client, token: token, sync: sync, loop: loop)
        update(ImmichAccountStatus(reach: .connecting, lastSynced: lastSynced), for: path)
        sync.requestSync()
    }

    private func stop(_ path: LibraryRootPath) {
        guard let account = accounts.removeValue(forKey: path) else {
            return
        }
        account.timer?.cancel()
        account.sync.finish()
        account.loop.cancel()
    }

    /// A report from `sync`'s loop. One from a loop the account no longer runs (stopped, or
    /// replaced by signing in again) is dropped: its outcome is about a session that is gone.
    private func received(_ report: ImmichSyncReport, for path: LibraryRootPath, from sync: ImmichCatalogSync) {
        guard accounts[path]?.sync === sync else {
            return
        }
        switch report {
        case .answered:
            serverAnswered(for: path)
        case .listed:
            listed(at: Date(), for: path)
        case let .ended(outcome):
            passEnded(outcome, for: path)
        }
    }

    /// A running pass's server answered, so the account is online and syncing before its
    /// pass ends.
    private func serverAnswered(for path: LibraryRootPath) {
        guard accounts[path] != nil, var current = status[path] else {
            return
        }
        current.reach = .online
        current.isSyncing = true
        update(current, for: path)
    }

    /// Records what the server answered and rings the next pass after the delay its
    /// answer calls for. A refused session or a loop torn down rings none; a root that could
    /// not get or keep its listing lease is retried, because nothing reports when it can.
    private func passEnded(_ outcome: ImmichSyncPassOutcome, for path: LibraryRootPath) {
        guard var account = accounts[path] else {
            return
        }
        account.timer?.cancel()
        account.timer = nil
        setReach(Self.reach(after: outcome, was: status[path]?.reach ?? .connecting), for: path)
        switch outcome {
        case .synced:
            account.failures = 0
            account.timer = poll(account.sync)
        case .serverFailed(.unauthorized), .stopped:
            break
        case .serverFailed, .resetLoop, .catalogFailed, .noLease:
            account.timer = retry(account.sync, after: account.failures)
            account.failures += 1
        }
        accounts[path] = account
    }

    /// What the server last answered, after a pass ended with `outcome`. Only a request
    /// that reached no server makes an account offline; a server that answered with a
    /// failure, or a failure of Otos's own, leaves what it last answered standing.
    nonisolated static func reach(
        after outcome: ImmichSyncPassOutcome,
        was current: ImmichAccountStatus.Reach
    ) -> ImmichAccountStatus.Reach {
        switch outcome {
        case .synced: .online
        case .serverFailed(.unauthorized): .signedOut
        case .serverFailed(.unreachable): .offline
        case .serverFailed, .resetLoop, .catalogFailed, .noLease, .stopped: current
        }
    }

    /// The next pass while the server answers.
    private func poll(_ sync: ImmichCatalogSync) -> Task<Void, Never> {
        let delay = schedule.poll
        return Task { [clock] in
            do {
                // time: poll — Immich offers a native client no change notification to wait on.
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            sync.requestSync()
        }
    }

    /// The next pass after `failures` failed ones, growing to the schedule's last delay.
    private func retry(_ sync: ImmichCatalogSync, after failures: Int) -> Task<Void, Never> {
        let delay = schedule.backoff[min(failures, schedule.backoff.count - 1)]
        return Task { [clock] in
            do {
                // time: backoff — nothing reports when a failing server, catalog or lease recovers.
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            sync.requestSync()
        }
    }

    /// A pass applied the stream to its end at `date`: the catalog is current with the
    /// server, so that is its last sync, kept in the catalog for the next launch. It is still
    /// syncing while it fetches the server's images.
    private func listed(at date: Date, for path: LibraryRootPath) {
        guard var current = status[path] else {
            return
        }
        current.reach = .online
        current.lastSynced = date
        update(current, for: path)
        let store = store
        storeUpdates.yield {
            do {
                try await store.recordSourceSynced(at: date, rootPath: path)
            } catch {
                OtosLog.catalog.errorOperation("immich.account.lastSynced", phase: "writeFailed", fields: [
                    "rootPath": path.rawValue, "error": String(describing: error),
                ])
            }
        }
    }

    /// A pass that ended without applying its stream: the server's answer, and no pass syncing.
    private func setReach(_ reach: ImmichAccountStatus.Reach, for path: LibraryRootPath) {
        guard var current = status[path] else {
            return
        }
        current.reach = reach
        current.isSyncing = false
        update(current, for: path)
    }

    /// Sends the Store's answering fact for `path` through the ordered update stream and
    /// returns once it is applied, so no earlier fact still queued lands after it.
    private func answeringApplied(_ answering: Bool, for path: LibraryRootPath) async {
        let store = store
        await withCheckedContinuation { (applied: CheckedContinuation<Void, Never>) in
            let sent = storeUpdates.yield {
                await store.setSourceAnswering(answering, for: path)
                applied.resume()
            }
            if case .terminated = sent {
                // Shut down: no update runs any more, so none can land after this one.
                applied.resume()
            }
        }
    }

    private func update(_ new: ImmichAccountStatus, for path: LibraryRootPath) {
        let old = status[path]
        guard old != new else {
            return
        }
        status[path] = new
        publishStatus(for: path)
        // Enrichment reads an account's originals in ranges only while its server answers;
        // the Store's answering fact is what stops claims during an outage.
        if old?.reach != new.reach {
            let answering = new.reach == .online
            let store = store
            storeUpdates.yield { await store.setSourceAnswering(answering, for: path) }
        }
    }

    private func publishStatus(for path: LibraryRootPath) {
        publish.yield(status)
        guard let current = status[path] else {
            return
        }
        OtosLog.catalog.noticeOperation("immich.account.status", phase: "changed", fields: [
            "rootPath": path.rawValue,
            "status": String(describing: current.reach),
            "syncing": "\(current.isSyncing)",
            "lastSynced": current.lastSynced.map { "\($0.timeIntervalSince1970)" } ?? "none",
        ])
    }

    /// The account's last complete pass, as the catalog keeps it; nil, logged, when the
    /// catalog cannot say (`ImmichAccountStatus.lastSynced`).
    private func lastSynced(of path: LibraryRootPath) async -> Date? {
        do {
            return try await store.sourceLastSynced(rootPath: path)
        } catch {
            OtosLog.catalog.errorOperation("immich.account.lastSynced", phase: "readFailed", fields: [
                "rootPath": path.rawValue, "error": String(describing: error),
            ])
            return nil
        }
    }

    private static func addOutcome(_ error: ImmichClientError) -> ImmichAddAccountOutcome {
        switch error {
        case .unreachable: .unreachable
        case .unauthorized: .wrongCredentials
        case .refused, .malformedResponse: .notImmich
        case let .unsupportedVersion(major): .unsupportedVersion(major: major)
        }
    }
}
