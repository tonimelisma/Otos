import Foundation
@testable import OtosKit
import Testing

struct MediaChoiceTests {
    @Test func choicesAreOneMutuallyExclusiveThreeStateValue() {
        #expect(MediaChoice.allCases == [.liked, .notRated, .disliked])
        #expect(MediaChoice.default == .notRated)
        #expect(MediaChoice.liked.actionLabel == "Like")
        #expect(MediaChoice.notRated.actionLabel == "Mark as Not Rated")
        #expect(MediaChoice.disliked.actionLabel == "Dislike")
    }

    /// DES-068: the item's single accessibility value, not a per-button
    /// "Selected"/"Not selected" (plan 0095 D22). `MediaChoiceHoverRegion`
    /// (Loupe/Compare) and `MediaAssetTilePresentation.accessibilityValue`
    /// (Grid/filmstrip) both read this exact string off `MediaChoice`.
    @Test func accessibilityValuesAreTheDES068Strings() {
        #expect(MediaChoice.liked.accessibilityValue == "liked")
        #expect(MediaChoice.notRated.accessibilityValue == "not rated")
        #expect(MediaChoice.disliked.accessibilityValue == "disliked")
    }

    @Test func choiceFilterUsesOrWithinCurationAndAndAcrossMediaGroups() {
        let jpeg = MediaFormatToken(rawValue: "JPEG")
        let likedOnly = MediaFilter(choices: [.liked])
        #expect(likedOnly.includes(kind: .image, format: jpeg, choice: .liked))
        #expect(!likedOnly.includes(kind: .image, format: jpeg, choice: .notRated))

        let likedOrNotRated = MediaFilter(choices: [.liked, .notRated])
        #expect(likedOrNotRated.includes(kind: .image, format: jpeg, choice: .liked))
        #expect(likedOrNotRated.includes(kind: .image, format: jpeg, choice: .notRated))
        #expect(!likedOrNotRated.includes(kind: .image, format: jpeg, choice: .disliked))

        let imageLiked = MediaFilter(kinds: [.image], choices: [.liked])
        #expect(imageLiked.includes(kind: .image, format: jpeg, choice: .liked))
        #expect(!imageLiked.includes(kind: .video, format: MediaFormatToken(rawValue: "MP4"), choice: .liked))
        #expect(!imageLiked.includes(kind: .image, format: jpeg, choice: .disliked))
    }

    @Test func selectingAllChoicesCanonicalizesToNoCurationRestriction() {
        var filter = MediaFilter()
        for choice in MediaChoice.allCases {
            filter = filter.settingChoice(choice, included: true)
        }
        #expect(filter == .all)
        #expect(filter.isActive == false)
    }

    @Test func choiceQueryUsesBoundArgumentsAndDeterministicOrder() throws {
        let descriptor = CatalogQueryDescriptor(
            scope: .allMedia,
            filter: MediaFilter(choices: [.liked, .disliked]),
            sort: .filenameAscending
        )
        let query = try #require(CatalogQueryGateway.orderedAssetIDQuery(
            descriptor: descriptor,
            scope: CatalogScopePredicate(rootIDs: [7])
        ))
        #expect(query.sql.contains("media_choice IN (?, ?)") || query.sql.contains("media_choice IN (?,?)"))
        #expect(!query.sql.contains("liked"))
        #expect(!query.sql.contains("disliked"))
        #expect(query.sql.contains("ORDER BY name_sort_key"))
    }
}
