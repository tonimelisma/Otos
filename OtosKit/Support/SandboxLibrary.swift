#if DEBUG
    import Foundation
    import Observation
    import OSLog

    /// Sandbox library registration guide
    ///
    /// A tour or a survey of a library made for it (`script/sandbox-library.sh`) needs that
    /// library registered in its sandbox catalog. `OTOS_SANDBOX_LIBRARY=<folder>` asks for it:
    /// once the catalog's first load has applied, the folder is added through the window's own
    /// `addLibrary` intent, the one Settings ▸ Libraries' Add button calls, so its scan, its
    /// watcher and every background owner meet it exactly as they meet a library a person adds.
    /// A folder already registered is left as it is, so a second launch of the same sandbox
    /// measures a library that is no longer new.
    ///
    /// It registers only where it cannot reach the user's configuration (ADR 0020): the process
    /// runs in a sandbox home (`SmokeTour.sandboxHome`), the catalog it opens lies inside that
    /// home, and so does the folder. Anywhere else it registers nothing and logs why
    /// (`op=sandboxLibrary phase=refused`). The whole seam is `#if DEBUG`.
    nonisolated enum SandboxLibrary {
        static let variable = "OTOS_SANDBOX_LIBRARY"

        enum Request: Equatable {
            /// Register this folder unless it is registered already.
            case add(LibraryRootPath)
            /// Asked for, but not here: the reason is logged and nothing is registered.
            case refused(String)
        }

        /// What the environment asks for, or nil when it asks for nothing. `catalogFolder` is
        /// the folder the catalog opens in (Application Support): a catalog outside the sandbox
        /// home is the user's, whatever `CFFIXED_USER_HOME` says.
        static func request(
            environment: [String: String],
            catalogFolder: String?,
            processHome: String = NSHomeDirectory(),
            userHome: String? = SmokeTour.accountHome()
        ) -> Request? {
            guard let raw = environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }
            guard let sandbox = SmokeTour.sandboxHome(environment: environment, processHome: processHome, userHome: userHome) else {
                return .refused("notSandboxHome")
            }
            guard let catalogFolder, SmokeTour.lies(catalogFolder, inside: sandbox) else {
                return .refused("catalogOutsideSandbox")
            }
            let url = URL(fileURLWithPath: raw, isDirectory: true)
            guard let path = try? CatalogPath.normalizedDirectoryPath(for: url) else {
                return .refused("unreadablePath")
            }
            guard SmokeTour.lies(path.rawValue, inside: sandbox) else {
                return .refused("folderOutsideSandbox")
            }
            return .add(path)
        }

        /// The folder this launch's environment asks to register, when it may: what the tour
        /// waits for before it plans.
        static func requestedPath(environment: [String: String]) -> LibraryRootPath? {
            if case let .add(path) = request(environment: environment, catalogFolder: applicationSupportFolder()) {
                return path
            }
            return nil
        }

        /// Whether the window lists `path` as a library whose first scan has delivered: listed,
        /// idle, and its items on the grid.
        static func isScanned(_ path: LibraryRootPath, in state: CatalogWindowState) -> Bool {
            guard let library = state.libraries.first(where: { $0.path == path }) else {
                return false
            }
            return library.activity == .idle && !state.mediaGrid.orderedAssetIDs.isEmpty
        }

        /// The user domain's Application Support folder, which `CFFIXED_USER_HOME` moves; nil
        /// when the system does not name one. Never created here.
        static func applicationSupportFolder() -> String? {
            (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))?
                .path(percentEncoded: false)
        }

        /// Registers the requested folder once the catalog's first load has applied, through the
        /// window's `addLibrary` intent. The follower holds the view model weakly and ends with
        /// it or once it has acted.
        @MainActor
        static func applyIfPresent(
            to viewModel: CatalogWindowViewModel,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) {
            guard let request = request(environment: environment, catalogFolder: applicationSupportFolder()) else {
                return
            }
            guard case let .add(path) = request else {
                if case let .refused(reason) = request {
                    OtosLog.app.errorOperation("sandboxLibrary", phase: "refused", fields: ["reason": reason])
                }
                return
            }
            let loaded = Observations { @MainActor [weak viewModel] in
                viewModel?.state.isCatalogLoaded
            }
            Task { [weak viewModel] in
                for await isLoaded in loaded {
                    guard let isLoaded, let viewModel else {
                        return
                    }
                    guard isLoaded else {
                        continue
                    }
                    if viewModel.state.libraries.contains(where: { $0.path == path }) {
                        OtosLog.app.noticeOperation("sandboxLibrary", phase: "exists", fields: ["rootPath": path.rawValue])
                    } else {
                        OtosLog.app.noticeOperation("sandboxLibrary", phase: "add", fields: ["rootPath": path.rawValue])
                        viewModel.addLibrary(url: URL(fileURLWithPath: path.rawValue, isDirectory: true))
                    }
                    return
                }
            }
        }
    }
#endif
