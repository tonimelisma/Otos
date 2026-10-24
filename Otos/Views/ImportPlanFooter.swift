import SwiftUI

/// Bottom import status surface for the selected removable source (ARC-047,
/// `docs/design/import-bar.md`). Three fixed zones, left to right: *what* (L1
/// over L3), *choices* (destination pop-up, eject/erase checkboxes), *the act*
/// (at most one prominent button — empty in the Done states that have no act
/// left, DES-052/DES-053). The view is passive: `ImportBarPresentation.map`
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
    let revealAttentionItems: (([MediaAssetID]) -> Void)?
    let sessionPreferences: ImportPreferences?
    let setSessionPreferences: ((ImportPreferences) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsEraseConfirmation = false

    /// Fixed content height (excludes the surface's own vertical padding), so
    /// the bar's total height never changes across states (DES-018, DES-053).
    /// The floor is the Preparing choices zone, the tallest content any state
    /// draws: the small linear track's 12 pt layout box, the 4 pt row gap, and
    /// the two control rows' 45 pt, measured with `NSHostingView.fittingSize`
    /// on 2026-09-13 (a regular-size track's box is 20 pt, which is why the
    /// track is `.small`).
    private static let contentHeight: CGFloat = 61

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
    /// own title/shortcut/tint. One owner forces every case through the same
    /// derivation, so no case can ignore `drawn.primaryEnabled` and render a
    /// live button in the cancelling state (`primaryEnabled: false`). A pure
    /// value type — not a rendered SwiftUI view — lets tests cover the
    /// renderer's input, not only the mapper's output. `nonisolated`
    /// deliberately opts out of `ImportPlanFooter`'s inferred `@MainActor`
    /// isolation (a `View`'s default) — this is pure computation with no UI
    /// state, and a test needs to call it off the main actor.
    nonisolated struct RenderedPrimary: Equatable {
        /// Empty exactly when `drawn.primaryAction` is `.none` — the state has
        /// no act, and the act zone renders nothing at all.
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
        case .none:
            title = ""
            isDefault = false
        case .importNewItems:
            title = "Import"
        case .ejectCard:
            title = "Eject Card"
        case let .eraseItems(count):
            title = "Erase \(count) \(count == 1 ? "Item" : "Items")"
            isDestructive = true
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
        // `auto 1fr auto`: *what* and *the act* size to their
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
        .animation(surfaceAnimation, value: drawn.kind)
        .transition(surfaceTransition)
        .accessibilityElement(children: .contain)
    }

    /// One hairline, before the middle zone, only when it has content worth
    /// separating from *what* — never before the act. The mockup draws at
    /// most one hairline per bar, and `.hidden` has nothing to divide.
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
        case let .choices(track, eraseEnabled, eraseDisabledReason):
            VStack(alignment: .leading, spacing: 4) {
                // Preparing's track sits above the controls it does not gate;
                // every other choices state holds the same 12 pt so the rows
                // never move between Preparing and Ready (DES-053).
                if let track {
                    progressTrackView(track)
                } else {
                    Color.clear.frame(height: 12)
                }
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

    /// `.help` is applied only when a reason exists — `.help("")` would still
    /// attach an empty tooltip while the toggle is enabled — and only to a
    /// wrapping `ZStack`, a distinct, always-enabled hit-testable container,
    /// never to the disabled `Toggle` itself. `.help` on a `.disabled` control
    /// is not reliably surfaced by AppKit's disabled-control hover handling,
    /// and DES-038 requires the explanation to actually reach the user, not
    /// merely to be attached to a control that may swallow hover events.
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
                .controlSize(.small)
        case let .determinate(completed, total):
            ProgressView(value: Double(completed), total: Double(max(total, 1)))
                .progressViewStyle(.linear)
                .controlSize(.small)
                .animation(reduceMotion ? .linear(duration: 0.1) : .linear(duration: 0.2), value: completed)
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

    /// One owner for every action's enabled state: `renderedPrimary.isEnabled`
    /// is applied here, not per case, so no case can render a live button by
    /// forgetting `.disabled` (the cancelling state, `primaryEnabled: false`).
    /// The zone holds its width whether or not it draws anything, so the states
    /// with no act (`.none`) leave the other two zones exactly where they were.
    private var actZone: some View {
        primaryButton
            .disabled(!renderedPrimary.isEnabled)
            .frame(minWidth: 140, alignment: .trailing)
    }

    @ViewBuilder
    private var primaryButton: some View {
        let rendered = renderedPrimary
        switch drawn.primaryAction {
        case .none:
            // Nothing to offer: no card left to eject or erase, and the batch a
            // "show" would navigate to is already selected (DES-053 exception,
            // `import-bar.md` "There is no `Show These Items` button"). The act
            // zone holds its width regardless, so no other zone moves.
            EmptyView()
        case .importNewItems:
            // The same push button whether or not the plan is ready: `actZone`
            // disables it from `primaryEnabled`, and macOS dims it in place. It
            // is never static text — a verb title says the control is
            // interactive, and a disabled control stays a control to VoiceOver
            // and the tab order (DES-053; HIG push buttons).
            styledPrimary(Button(rendered.title, action: queueImport), hint: "Imports new items from the card")
        case .ejectCard:
            styledPrimary(Button(rendered.title, action: ejectCard), hint: "Ejects the card")
        case let .eraseItems(count):
            styledPrimary(Button(rendered.title) {
                showsEraseConfirmation = true
            }.tint(rendered.isDestructive ? .red : nil), hint: "Deletes items from the card")
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
        case .cancel:
            styledPrimary(Button(rendered.title, action: cancelImport), hint: "Stops the current import")
        case .tryAgain:
            styledPrimary(Button(rendered.title) {
                retryPlanning?()
            })
        }
    }

    private func styledPrimary(_ content: some View, hint: String? = nil) -> some View {
        let styled = content
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(renderedPrimary.isDefault ? .defaultAction : .cancelAction)
            .frame(height: 30)
        return Group {
            if let hint {
                styled.accessibilityHint(hint)
            } else {
                styled
            }
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
