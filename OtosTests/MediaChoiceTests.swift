import Foundation
@testable import OtosKit
import Testing

struct MediaChoiceTests {
    // Validates: APP-024
    /// DES-066: neutral has no button, so the third state is reached by pressing
    /// the act the item already carries. Both the AppKit tile and the SwiftUI
    /// Loupe/Compare control resolve through this one function rather than each
    /// re-deriving the rule.
    @Test func pressingTheCarriedActClearsItToNotRated() {
        #expect(MediaChoiceToggle.like.resolved(from: .liked) == .notRated)
        #expect(MediaChoiceToggle.dislike.resolved(from: .disliked) == .notRated)

        #expect(MediaChoiceToggle.like.resolved(from: .notRated) == .liked)
        #expect(MediaChoiceToggle.dislike.resolved(from: .notRated) == .disliked)
        // Crossing straight from one act to the other never detours via neutral.
        #expect(MediaChoiceToggle.like.resolved(from: .disliked) == .liked)
        #expect(MediaChoiceToggle.dislike.resolved(from: .liked) == .disliked)
    }

    // Validates: APP-025
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

    // Validates: APP-025
    @Test func selectingAllChoicesCanonicalizesToNoCurationRestriction() {
        var filter = MediaFilter()
        for choice in MediaChoice.allCases {
            filter = filter.settingChoice(choice, included: true)
        }
        #expect(filter == .all)
        #expect(filter.isActive == false)
    }
}
