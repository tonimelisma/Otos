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

    private var renderedPrimary: RenderedPrimary {
        Self.renderedPrimary(for: drawn)
    }

    /// The primary button's fully-derived render intent: title, enabled
    /// state, default-keyboard-shortcut eligibility, and destructive tint —
    /// computed once here and consumed by every `primaryAction` case in
    /// `primaryButton`, rather than each case independently re-deriving its
    /// own title/shortcut/tint. `drawn.primaryEnabled` used to be read by
    /// only 1 of 7 cases; the cancelling state (`primaryEnabled: false`)
    /// rendered a live button because nothing forced every case through one
    /// owner (plan 0095 D11). A pure value type — not a rendered SwiftUI
    /// view — is what closes the gap that let that ship green: the mapper
    /// was fully covered by tests, the renderer was not. `nonisolated`
    /// deliberately opts out of `ImportPlanFooter`'s inferred `@MainActor`
    /// isolation (a `View`'s default) — this is pure computation with no UI
    /// state, and a test needs to call it off the main actor.
    nonisolated struct RenderedPrimary: Equatable {
        let title: String
        let isEnabled: Bool
        let isDefault: Bool
        let isDestructive: Bool
    }

    nonisolated static func renderedPrimary(for drawn: ImportBarDrawnState) -> RenderedPrimary {
        let title: String
        var isDefault = true
        var isDestructive = false
        switch drawn.primaryAction {
        case .importPending:
            title = "Import"
        case let .importItems(count):
            title = "Import \(count) \(count == 1 ? "Item" : "Items")"
        case .ejectCard:
            title = "Eject Card"
        case let .eraseItems(count):
            title = "Erase \(count) \(count == 1 ? "Item" : "Items")"
            isDestructive = true
        case .showTheseItems:
            title = "Show These Items"
        case .cancel:
            title = "Cancel"
            isDefault = false
        case .tryAgain:
            title = "Try Again"
        }
        return RenderedPrimary(
            title: title,
            isEnabled: drawn.primaryEnabled,
            isDefault: isDefault,
            isDestructive: isDestructive
        )
    }

    var body: some View {
        // `auto 1fr auto` (plan 0095 D14): *what* and *the act* size to their
        // own content; *choices* is the only zone that keeps
        // `.frame(maxWidth: .infinity)` and so is the only one that absorbs
        // the HStack's slack.
        HStack(alignment: .top, spacing: 28) {
            whatZone
            if showsMiddleHairline {
                Divider().overlay(DesignPalette.hairline(for: colorScheme))
            }
            choicesZone
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

    /// One hairline, before the middle zone, only when it has content worth
    /// separating from *what* — never before the act (plan 0095 D13: the
    /// mockup draws at most one hairline per bar; this file drew two in
    /// every state, including `.hidden`, where there is nothing to divide).
    private var showsMiddleHairline: Bool {
        switch drawn.middleZone {
        case .choices, .progress: true
        case .addLibraryButton, .hidden: false
        }
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
                    .font(.footnote)
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
                    eraseToggle(eraseEnabled: eraseEnabled, eraseDisabledReason: eraseDisabledReason)
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

    /// `.help(eraseDisabledReason ?? "")` used to attach an empty tooltip
    /// even while the toggle was enabled, and attaching `.help` directly to a
    /// `.disabled` control is not reliably surfaced by AppKit's disabled-
    /// control hover handling — DES-038 requires the explanation to actually
    /// reach the user, not merely to be attached to a control that may
    /// swallow hover events (plan 0095 D24). `.help` is applied only when a
    /// reason exists, and only to a wrapping `ZStack` — a distinct, always-
    /// enabled hit-testable container — never to the disabled `Toggle` itself.
    @ViewBuilder
    private func eraseToggle(eraseEnabled: Bool, eraseDisabledReason: String?) -> some View {
        let toggle = Toggle("Erase the card", isOn: erasePreferenceBinding)
            .toggleStyle(.checkbox)
            .disabled(!eraseEnabled)
        if let eraseDisabledReason {
            ZStack { toggle }
                .help(eraseDisabledReason)
        } else {
            toggle
        }
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
            // One owner for every action's enabled state (plan 0095 D11):
            // `renderedPrimary.isEnabled` is applied here, not per-case — a
            // case that forgets `.disabled` used to render a live button
            // (the cancelling state, `primaryEnabled: false`).
            primaryButton
                .disabled(!renderedPrimary.isEnabled)
        }
        .frame(minWidth: 140, alignment: .trailing)
    }

    @ViewBuilder
    private var primaryButton: some View {
        let rendered = renderedPrimary
        switch drawn.primaryAction {
        case .importPending:
            Button(rendered.title) {}
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(rendered.isDefault ? .defaultAction : .cancelAction)
                .frame(height: 30)
                .accessibilityHint("Imports new items from the card")
        case .importItems:
            Button(rendered.title, action: queueImport)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(rendered.isDefault ? .defaultAction : .cancelAction)
                .frame(height: 30)
                .accessibilityHint("Imports new items from the card")
        case .ejectCard:
            Button(rendered.title, action: ejectCard)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(rendered.isDefault ? .defaultAction : .cancelAction)
                .frame(height: 30)
                .accessibilityHint("Ejects the card")
        case let .eraseItems(count):
            Button(rendered.title) {
                showsEraseConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .tint(rendered.isDestructive ? .red : nil)
            .keyboardShortcut(rendered.isDefault ? .defaultAction : .cancelAction)
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
            Button(rendered.title) {
                showTheseItems?()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(rendered.isDefault ? .defaultAction : .cancelAction)
            .frame(height: 30)
        case .cancel:
            Button(rendered.title, action: cancelImport)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(rendered.isDefault ? .defaultAction : .cancelAction)
                .frame(height: 30)
                .accessibilityHint("Stops the current import")
        case .tryAgain:
            Button(rendered.title) {
                retryPlanning?()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(rendered.isDefault ? .defaultAction : .cancelAction)
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
