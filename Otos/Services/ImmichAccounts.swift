import Foundation
import OSLog

/// What an account's server last answered (ADR 0046 §6). Learned from requests, never
/// assumed from elapsed time.
nonisolated enum ImmichAccountStatus: Equatable, Sendable {
    /// No pass has answered yet this launch.
    case connecting
    /// The last pass reached the server and applied its stream.
    case online
    /// The last request did not reach a server that answered. The account's rows,
    /// thumbnails and previews stay browsable.
    case offline
    /// The server refused the session: logged out, revoked, or the account has no saved
    /// session. Signing in again resumes it.
    case signedOut
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
/// account's passes until it signs in again.
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
        let sync: ImmichCatalogSync
        let loop: Task<Void, Never>
        var timer: Task<Void, Never>?
        var failures = 0
    }

    nonisolated let statuses: AsyncStream<[LibraryRootPath: ImmichAccountStatus]>
    private let publish: AsyncStream<[LibraryRootPath: ImmichAccountStatus]>.Continuation

    private let store: CatalogStore
    private let sessions: any ImmichSessionStoring
    private let urlSession: URLSession
    private let schedule: Schedule
    private let clock = ContinuousClock()
    private var accounts: [LibraryRootPath: Account] = [:]
    private var status: [LibraryRootPath: ImmichAccountStatus] = [:]

    init(
        store: CatalogStore,
        sessions: any ImmichSessionStoring = ImmichKeychainSessionStore(),
        urlSession: URLSession = .shared,
        schedule: Schedule = .production
    ) {
        self.store = store
        self.sessions = sessions
        self.urlSession = urlSession
        self.schedule = schedule
        (statuses, publish) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Starts every saved account's sync: one with a saved session at once, one without
    /// as signed out.
    func start() async {
        let roots = await store.currentLibraries().map(\.root).filter { $0.remoteBaseURL != nil }
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
            if let token, let server = root.remoteBaseURL {
                begin(root, token: token, server: server)
            } else {
                setStatus(.signedOut, for: root.path)
            }
        }
    }

    /// Logs in, checks the server speaks Immich's supported major version, adds the
    /// account's root, saves its session, and starts its sync. Signing in again to an
    /// account Otos already has replaces its session and resumes it.
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
            rootPath = try await store.addImmichAccount(server: address, userID: login.userID, displayName: login.name)
            guard let root = await store.currentLibraries().first(where: { $0.path == rootPath })?.root,
                  let identity = root.deviceIdentity
            else {
                return .notSaved
            }
            try sessions.saveToken(login.accessToken, for: identity)
            stop(rootPath)
            begin(root, token: login.accessToken, server: address)
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

    /// Ends an account before its root is removed: stops its sync, logs its session out
    /// when the server answers, and deletes its Keychain item. A root that is not an
    /// account is left alone.
    func forget(_ root: LibraryRoot) async {
        guard let identity = root.deviceIdentity, let server = root.remoteBaseURL else {
            return
        }
        stop(root.path)
        status[root.path] = nil
        publish.yield(status)
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

    /// Asks every running account for a pass now.
    func syncAll() {
        for account in accounts.values {
            account.sync.requestSync()
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
    }

    // MARK: - Loops

    private func begin(_ root: LibraryRoot, token: String, server: URL) {
        let sync = ImmichCatalogSync(
            rootPath: root.path,
            source: ImmichSessionSyncSource(client: ImmichClient(server: server, session: urlSession), token: token),
            store: store
        )
        let path = root.path
        // The loop holds the sync, never this owner: a weak reference per pass report.
        let loop = Task { [sync] in
            await sync.run { [weak self] outcome in
                await self?.passEnded(outcome, for: path)
            }
        }
        accounts[path] = Account(root: root, sync: sync, loop: loop)
        setStatus(.connecting, for: path)
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

    /// Records what the server answered and rings the next pass after the delay its
    /// answer calls for. A refused session or a removed root rings none.
    private func passEnded(_ outcome: ImmichSyncPassOutcome, for path: LibraryRootPath) {
        guard var account = accounts[path] else {
            return
        }
        let next: Duration?
        switch outcome {
        case .synced:
            account.failures = 0
            setStatus(.online, for: path)
            next = schedule.poll
        case .serverFailed(.unauthorized):
            setStatus(.signedOut, for: path)
            next = nil
        case .serverFailed, .resetLoop:
            setStatus(.offline, for: path)
            next = backoff(after: account.failures)
            account.failures += 1
        case .catalogFailed:
            next = backoff(after: account.failures)
            account.failures += 1
        case .noLease:
            next = nil
        }
        account.timer?.cancel()
        account.timer = next.map { delay in
            Task { [clock, sync = account.sync] in
                do {
                    // time: poll — Immich reports no change to a native client; between
                    // passes while it answers, and backoff while it does not.
                    try await clock.sleep(for: delay)
                } catch {
                    return
                }
                sync.requestSync()
            }
        }
        accounts[path] = account
    }

    private func backoff(after failures: Int) -> Duration {
        schedule.backoff[min(failures, schedule.backoff.count - 1)]
    }

    private func setStatus(_ new: ImmichAccountStatus, for path: LibraryRootPath) {
        guard status[path] != new else {
            return
        }
        status[path] = new
        publish.yield(status)
        OtosLog.catalog.noticeOperation("immich.account.status", phase: "changed", fields: [
            "rootPath": path.rawValue, "status": String(describing: new),
        ])
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
