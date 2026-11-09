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
        /// The non-path values: the Places map (ADR 0040) and the Duplicates list (ADR 0042),
        /// which have no root to name.
        static let placesValue = "places"
        static let onThisDayValue = "onThisDay"
        static let duplicatesValue = "duplicates"
        /// The People list and its review (ADR 0047).
        static let peopleValue = "people"
        static let peopleReviewValue = "people-review"
        /// With `onThisDay`: once its years publish, play the story from the newest year
        /// through the ordinary intent, so a capture shows the player (ADR 0049).
        static let playStoryVariable = "OTOS_SMOKE_PLAY_STORY"

        /// What the environment asked the window to show.
        enum Request: Equatable {
            case root(LibraryRootPath)
            case places
            case onThisDay
            case duplicates
            case people
            case peopleReview

            var diagnosticDescription: String {
                switch self {
                case let .root(path): path.rawValue
                case .places: SmokeLibrarySelection.placesValue
                case .onThisDay: SmokeLibrarySelection.onThisDayValue
                case .duplicates: SmokeLibrarySelection.duplicatesValue
                case .people: SmokeLibrarySelection.peopleValue
                case .peopleReview: SmokeLibrarySelection.peopleReviewValue
                }
            }
        }

        enum Resolution: Equatable {
            case select(SidebarSelection)
            /// Nothing was selected. Carries the registered roots so the log names them
            /// rather than telling the developer only that their path was wrong.
            case notRegistered(requested: LibraryRootPath, registered: [LibraryRootPath])
            /// Places was asked for, but no fixed library exists to map.
            case noFixedLibrary(registered: [LibraryRootPath])
            /// Duplicates was asked for, but the groups are not built yet or none is active;
            /// the seam keeps following, since groups arrive as digests do.
            case noDuplicatesYet
            /// People was asked for, but it is not built yet; the seam keeps following.
            case noPeopleYet
        }

        /// The request: `places`, or a root normalized the same way `CatalogStore`
        /// normalizes roots before persisting them, so a tilde, a trailing slash, or a
        /// symlinked parent still matches the stored spelling.
        static func configuredRequest(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Request? {
            guard let rawValue = environment[environmentVariable]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !rawValue.isEmpty
            else {
                return nil
            }
            if rawValue == placesValue {
                return .places
            }
            if rawValue == duplicatesValue {
                return .duplicates
            }
            if rawValue == peopleValue {
                return .people
            }
            if rawValue == peopleReviewValue {
                return .peopleReview
            }
            if rawValue == onThisDayValue {
                return .onThisDay
            }
            let url = URL(fileURLWithPath: NSString(string: rawValue).expandingTildeInPath, isDirectory: true)
            return (try? CatalogPath.normalizedDirectoryPath(for: url)).map(Request.root)
        }

        /// Pure match of a request against the sources the window currently knows. Fixed
        /// libraries and removable sources are both selectable, exactly as the sidebar
        /// treats them; Places needs one fixed library, exactly as its row does.
        static func resolve(
            requested: Request,
            among sources: [CatalogLibraryState],
            activeDuplicateGroups: Int = 0,
            peopleAreBuilt: Bool = false,
            today: CalendarDay = .today()
        ) -> Resolution {
            let registered = sources.map(\.path).sorted { $0.rawValue < $1.rawValue }
            switch requested {
            case let .root(path):
                if sources.contains(where: { $0.path == path }) {
                    return .select(.library(path))
                }
                return .notRegistered(requested: path, registered: registered)
            case .places:
                if SidebarSelectionPolicy.showsPlaces(libraries: sources) {
                    return .select(.places)
                }
                return .noFixedLibrary(registered: registered)
            case .onThisDay:
                if SidebarSelectionPolicy.showsPlaces(libraries: sources) {
                    return .select(.onThisDay(today))
                }
                return .noFixedLibrary(registered: registered)
            case .duplicates:
                return activeDuplicateGroups > 0 ? .select(.duplicates) : .noDuplicatesYet
            case .people, .peopleReview:
                guard SidebarSelectionPolicy.showsPlaces(libraries: sources) else {
                    return .noFixedLibrary(registered: registered)
                }
                guard peopleAreBuilt else {
                    return .noPeopleYet
                }
                return .select(requested == .people ? .people : .peopleReview)
            }
        }

        /// What one published window state means for the request: nothing yet while the
        /// catalog's first load is unfinished, then a selection or the registered roots.
        static func resolution(
            requested: Request,
            in state: CatalogWindowState,
            today: CalendarDay = .today()
        ) -> Resolution? {
            guard state.mediaEmptyState != .loadingCatalog else {
                return nil
            }
            return resolve(
                requested: requested,
                among: state.libraries + state.removableSources,
                activeDuplicateGroups: state.duplicates?.activeGroups.count ?? 0,
                peopleAreBuilt: state.people != nil,
                today: today
            )
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
            guard let requested = configuredRequest(environment: environment) else {
                return
            }
            OtosLog.app.notice(
                "op=smoke.select phase=start requestedPath=\(requested.diagnosticDescription, privacy: .public)"
            )
            let states = Observations { @MainActor [weak viewModel] in
                viewModel?.state
            }
            let playsStory = requested == .onThisDay && environment[playStoryVariable] == "1"
            Task { [weak viewModel] in
                var reportedUnregistered = false
                var selected = false
                for await state in states {
                    guard let state, let viewModel else {
                        return
                    }
                    if selected {
                        // Following only to start the story once the years are on screen.
                        guard viewModel.canPlayStory else {
                            continue
                        }
                        viewModel.playStory()
                        OtosLog.app.notice("op=smoke.select phase=story outcome=playing")
                        return
                    }
                    switch resolution(requested: requested, in: state, today: viewModel.today) {
                    case nil:
                        continue
                    case let .select(selection):
                        viewModel.selectSidebar(selection)
                        OtosLog.app.notice(
                            "op=smoke.select phase=finish outcome=selected path=\(requested.diagnosticDescription, privacy: .public)"
                        )
                        guard playsStory else {
                            return
                        }
                        selected = true
                    case let .notRegistered(_, registered) where !reportedUnregistered,
                         let .noFixedLibrary(registered) where !reportedUnregistered:
                        reportedUnregistered = true
                        let names = registered.map(\.rawValue).joined(separator: ", ")
                        OtosLog.app.error(
                            "op=smoke.select phase=report outcome=notRegistered requestedPath=\(requested.diagnosticDescription, privacy: .public) registeredRoots=[\(names, privacy: .public)] hint=a smoke run never adds a root; pass one that is already registered, or places with a fixed library registered"
                        )
                    case .notRegistered, .noFixedLibrary, .noDuplicatesYet, .noPeopleYet:
                        continue
                    }
                }
            }
        }
    }
#endif
