import SwiftUI

/// SidebarView renders projected library rows and reports explicit selection
/// intents. The local Binding exists only to adapt SwiftUI List's control API;
/// selection ownership and asynchronous delivery remain in the ViewModel.
struct SidebarView: View {
    let showsAllMedia: Bool
    let showsPlaces: Bool
    /// People (ADR 0047): one row, under On This Day, whenever a fixed library exists.
    let showsPeople: Bool
    /// Today, while the On This Day row exists (it shows whenever Places does); the row's
    /// tag is today's scope (ADR 0049).
    let onThisDay: CalendarDay?
    let showsDuplicates: Bool
    /// How many photos have duplicates (ADR 0042); nil until the groups are first built.
    let duplicatesCount: Int?
    let libraries: [CatalogLibraryState]
    /// What each Immich account's server last answered (ADR 0046 §6).
    let accountStatuses: [LibraryRootPath: ImmichAccountStatus]
    let importBatches: [ImportBatchSummary]
    let removableSources: [CatalogLibraryState]
    let importPresentations: [MediaOperationSourcePresentation]
    let sidebarSelection: SidebarSelection
    let ejectingSourceIdentities: Set<DeviceIdentity>
    let selectSidebar: @MainActor @Sendable (SidebarSelection) -> Void
    let ejectSource: @MainActor @Sendable (LibraryRoot) -> Void
    @Environment(\.colorScheme) private var colorScheme

    init(
        showsAllMedia: Bool,
        showsPlaces: Bool,
        showsPeople: Bool = false,
        onThisDay: CalendarDay? = nil,
        showsDuplicates: Bool = false,
        duplicatesCount: Int? = nil,
        libraries: [CatalogLibraryState],
        accountStatuses: [LibraryRootPath: ImmichAccountStatus] = [:],
        importBatches: [ImportBatchSummary],
        removableSources: [CatalogLibraryState],
        importPresentations: [MediaOperationSourcePresentation] = [],
        sidebarSelection: SidebarSelection,
        ejectingSourceIdentities: Set<DeviceIdentity>,
        selectSidebar: @MainActor @Sendable @escaping (SidebarSelection) -> Void,
        ejectSource: @MainActor @Sendable @escaping (LibraryRoot) -> Void
    ) {
        self.showsAllMedia = showsAllMedia
        self.showsPlaces = showsPlaces
        self.showsPeople = showsPeople
        self.onThisDay = onThisDay
        self.showsDuplicates = showsDuplicates
        self.duplicatesCount = duplicatesCount
        self.libraries = libraries
        self.accountStatuses = accountStatuses
        self.importBatches = importBatches
        self.removableSources = removableSources
        self.importPresentations = importPresentations
        self.sidebarSelection = sidebarSelection
        self.ejectingSourceIdentities = ejectingSourceIdentities
        self.selectSidebar = selectSidebar
        self.ejectSource = ejectSource
    }

    var body: some View {
        List(selection: selectionBinding) {
            if showsAllMedia {
                SidebarRow(systemImage: "square.grid.2x2", title: "All Media") {
                    EmptyView()
                }
                .tag(SidebarSelection.allMedia)
            }
            if let onThisDay {
                // Items captured on today's month and day in earlier years, else on today's day
                // of the month in earlier months (ADR 0049), second under All Media (owner
                // decision, 2026-11-11). No count, as Places carries none.
                SidebarRow(systemImage: "calendar", title: "On This Day") {
                    EmptyView()
                }
                .tag(SidebarSelection.onThisDay(onThisDay))
            }
            // The other ways to browse the whole library, under On This Day: by who is in a
            // photo and by where it was taken (owner decision, 2026-11-12). They exist from the
            // moment a fixed library does, as On This Day does, so they never arrive under the
            // pointer.
            if showsPeople {
                // The People gallery (ADR 0047); the row stays highlighted while a
                // person's photos under it are open.
                SidebarRow(systemImage: "person.crop.square", title: "People") {
                    EmptyView()
                }
                .tag(SidebarSelection.people)
            }
            if showsPlaces {
                // The map of every located item in the fixed libraries (ADR 0040); the
                // row stays highlighted while a place under it is open.
                SidebarRow(systemImage: "map", title: "Places") {
                    EmptyView()
                }
                .tag(SidebarSelection.places)
            }

            // A header with no rows under it is a claim about nothing; before the catalog
            // loads there are none (APP-044).
            if !libraries.isEmpty {
                Section("Libraries") {
                    ForEach(libraries) { library in
                        SidebarRow(systemImage: library.kind.sidebarSystemImage, title: library.displayName) {
                            AccountStatusGlyph(status: accountStatuses[library.path], server: library.root.remoteBaseURL)
                        }
                        .tag(SidebarSelection.library(library.path))
                    }
                }
            }

            if !importBatches.isEmpty {
                Section("Imports") {
                    ForEach(visibleImportBatches, id: \.batchID) { batch in
                        SidebarRow(
                            systemImage: "square.and.arrow.down.on.square",
                            title: ImportBatchFormatting.sidebarTitle(
                                for: batch.batchID,
                                among: importBatches
                            )
                        ) {
                            batchTrailingAccessory(for: batch)
                        }
                        .tag(SidebarSelection.importBatch(batch.batchID))
                    }
                    if importBatches.count > 5 {
                        SidebarRow(systemImage: "list.bullet", title: "All Imports…") {
                            EmptyView()
                        }
                        .tag(SidebarSelection.allImports)
                    }
                }
            }

            let connectedSources = SidebarSelectionPolicy.sidebarVisibleRemovableSources(removableSources)
            if !connectedSources.isEmpty {
                Section("Removable") {
                    ForEach(connectedSources) { source in
                        SidebarRow(
                            systemImage: source.kind.sidebarSystemImage,
                            title: source.displayName
                        ) {
                            removableTrailingAccessory(for: source)
                        }
                        .tag(SidebarSelection.library(source.path))
                    }
                }
            }

            // Last, so its row's arrival pushes no row under the pointer (ADR 0042), under the
            // header Photos gives it: Duplicates is upkeep, not a way to browse (owner decision,
            // 2026-11-12).
            if showsDuplicates {
                Section("Utilities") {
                    // Its count is the bar's L1 unit: photos with duplicates.
                    SidebarRow(systemImage: "square.on.square", title: "Duplicates") {
                        if let duplicatesCount {
                            Text("\(duplicatesCount)")
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(SidebarSelection.duplicates)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(DesignPalette.sidebar(for: colorScheme))
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
    }

    @ViewBuilder
    private func removableTrailingAccessory(for source: CatalogLibraryState) -> some View {
        let presentation = importPresentations.first(where: {
            $0.sourcePath == source.path
        })
        switch SidebarSelectionPolicy.removableIndicator(
            presentation: presentation,
            sidebarSelection: sidebarSelection
        ) {
        case .indeterminate:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("\(source.displayName), preparing")
        case let .determinate(completed, total):
            ProgressView(value: Double(completed), total: Double(max(total, 1)))
                .controlSize(.small)
                .frame(width: 32)
                .accessibilityLabel("\(source.displayName), importing, \(completed) of \(total)")
        case .none:
            ejectAccessory(for: source)
        }
    }

    @ViewBuilder
    private func batchTrailingAccessory(for batch: ImportBatchSummary) -> some View {
        switch SidebarSelectionPolicy.batchIndicator(
            batchID: batch.batchID,
            presentations: importPresentations,
            sidebarSelection: sidebarSelection
        ) {
        case let .determinate(completed, total):
            ProgressView(value: Double(completed), total: Double(max(total, 1)))
                .controlSize(.small)
                .frame(width: 32)
                .accessibilityLabel("Importing, \(completed) of \(total)")
        case .none, .indeterminate:
            Text("\(batch.photoCount)")
                .foregroundStyle(DesignPalette.l3(for: colorScheme))
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func ejectAccessory(for source: CatalogLibraryState) -> some View {
        if let identity = source.deviceIdentity, ejectingSourceIdentities.contains(identity) {
            ProgressView()
                .controlSize(.small)
        } else if source.isEjectable {
            Button {
                ejectSource(source.root)
            } label: {
                Image(systemName: "eject.fill")
            }
            .buttonStyle(.borderless)
            .help("Eject")
        }
    }

    private var visibleImportBatches: [ImportBatchSummary] {
        if importBatches.count <= 5 {
            return importBatches
        }
        let lastFive = Array(importBatches.prefix(5))
        if case let .importBatch(selectedID) = sidebarSelection,
           !lastFive.contains(where: { $0.batchID == selectedID }),
           let selected = importBatches.first(where: { $0.batchID == selectedID })
        {
            return lastFive + [selected]
        }
        return lastFive
    }

    private var selectionBinding: Binding<SidebarSelection> {
        Binding(
            get: { sidebarSelection.sidebarRow },
            set: selectSidebar
        )
    }
}

/// An account the server is not answering for, as a glyph with its reason: offline still
/// shows what Otos stored, and signed out waits for Settings' Sign In… (DES-029: a glyph,
/// never color alone).
private struct AccountStatusGlyph: View {
    let status: ImmichAccountStatus?
    let server: URL?

    var body: some View {
        switch status?.reach {
        case .offline:
            if let status {
                TimelineView(.everyMinute) { context in
                    Image(systemName: "wifi.slash")
                        .foregroundStyle(.secondary)
                        .help(status.unreachableHelp(server: server, now: context.date))
                        .accessibilityLabel("Server unreachable, \(status.label(now: context.date))")
                }
            }
        case .signedOut:
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.secondary)
                .help("Signed out. Sign in again in Settings ▸ Libraries.")
                .accessibilityLabel("Signed out")
        case .online, .connecting, nil:
            EmptyView()
        }
    }
}

private struct SidebarRow<Trailing: View>: View {
    let systemImage: String
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
            Text(title)
                .foregroundStyle(DesignPalette.label(for: colorScheme))
                .lineLimit(1)
            Spacer(minLength: 4)
            trailing()
        }
    }
}

#Preview {
    SidebarView(
        showsAllMedia: true,
        showsPlaces: true,
        libraries: [
            CatalogLibraryState(
                root: LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures")),
                availability: .available,
                activity: .scanning
            ),
            CatalogLibraryState(
                root: LibraryRoot(path: LibraryRootPath(rawValue: "/Volumes/Archive")),
                availability: .unavailable,
                activity: .idle
            ),
        ],
        accountStatuses: [:],
        importBatches: [
            ImportBatchSummary(
                batchID: ImportBatchID(unixMilliseconds: 1_704_067_200_000),
                photoCount: 12
            ),
        ],
        removableSources: [
            CatalogLibraryState(
                root: LibraryRoot(
                    path: LibraryRootPath(rawValue: "/Volumes/CARD"),
                    kind: .removableVolume,
                    deviceIdentity: .volume(uuid: "card"),
                    displayName: "CARD",
                    lastSeenAt: Date()
                ),
                availability: .available,
                activity: .idle,
                isEjectable: true
            ),
        ],
        sidebarSelection: .allMedia,
        ejectingSourceIdentities: [],
        selectSidebar: { _ in },
        ejectSource: { _ in }
    )
}
