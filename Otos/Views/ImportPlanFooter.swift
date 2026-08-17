import SwiftUI

/// Bottom import status surface for the selected removable source (ARC-047,
/// `docs/design/import-bar.md`). Three fixed zones, left to right: *what* (L1
/// over L3), *choices* (destination pop-up, eject/erase checkboxes), *the act*
/// (one prominent button). The view is passive: `ImportBarPresentation.map`
/// computes every string and the middle zone's shape; this file renders that
/// value and calls intents (`AGENTS.md` → Architecture Standards). One fixed
/// height across every state (DES-018, DES-053) — a state with nothing to show
/// in the middle zone holds blank space rather than resizing the surface.
struct ImportPlanFooter: View {
    let presentation: MediaOperationSourcePresentation
    let fixedLibraries: [CatalogLibraryState]
    let sourceDisplayName: String
    let isCancelling: Bool
    let importPreferences: ImportPreferences
    let setDestination: (LibraryRootPath) -> Void
    let queueImport: () -> Void
    let cancelImport: () -> Void
    let ejectCard: () -> Void
    let retryPlanning: (() -> Void)?
    let showTheseItems: (() -> Void)?
    let revealAttentionItems: (([MediaAssetID]) -> Void)?
    let sessionPreferences: ImportPreferences?
    let setSessionPreferences: ((ImportPreferences) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsEraseConfirmation = false

    /// Fixed content height (excludes the surface's own vertical padding), so
    /// the bar's total height never changes across states (DES-018, DES-053):
    /// the choices zone's two 22 pt rows plus its row gap set the floor.
    private static let contentHeight: CGFloat = 50

    private var effectivePreferences: ImportPreferences {
        sessionPreferences ?? importPreferences
    }

    private var drawn: ImportBarDrawnState {
        ImportBarPresentation.map(
            presentation: presentation,
            preferences: effectivePreferences,
            sourceDisplayName: sourceDisplayName,
            isCancelling: isCancelling
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            whatZone
            Divider().overlay(DesignPalette.hairline(for: colorScheme))
            choicesZone
            Divider().overlay(DesignPalette.hairline(for: colorScheme))
            actZone
        }
        .frame(minHeight: Self.contentHeight, maxHeight: Self.contentHeight)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(DesignPalette.bar(for: colorScheme))
        .animation(surfaceAnimation, value: drawn)
        .transition(surfaceTransition)
        .accessibilityElement(children: .contain)
    }

    // MARK: - What

    private var whatZone: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                switch drawn.primaryBadge {
                case .checkmark:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(checkmarkTransition)
                case .attention:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .transition(checkmarkTransition)
                case .none:
                    EmptyView()
                }
                Text(drawn.primaryLine)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(DesignPalette.label(for: colorScheme))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(drawn.primaryLine)
            secondaryLineView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var secondaryLineView: some View {
        switch drawn.secondaryLine {
        case .none:
            Color.clear.frame(height: 14)
        case let .plain(text):
            Text(text)
                .font(.subheadline)
                .foregroundStyle(DesignPalette.l3(for: colorScheme))
                .monospacedDigit()
                .lineLimit(1)
        case let .attention(clause, revealLabel, itemIDs):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(clause)
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
                    .monospacedDigit()
                    .lineLimit(1)
                Button(revealLabel) {
                    revealAttentionItems?(itemIDs)
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
            }
        }
    }

    // MARK: - Choices

    @ViewBuilder
    private var choicesZone: some View {
        switch drawn.middleZone {
        case let .choices(eraseEnabled, eraseDisabledReason):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    introLabel("Copy into")
                    Picker("Copy into", selection: destinationBinding) {
                        ForEach(fixedLibraries) { library in
                            Text(library.displayName).tag(Optional(library.path))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
                HStack(spacing: 6) {
                    introLabel("Afterwards")
                    Toggle("Eject the card", isOn: ejectPreferenceBinding)
                        .toggleStyle(.checkbox)
                    Toggle("Erase the card", isOn: erasePreferenceBinding)
                        .toggleStyle(.checkbox)
                        .disabled(!eraseEnabled)
                        .help(eraseDisabledReason ?? "")
                }
            }
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .addLibraryButton:
            SettingsLink {
                Text("Add a Library…")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case let .progress(track, caption):
            VStack(alignment: .leading, spacing: 4) {
                progressTrackView(track)
                if let caption {
                    Text(caption)
                        .font(.subheadline)
                        .foregroundStyle(DesignPalette.l3(for: colorScheme))
                        .lineLimit(1)
                } else {
                    Color.clear.frame(height: 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .hidden:
            Color.clear.frame(maxWidth: .infinity)
        }
    }

    private func introLabel(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(DesignPalette.l3(for: colorScheme))
            .frame(width: 66, alignment: .leading)
    }

    @ViewBuilder
    private func progressTrackView(_ track: ImportBarDrawnState.ProgressTrack) -> some View {
        switch track {
        case .indeterminate:
            ProgressView()
                .progressViewStyle(.linear)
        case let .determinate(completed, total):
            ProgressView(value: Double(completed), total: Double(max(total, 1)))
                .progressViewStyle(.linear)
        }
    }

    private var destinationBinding: Binding<LibraryRootPath?> {
        Binding(
            get: { presentation.destinationPath },
            set: { path in
                if let path {
                    setDestination(path)
                }
            }
        )
    }

    private var ejectPreferenceBinding: Binding<Bool> {
        Binding(
            get: { effectivePreferences.autoEjectAfterImport },
            set: { newValue in
                var updated = effectivePreferences
                updated.autoEjectAfterImport = newValue
                setSessionPreferences?(updated)
            }
        )
    }

    private var erasePreferenceBinding: Binding<Bool> {
        Binding(
            get: { effectivePreferences.deleteSourceAfterImport },
            set: { newValue in
                var updated = effectivePreferences
                updated.deleteSourceAfterImport = newValue
                setSessionPreferences?(updated)
            }
        )
    }

    // MARK: - The act

    private var actZone: some View {
        HStack(spacing: 8) {
            if drawn.showsSecondaryShowItemsButton {
                Button("Show These Items") {
                    showTheseItems?()
                }
                .buttonStyle(.borderless)
            }
            primaryButton
        }
        .frame(minWidth: 140, alignment: .trailing)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch drawn.primaryAction {
        case .importPending:
            Button("Import") {}
                .disabled(true)
                .buttonStyle(.borderedProminent)
                .frame(height: 30)
                .accessibilityHint("Imports new items from the card")
        case let .importItems(count):
            Button("Import \(count) \(count == 1 ? "Item" : "Items")", action: queueImport)
                .disabled(!drawn.primaryEnabled)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .frame(height: 30)
                .accessibilityHint("Imports new items from the card")
        case .ejectCard:
            Button("Eject Card", action: ejectCard)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .frame(height: 30)
                .accessibilityHint("Ejects the card")
        case let .eraseItems(count):
            Button("Erase \(count) \(count == 1 ? "Item" : "Items")") {
                showsEraseConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.defaultAction)
            .frame(height: 30)
            .accessibilityHint("Deletes items from the card")
            .confirmationDialog(
                "Erase \(sourceDisplayName)?",
                isPresented: $showsEraseConfirmation,
                titleVisibility: .visible
            ) {
                Button("Erase", role: .destructive, action: queueImport)
                Button("Cancel", role: .cancel) {}
            } message: {
                if drawn.eraseConfirmationProvenClean {
                    let destinationName = presentation.destinationDisplayName ?? "your library"
                    Text(
                        "\(count) \(count == 1 ? "item" : "items") will be deleted from the card. " +
                            "All of them are already in \(destinationName)."
                    )
                } else {
                    Text("\(count) \(count == 1 ? "item" : "items") will be deleted from the card.")
                }
            }
        case .showTheseItems:
            Button("Show These Items") {
                showTheseItems?()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .frame(height: 30)
        case .cancel:
            Button("Cancel", action: cancelImport)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
                .frame(height: 30)
                .accessibilityHint("Stops the current import")
        case .tryAgain:
            Button("Try Again") {
                retryPlanning?()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .frame(height: 30)
        }
    }

    // MARK: - Motion (DES-070–075)

    private var surfaceAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.85)
    }

    private var surfaceTransition: AnyTransition {
        reduceMotion
            ? .opacity.animation(.easeInOut(duration: 0.15))
            : .move(edge: .bottom).combined(with: .opacity)
    }

    private var checkmarkTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .scale(scale: 0.6).combined(with: .opacity)
    }
}
