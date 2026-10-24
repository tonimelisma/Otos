#if DEBUG
    import Foundation
    import Observation
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
    /// the ViewModel. Roots are published asynchronously after `start()`, so it resolves
    /// against each published window state once the catalog's first load has finished,
    /// and never against elapsed time.
    nonisolated enum SmokeLibrarySelection {
        static let environmentVariable = "OTOS_SMOKE_SELECT_ROOT"

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

        /// What one published window state means for the requested root: nothing yet while
        /// the catalog's first load is unfinished, then a selection or the registered roots.
        static func resolution(
            requested: LibraryRootPath,
            in state: CatalogWindowState
        ) -> Resolution? {
            guard state.mediaEmptyState != .loadingCatalog else {
                return nil
            }
            return resolve(requested: requested, among: state.libraries + state.removableSources)
        }

        /// Applies the ordinary selection intent once the requested root is published.
        /// Never registers, removes, or otherwise mutates catalog configuration.
        ///
        /// It follows the window states the ViewModel publishes. The first state past the
        /// catalog's first load answers whether the root is registered: if it is not, that
        /// is reported once, with the roots that are, and the seam keeps following in case
        /// it is a removable source that attaches later. The loop holds the ViewModel
        /// weakly and ends with it.
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
            let states = Observations { @MainActor [weak viewModel] in
                viewModel?.state
            }
            Task { @MainActor [weak viewModel] in
                var reportedUnregistered = false
                for await state in states {
                    guard let state, let viewModel else {
                        return
                    }
                    switch resolution(requested: requested, in: state) {
                    case nil:
                        continue
                    case let .select(selection):
                        viewModel.selectSidebar(selection)
                        OtosLog.app.notice(
                            "op=smoke.select phase=finish outcome=selected path=\(requested.rawValue, privacy: .public)"
                        )
                        return
                    case let .notRegistered(_, registered) where !reportedUnregistered:
                        reportedUnregistered = true
                        let names = registered.map(\.rawValue).joined(separator: ", ")
                        OtosLog.app.error(
                            "op=smoke.select phase=report outcome=notRegistered requestedPath=\(requested.rawValue, privacy: .public) registeredRoots=[\(names, privacy: .public)] hint=a smoke run never adds a root; pass one that is already registered"
                        )
                    case .notRegistered:
                        continue
                    }
                }
            }
        }
    }
#endif
