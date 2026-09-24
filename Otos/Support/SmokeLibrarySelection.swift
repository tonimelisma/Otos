#if DEBUG
    import Foundation
    import OSLog

    /// Developer smoke-launch selection guide
    ///
    /// A smoke run may look at the user's real library — that is the point of running
    /// against production data — but it may never change what the user has configured.
    /// This seam is therefore read-only with respect to catalog configuration: it
    /// resolves `OTOS_SMOKE_SELECT_ROOT` against roots the Store already has and applies
    /// the same `selectSidebar` intent a sidebar click applies. There is no path here
    /// that registers a root. A developer seam that could register one puts whatever
    /// path it is handed into the user's permanent library list, including a scratch
    /// directory that will not exist tomorrow (ADR 0020).
    ///
    /// The whole seam is `#if DEBUG`: a release build contains no way for an
    /// environment variable to steer the catalog at all.
    ///
    /// Resolution is pure (`resolve(requested:among:)`); only `applyIfPresent` touches
    /// the ViewModel, and it waits because roots are published asynchronously after
    /// `start()`.
    nonisolated enum SmokeLibrarySelection {
        static let environmentVariable = "OTOS_SMOKE_SELECT_ROOT"

        /// How long the requested root has to appear after launch. Store loads and
        /// publishes roots asynchronously, so the seam cannot resolve at launch time.
        /// Expiring is a normal outcome, not an error path: it reports what is
        /// registered so the caller can fix the argument.
        static let appearanceTimeout = Duration.seconds(30)

        private static let pollInterval = Duration.milliseconds(100)

        enum Resolution: Equatable {
            case select(SidebarSelection)
            /// Nothing was selected. Carries the registered roots so the log names them
            /// rather than telling the developer only that their path was wrong.
            case notRegistered(requested: LibraryRootPath, registered: [LibraryRootPath])
        }

        /// The requested root, normalized the same way `CatalogStore` normalizes roots
        /// before persisting them, so a tilde, a trailing slash, or a symlinked parent
        /// still matches the stored spelling.
        static func configuredRootPath(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> LibraryRootPath? {
            guard let rawValue = environment[environmentVariable]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !rawValue.isEmpty
            else {
                return nil
            }
            let url = URL(fileURLWithPath: NSString(string: rawValue).expandingTildeInPath, isDirectory: true)
            return try? CatalogPath.normalizedDirectoryPath(for: url)
        }

        /// Pure match of a requested root against the sources the window currently knows.
        /// Fixed libraries and removable sources are both selectable, exactly as the
        /// sidebar treats them.
        static func resolve(
            requested: LibraryRootPath,
            among sources: [CatalogLibraryState]
        ) -> Resolution {
            if sources.contains(where: { $0.path == requested }) {
                return .select(.library(requested))
            }
            return .notRegistered(
                requested: requested,
                registered: sources.map(\.path).sorted { $0.rawValue < $1.rawValue }
            )
        }

        /// Waits for the requested root to appear, then applies the ordinary selection
        /// intent. Never registers, removes, or otherwise mutates catalog configuration.
        @MainActor
        static func applyIfPresent(
            to viewModel: CatalogWindowViewModel,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) {
            guard let requested = configuredRootPath(environment: environment) else {
                return
            }
            OtosLog.app.notice(
                "op=smoke.select phase=start requestedPath=\(requested.rawValue, privacy: .public)"
            )
            Task { @MainActor [weak viewModel] in
                let deadline = ContinuousClock().now.advanced(by: appearanceTimeout)
                while true {
                    guard let viewModel else {
                        return
                    }
                    let sources = viewModel.state.libraries + viewModel.state.removableSources
                    if case let .select(selection) = resolve(requested: requested, among: sources) {
                        viewModel.selectSidebar(selection)
                        OtosLog.app.notice(
                            "op=smoke.select phase=finish outcome=selected path=\(requested.rawValue, privacy: .public)"
                        )
                        return
                    }
                    guard ContinuousClock().now < deadline else {
                        let registered = sources.map(\.path.rawValue).sorted().joined(separator: ", ")
                        OtosLog.app.error(
                            "op=smoke.select phase=finish outcome=notRegistered requestedPath=\(requested.rawValue, privacy: .public) registeredRoots=[\(registered, privacy: .public)] hint=a smoke run never adds a root; pass one that is already registered"
                        )
                        return
                    }
                    try? await Task.sleep(for: pollInterval)
                }
            }
        }
    }
#endif
