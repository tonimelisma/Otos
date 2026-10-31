#if DEBUG
    import AppKit
    import Foundation
    import Observation
    import OSLog

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
    /// first non-empty set of stacks; for any grid, the first non-empty order. Both are
    /// published state the ViewModel owns. Thumbnails decode after that moment, so a
    /// capture may show placeholders; the run's log says which asset painted when.
    ///
    /// `OTOS_SMOKE_APPEARANCE=dark|light` sets the app's own appearance — the app's,
    /// not the system's — so both captures come from one machine state. The whole seam
    /// is `#if DEBUG`; a release build contains none of it.
    nonisolated enum SmokeWindowCapture {
        static let pathVariable = "OTOS_SMOKE_CAPTURE_PATH"
        static let appearanceVariable = "OTOS_SMOKE_APPEARANCE"
        /// Seconds to let the window settle after it is ready, before the capture. The map's
        /// tiles arrive from the network and its stacks decode their thumbnails after the
        /// readiness fact, and MapKit's SwiftUI `Map` reports neither, so this is the one
        /// wait nothing can replace (ADR 0033, `time: measurement`). Default 0.
        static let settleVariable = "OTOS_SMOKE_CAPTURE_SETTLE_SECONDS"

        /// Whether the window has something worth capturing for the requested selection.
        static func isReady(showsPlacesMap: Bool, clusterCount: Int, gridCount: Int) -> Bool {
            showsPlacesMap ? clusterCount > 0 : gridCount > 0
        }

        @MainActor
        static func applyIfPresent(
            to viewModel: CatalogWindowViewModel,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) {
            guard let path = environment[pathVariable]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty
            else {
                return
            }
            if let appearance = environment[appearanceVariable] {
                NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            }
            let settleSeconds = environment[settleVariable].flatMap(Double.init) ?? 0
            OtosLog.app.notice(
                "op=smoke.capture phase=start path=\(path, privacy: .public) settleSeconds=\(settleSeconds, privacy: .public)"
            )
            let readiness = Observations { @MainActor [weak viewModel] in
                viewModel.map {
                    isReady(
                        showsPlacesMap: $0.showsPlacesMap,
                        clusterCount: $0.mapClusters.count,
                        gridCount: $0.state.mediaGrid.orderedAssetIDs.count
                    )
                }
            }
            Task {
                for await ready in readiness {
                    guard let ready else {
                        return
                    }
                    guard ready else {
                        continue
                    }
                    // The state that made the window ready is applied; the view tree that
                    // shows it lays out on the next pass. Yield once so the capture draws
                    // that pass, not the one before it.
                    await Task.yield()
                    if settleSeconds > 0 {
                        // time: measurement — tiles and thumbnails report no arrival.
                        try? await Task.sleep(for: .seconds(settleSeconds))
                    }
                    capture(to: path)
                    return
                }
            }
        }

        @MainActor
        private static func capture(to path: String) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let view = window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else {
                OtosLog.app.error("op=smoke.capture phase=failed reason=noWindow")
                return
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
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
                "op=smoke.capture phase=finish path=\(path, privacy: .public) width=\(bitmap.pixelsWide, privacy: .public) height=\(bitmap.pixelsHigh, privacy: .public)"
            )
        }
    }
#endif
