import Foundation
@testable import OtosKit
import Testing

/// `RenderedPrimary` is the render-intent seam plan 0095 increment 8 added to
/// close the gap that let D11 ship green: `ImportBarPresentation` (the
/// mapper) was fully covered by tests, but `ImportPlanFooter` (the renderer)
/// was not, so a `primaryAction` case that forgot `.disabled` rendered a live
/// button anyway. These tests assert what the renderer actually derives —
/// title, enabled state, default-shortcut eligibility, destructive tint — as
/// a pure value, not a rendered SwiftUI view.
struct ImportPlanFooterRenderedPrimaryTests {
    private static func drawn(
        primaryAction: ImportBarDrawnState.PrimaryAction,
        primaryEnabled: Bool
    ) -> ImportBarDrawnState {
        ImportBarDrawnState(
            kind: .ready,
            primaryLine: "test",
            primaryBadge: .none,
            secondaryLine: .none,
            middleZone: .hidden,
            primaryAction: primaryAction,
            primaryEnabled: primaryEnabled,
            eraseConfirmationProvenClean: false
        )
    }

    private static let allActions: [ImportBarDrawnState.PrimaryAction] = [
        .importNewItems,
        .ejectCard,
        .eraseItems(count: 3),
        .cancel,
        .tryAgain,
    ]

    /// Plan 0095 D11: `drawn.primaryEnabled` was read by only 1 of 7 actions;
    /// the cancelling state (`primaryEnabled: false`) rendered a live button
    /// because nothing forced every case through one owner.
    @Test func everyActionHonorsPrimaryEnabledRegardlessOfCase() {
        for action in Self.allActions {
            let enabled = ImportPlanFooter.renderedPrimary(for: Self.drawn(primaryAction: action, primaryEnabled: true))
            #expect(enabled.isEnabled, "\(action) should be enabled when primaryEnabled is true")
            let disabled = ImportPlanFooter.renderedPrimary(for: Self.drawn(primaryAction: action, primaryEnabled: false))
            #expect(!disabled.isEnabled, "\(action) should be disabled when primaryEnabled is false")
        }
    }

    @Test func titlesMatchEachAction() {
        func title(_ action: ImportBarDrawnState.PrimaryAction) -> String {
            ImportPlanFooter.renderedPrimary(for: Self.drawn(primaryAction: action, primaryEnabled: true)).title
        }
        #expect(title(.importNewItems) == "Import")
        #expect(title(.ejectCard) == "Eject Card")
        #expect(title(.eraseItems(count: 1)) == "Erase 1 Item")
        #expect(title(.eraseItems(count: 3)) == "Erase 3 Items")
        #expect(title(.none).isEmpty)
        #expect(title(.cancel) == "Cancel")
        #expect(title(.tryAgain) == "Try Again")
    }

    @Test func onlyEraseIsDestructive() {
        for action in Self.allActions where action != .eraseItems(count: 3) {
            let rendered = ImportPlanFooter.renderedPrimary(for: Self.drawn(primaryAction: action, primaryEnabled: true))
            #expect(!rendered.isDestructive, "\(action) should not be destructive")
        }
        let erase = ImportPlanFooter.renderedPrimary(for: Self.drawn(primaryAction: .eraseItems(count: 3), primaryEnabled: true))
        #expect(erase.isDestructive)
    }

    @Test func onlyCancelIsNotDefault() {
        for action in Self.allActions where action != .cancel {
            let rendered = ImportPlanFooter.renderedPrimary(for: Self.drawn(primaryAction: action, primaryEnabled: true))
            #expect(rendered.isDefault, "\(action) should be the default action")
        }
        let cancel = ImportPlanFooter.renderedPrimary(for: Self.drawn(primaryAction: .cancel, primaryEnabled: true))
        #expect(!cancel.isDefault)
    }

    /// `.none` renders no button at all, so it has no title and nothing for
    /// Return to fire — the act zone is empty (DES-053's "subject no longer
    /// exists" exception, `import-bar.md` state F).
    @Test func theEmptyActionRendersNoTitleAndTakesNoReturnKey() {
        let rendered = ImportPlanFooter.renderedPrimary(for: Self.drawn(primaryAction: .none, primaryEnabled: true))
        #expect(rendered.title.isEmpty)
        #expect(!rendered.isDefault)
        #expect(!rendered.isDestructive)
    }
}
