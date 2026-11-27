#if DEBUG
    import AppKit
    import Foundation
    import Observation
    import OSLog
    import QuartzCore

    /// Developer smoke-capture guide
    ///
    /// A smoke run can write the main window's own rendering to a PNG, so a design pass
    /// (DES-022's light and dark, DES-029's grayscale) is agent-owned without screen
    /// recording permission or a hand on the mouse. The window draws itself through
    /// `cacheDisplay`, which is what the app composes, not a screen capture: a Metal-
    /// backed layer such as the map's tiles may come out blank, while the chrome, the
    /// bar and the stacks are the real views.
    ///
    /// The capture waits on a fact, never on time (ADR 0033): for the Places map, the
    /// first non-empty set of stacks; for On This Day, its published anniversaries or its known
    /// emptiness, or with `OTOS_SMOKE_PLAY_STORY` the story's first settled picture; for
    /// Duplicates, its first group; for any grid, the first non-empty order. All are
    /// published state the ViewModel owns. Thumbnails decode after that moment, so a
    /// capture may show placeholders; the run's log says which asset painted when.
    ///
    /// Alone, `OTOS_SMOKE_CAPTURE_PATH` is one PNG of the window as the selection seam
    /// (`OTOS_SMOKE_SELECT_ROOT`) leaves it, in `OTOS_SMOKE_APPEARANCE=dark|light`, the app's
    /// own appearance, not the system's. With `OTOS_SMOKE_CAPTURE_VIEWS` it is a folder, and
    /// the seam walks those views in one launch, each in every appearance
    /// `OTOS_SMOKE_APPEARANCE` lists (default `light,dark`): it selects the view through the
    /// sidebar's own intent once the window can show it, waits until the window shows it
    /// with what it holds, writes `<view>-<appearance>-rendering.png`, and waits for the
    /// go-ahead (`SIGUSR1`) before the next step. `script/app-capture.sh` sends it once it
    /// has captured the screen for that step, so every view and appearance comes from one
    /// library and one exit. The whole seam is `#if DEBUG`; a release build contains none
    /// of it.
    nonisolated enum SmokeWindowCapture {
        static let pathVariable = "OTOS_SMOKE_CAPTURE_PATH"
        static let appearanceVariable = "OTOS_SMOKE_APPEARANCE"
        static let viewsVariable = "OTOS_SMOKE_CAPTURE_VIEWS"
        /// The capturing script's report that it is done with a step.
        static let goAheadSignal = SIGUSR1
        /// Seconds to let the Places map settle after it is ready, before the capture. Its
        /// tiles arrive from the network and its stacks decode their thumbnails after the
        /// readiness fact, and MapKit's SwiftUI `Map` reports neither, so this is the one
        /// wait nothing can replace (ADR 0033, `time: measurement`). Only a step that shows
        /// the map waits it. Default 0.
        static let settleVariable = "OTOS_SMOKE_CAPTURE_SETTLE_SECONDS"
        /// `0` to `1`: how far down every scroll view in the window is scrolled before the
        /// capture, so a design pass can see a list past its first screen. Default 0.
        static let scrollVariable = "OTOS_SMOKE_CAPTURE_SCROLL_FRACTION"
        /// How far into the grid's order the Edit view looks for a still to open, and the
        /// library view waits for thumbnails.
        static let editorSearchLimit = 24

        /// A view a capture walk shows, by the name `script/app-capture.sh` gives it.
        enum View: String, CaseIterable, Sendable {
            /// The first fixed library's grid: what the sidebar selects for a single library,
            /// where All Media is no row.
            case library
            case places
            case onThisDay = "on-this-day"
            case duplicates
            /// The library's grid with the Edit pane open on the first still near the top of
            /// its order. Nothing is edited: opening the pane writes no recipe.
            case edit
        }

        enum Appearance: String, Sendable {
            case light
            case dark

            var name: NSAppearance.Name {
                self == .dark ? .darkAqua : .aqua
            }
        }

        /// One capture: the view it shows (nil: whatever the window shows), the appearance it
        /// sets (nil: the app's own), and the PNG it writes.
        struct Step: Equatable, Sendable {
            let view: View?
            let appearance: Appearance?
            let path: String
        }

        enum Plan: Equatable {
            case none
            case steps([Step])
            /// Asked for, but not in a form the seam can follow; nothing is captured.
            case invalid(String)
        }

        /// What the environment asks the seam to capture. Pure.
        static func plan(environment: [String: String]) -> Plan {
            guard let path = trimmed(environment[pathVariable]) else {
                return .none
            }
            var appearances: [Appearance] = []
            for name in list(environment[appearanceVariable]) {
                guard let appearance = Appearance(rawValue: name) else {
                    return .invalid("unknownAppearance=\(name)")
                }
                appearances.append(appearance)
            }
            guard environment[viewsVariable] != nil else {
                guard appearances.count <= 1 else {
                    return .invalid("oneAppearanceForOnePath")
                }
                return .steps([Step(view: nil, appearance: appearances.first, path: path)])
            }
            var views: [View] = []
            for name in list(environment[viewsVariable]) {
                guard let view = View(rawValue: name) else {
                    return .invalid("unknownView=\(name)")
                }
                views.append(view)
            }
            guard !views.isEmpty else {
                return .invalid("noViews")
            }
            let walked = appearances.isEmpty ? [Appearance.light, .dark] : appearances
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            return .steps(views.flatMap { view in
                walked.map { appearance in
                    Step(
                        view: view,
                        appearance: appearance,
                        path: folder.appendingPathComponent("\(view.rawValue)-\(appearance.rawValue)-rendering.png").path
                    )
                }
            })
        }

        /// The sidebar selection that shows `view`, once this state can show it: nil while the
        /// catalog's first load is unfinished, while no fixed library is registered (a choice
        /// made before then would stand in for the launch's own default), and while
        /// Duplicates has no active group.
        static func selection(for view: View, in state: CatalogWindowState, today: CalendarDay) -> SidebarSelection? {
            let request: SmokeLibrarySelection.Request
            switch view {
            case .library, .edit:
                guard state.mediaEmptyState != .loadingCatalog, let library = state.libraries.first else {
                    return nil
                }
                return .library(library.path)
            case .places:
                request = .places
            case .onThisDay:
                request = .onThisDay
            case .duplicates:
                request = .duplicates
            }
            guard case let .select(selection)? = SmokeLibrarySelection.resolution(
                requested: request, in: state, today: today
            ) else {
                return nil
            }
            return selection
        }

        /// Whether the window has something worth capturing for the requested selection.
        static func isReady(
            showsPlacesMap: Bool,
            clusterCount: Int,
            showsDuplicates: Bool = false,
            duplicateGroupCount: Int = 0,
            showsPeople: Bool = false,
            peopleAreBuilt: Bool = false,
            showsOnThisDay: Bool = false,
            onThisDaySettled: Bool = false,
            gridCount: Int
        ) -> Bool {
            if showsPlacesMap {
                return clusterCount > 0
            }
            if showsPeople {
                return peopleAreBuilt
            }
            if showsOnThisDay {
                return onThisDaySettled
            }
            if showsDuplicates {
                return duplicateGroupCount > 0
            }
            return gridCount > 0
        }

        @MainActor
        static func applyIfPresent(
            to viewModel: CatalogWindowViewModel,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) {
            let steps: [Step]
            switch plan(environment: environment) {
            case .none:
                return
            case let .invalid(reason):
                OtosLog.app.error("op=smoke.capture phase=failed reason=invalidRequest detail=\(reason, privacy: .public)")
                return
            case let .steps(planned):
                steps = planned
            }
            // The one write this seam makes goes where the developer pointed it, never
            // into a library: a capture under a root would be a file Otos wrote into the
            // user's media.
            let roots = viewModel.parts.libraries.map { $0.path.rawValue + "/" }
            if let inside = steps.first(where: { step in roots.contains { step.path.hasPrefix($0) } }) {
                OtosLog.app.error("op=smoke.capture phase=failed reason=insideLibrary path=\(inside.path, privacy: .public)")
                return
            }
            let settleSeconds = environment[settleVariable].flatMap(Double.init) ?? 0
            let scrollFraction = environment[scrollVariable].flatMap(Double.init) ?? 0
            let awaitsStory = environment[SmokeLibrarySelection.playStoryVariable] == "1"
            OtosLog.app.notice(
                "op=smoke.capture phase=start steps=\(steps.count, privacy: .public) settleSeconds=\(settleSeconds, privacy: .public)"
            )
            let goAheads = steps.count > 1 ? goAheadSource() : nil
            let options = WalkOptions(
                settleSeconds: settleSeconds, scrollFraction: scrollFraction, awaitsStory: awaitsStory
            )
            Task { [weak viewModel] in
                defer { goAheads?.source.cancel() }
                await walk(steps, in: { viewModel }, goAheads: goAheads?.stream, options: options)
            }
        }

        private struct WalkOptions: Sendable {
            let settleSeconds: Double
            let scrollFraction: Double
            let awaitsStory: Bool
        }

        /// Takes each step in order: the first at once, each later one on the next go-ahead.
        /// Ends early when the window went, or when the Edit pane could not open (which
        /// `openEditor` reports).
        @MainActor
        private static func walk(
            _ steps: [Step],
            in owner: @escaping @MainActor () -> CatalogWindowViewModel?,
            goAheads: AsyncStream<Void>?,
            options: WalkOptions
        ) async {
            var goAhead = goAheads?.makeAsyncIterator()
            var shown: View?
            if steps.contains(where: { $0.view != nil }) {
                presentWindow()
            }
            for (index, step) in steps.enumerated() {
                if index > 0 {
                    guard await goAhead?.next(isolation: #isolation) != nil else {
                        return
                    }
                }
                // The appearance first, so the window has redrawn in it while the view is
                // selected and waited on; a switch just before a capture is still animating
                // the toolbar's glass when the screen is captured.
                if let appearance = step.appearance {
                    NSApp.appearance = NSAppearance(named: appearance.name)
                }
                if let view = step.view, view != shown {
                    guard await show(view, in: owner, awaitsStory: options.awaitsStory) else {
                        return
                    }
                    shown = view
                }
                OtosLog.app.notice(
                    "op=smoke.capture phase=waiting view=\(step.view?.rawValue ?? "shown", privacy: .public) appearance=\(step.appearance?.rawValue ?? "app", privacy: .public)"
                )
                guard await isReady(for: step.view, in: owner, awaitsStory: options.awaitsStory) else {
                    return
                }
                // The state that made the window ready is applied; the view tree that shows
                // it lays out on the next pass. Yield once so the capture draws that pass,
                // not the one before it.
                await Task.yield()
                if options.scrollFraction > 0 {
                    scrollEveryScrollView(to: options.scrollFraction)
                    await Task.yield()
                }
                if options.settleSeconds > 0, owner()?.showsPlacesMap == true {
                    // time: measurement — the map's tiles and thumbnails report no arrival.
                    try? await Task.sleep(for: .seconds(options.settleSeconds))
                }
                capture(step)
            }
        }

        /// The capturing script's go-aheads, one per `SIGUSR1`, yielded from the source's own
        /// queue into the walk's stream. The signal's default action ends the process, so it
        /// is ignored before the source that reports it starts. The walk owns the source and
        /// cancels it however it ends.
        private static func goAheadSource() -> (stream: AsyncStream<Void>, source: any DispatchSourceSignal) {
            let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .unbounded)
            signal(goAheadSignal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: goAheadSignal,
                queue: DispatchQueue(label: "net.melisma.Otos.smokeCapture.goAhead")
            )
            source.setEventHandler { @Sendable in
                continuation.yield()
            }
            source.setCancelHandler { @Sendable in
                continuation.finish()
            }
            source.resume()
            return (stream, source)
        }

        /// Selects `view` through the sidebar's intent once the window's state can show it,
        /// closing an Edit pane a previous step opened; for Edit, opens the pane once the
        /// library's grid shows its photos. False when the window went or the pane could not open.
        @MainActor
        private static func show(
            _ view: View,
            in owner: @escaping @MainActor () -> CatalogWindowViewModel?,
            awaitsStory: Bool
        ) async -> Bool {
            let selections = Observations { @MainActor in
                owner().map { model in selection(for: view, in: model.state, today: model.today) }
            }
            var chosen: SidebarSelection?
            for await answer in selections {
                guard let answer else {
                    return false
                }
                if let answer {
                    chosen = answer
                    break
                }
            }
            guard let chosen, let model = owner() else {
                return false
            }
            if view != .edit {
                model.setInspectorPane(nil)
            }
            model.selectSidebar(chosen)
            OtosLog.app.notice("op=smoke.capture phase=selected view=\(view.rawValue, privacy: .public)")
            switch view {
            case .library:
                guard await isReady(for: view, in: owner, awaitsStory: awaitsStory) else {
                    return false
                }
                return await gridThumbnailsRendered(in: owner)
            case .edit:
                guard await isReady(for: view, in: owner, awaitsStory: awaitsStory) else {
                    return false
                }
                return await openEditor(in: owner)
            case .places, .onThisDay, .duplicates:
                return true
            }
        }

        /// A walk shows the window at the size a person working in it uses: zoomed to the
        /// screen's visible frame, since SwiftUI sizes a window with no default size to its
        /// content's ideal size. It is not made active: macOS gives activation only to an app
        /// the person or LaunchServices brings forward, never to one a shell launched, so the
        /// captures draw the window inactive (gray window buttons, a dimmed toolbar).
        @MainActor
        private static func presentWindow() {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let screen = window.screen ?? NSScreen.main
            else {
                OtosLog.app.error("op=smoke.capture phase=failed reason=noWindowToPresent")
                return
            }
            window.setFrame(screen.visibleFrame, display: true)
            window.orderFront(nil)
            OtosLog.app.notice(
                "op=smoke.capture phase=presented width=\(Int(window.frame.width), privacy: .public) height=\(Int(window.frame.height), privacy: .public)"
            )
        }

        /// Waits until every one of the grid's first `editorSearchLimit` items names a thumbnail
        /// in the catalog, re-reading their details each time the grid's content or its details
        /// change; enrichment renders them after the order is known. A read that fails is
        /// logged and read again on the next change.
        @MainActor
        private static func gridThumbnailsRendered(
            in owner: @escaping @MainActor () -> CatalogWindowViewModel?
        ) async -> Bool {
            let grids = Observations { @MainActor in
                owner().map { model in
                    GridDetails(
                        ids: Array(model.parts.mediaGrid.orderedAssetIDs.prefix(editorSearchLimit)),
                        generation: model.parts.mediaGrid.detailRefreshGeneration
                    )
                }
            }
            for await grid in grids {
                guard let grid, let reader = owner()?.tileDetailReader else {
                    return false
                }
                let details: [MediaAssetID: MediaTileDetail]
                do {
                    details = try await reader.details(for: grid.ids)
                } catch {
                    OtosLog.app.error(
                        "op=smoke.capture phase=detailReadFailed error=\(String(describing: error), privacy: .public)"
                    )
                    continue
                }
                let awaited = grid.ids.count { details[$0]?.thumbnailPath == nil }
                if !grid.ids.isEmpty, awaited == 0 {
                    OtosLog.app.notice("op=smoke.capture phase=thumbnailsRendered items=\(grid.ids.count, privacy: .public)")
                    return true
                }
            }
            return false
        }

        private struct GridDetails: Equatable, Sendable {
            let ids: [MediaAssetID]
            let generation: UInt64
        }

        /// Waits until the window shows `view` (any view, for nil) with what it holds.
        @MainActor
        private static func isReady(
            for view: View?,
            in owner: @escaping @MainActor () -> CatalogWindowViewModel?,
            awaitsStory: Bool
        ) async -> Bool {
            let readiness = Observations { @MainActor in
                owner().map { model in
                    (view.map { shows($0, model) } ?? true) && isReady(
                        showsPlacesMap: model.showsPlacesMap,
                        clusterCount: model.mapClusters.count,
                        showsDuplicates: model.showsDuplicatesList,
                        duplicateGroupCount: model.state.duplicates?.groups.count ?? 0,
                        showsPeople: model.showsPeopleList,
                        peopleAreBuilt: model.state.people != nil,
                        showsOnThisDay: model.showsOnThisDay,
                        onThisDaySettled: onThisDaySettled(model, awaitsStory: awaitsStory),
                        gridCount: model.state.mediaGrid.orderedAssetIDs.count
                    )
                }
            }
            for await ready in readiness {
                guard let ready else {
                    return false
                }
                if ready {
                    return true
                }
            }
            return false
        }

        /// The detail pane draws `view`'s scope with its state applied (DES-118).
        @MainActor
        private static func shows(_ view: View, _ model: CatalogWindowViewModel) -> Bool {
            switch view {
            case .library, .edit:
                model.showsSelectedScope && model.queryDescriptor.scope.detailSurface == nil
            case .places:
                model.showsPlacesMap
            case .onThisDay:
                model.showsOnThisDay
            case .duplicates:
                model.showsDuplicatesList
            }
        }

        /// Selects the first still near the top of the grid and opens the Edit pane on it;
        /// returns once the pane has the photo's histogram, the last of the facts it draws
        /// that opening the photo publishes, or false (and says why) when there is no still
        /// to open or the window went. The window model is asked for through `owner` at each
        /// step, so no wait holds it.
        @MainActor
        private static func openEditor(in owner: @escaping @MainActor () -> CatalogWindowViewModel?) async -> Bool {
            guard let start = owner().map({
                (Array($0.parts.mediaGrid.orderedAssetIDs.prefix(editorSearchLimit)), $0.tileDetailReader)
            }) else {
                return false
            }
            let (candidates, reader) = start
            let details: [MediaAssetID: MediaTileDetail]
            do {
                details = try await reader.details(for: candidates)
            } catch {
                OtosLog.app.error(
                    "op=smoke.capture phase=failed reason=detailReadFailed error=\(String(describing: error), privacy: .public)"
                )
                return false
            }
            guard let photo = candidates.first(where: { details[$0].map { $0.bestKind != .video } ?? false }) else {
                OtosLog.app.error("op=smoke.capture phase=failed reason=noStillToEdit candidates=\(candidates.count, privacy: .public)")
                return false
            }
            guard let model = owner() else {
                return false
            }
            model.selectAssets([photo])
            model.setInspectorPane(.edit)
            let shown = Observations { @MainActor in
                owner().map { $0.editSession.editTarget?.id == photo && $0.editSession.editHistogram != nil }
            }
            for await isShown in shown {
                guard let isShown else {
                    return false
                }
                if isShown {
                    OtosLog.app.notice("op=smoke.capture phase=editorShown")
                    return true
                }
            }
            return false
        }

        private static func trimmed(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return value
        }

        private static func list(_ value: String?) -> [String] {
            (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        /// On This Day has something to show: the story's picture settled, or else the
        /// anniversaries, or the scope known to hold none.
        @MainActor
        private static func onThisDaySettled(_ viewModel: CatalogWindowViewModel, awaitsStory: Bool) -> Bool {
            if awaitsStory {
                return viewModel.story.map { $0.pane != .awaited } ?? false
            }
            if case .nothingOnThisDay = viewModel.parts.mediaEmptyState {
                return true
            }
            return viewModel.parts.onThisDay?.anniversaries.isEmpty == false
        }

        /// Scrolls every scroll view in the main window to the given fraction of its
        /// range, so a capture can show a list past its first screen.
        @MainActor
        private static func scrollEveryScrollView(to fraction: Double) {
            guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView else {
                return
            }
            var pending = [view]
            while let next = pending.popLast() {
                if let scrollView = next as? NSScrollView, let document = scrollView.documentView {
                    let visible = scrollView.contentView.bounds.height
                    let maxY = max(0, document.bounds.height - visible)
                    scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY * fraction))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
                pending.append(contentsOf: next.subviews)
            }
        }

        @MainActor
        private static func capture(_ step: Step) {
            let path = step.path
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let view = window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else {
                OtosLog.app.error("op=smoke.capture phase=failed reason=noWindow")
                return
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            // The report below is what a screen capture of this step waits for, so the window
            // is laid out, drawn and committed to the window server first: an appearance just
            // set otherwise reaches the screen only on a later pass, after the capture
            // (run 45945839837 drew edit's dark step light).
            view.layoutSubtreeIfNeeded()
            window.display()
            CATransaction.flush()
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                OtosLog.app.error("op=smoke.capture phase=failed reason=noPNG")
                return
            }
            do {
                try data.write(to: URL(fileURLWithPath: path, isDirectory: false))
            } catch {
                OtosLog.app.error(
                    "op=smoke.capture phase=failed reason=write error=\(String(describing: error), privacy: .public)"
                )
                return
            }
            OtosLog.app.notice(
                "op=smoke.capture phase=finish view=\(step.view?.rawValue ?? "shown", privacy: .public) appearance=\(step.appearance?.rawValue ?? "app", privacy: .public) path=\(path, privacy: .public) width=\(bitmap.pixelsWide, privacy: .public) height=\(bitmap.pixelsHigh, privacy: .public)"
            )
        }
    }
#endif
