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
