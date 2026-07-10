@testable import Otos
import Testing

struct MediaGridAnimationTests {
    @Test func suppressesApplyAnimationWhileScrollTickIsRecent() {
        #expect(MediaGridAnimation.suppressesApplyAnimation(lastScrollTickAge: 0))
        #expect(MediaGridAnimation.suppressesApplyAnimation(lastScrollTickAge: 0.16))
        #expect(
            MediaGridAnimation.suppressesApplyAnimation(
                lastScrollTickAge: MediaGridAnimation.applyAnimationScrollQuietThreshold - 0.001
            )
        )
    }

    @Test func allowsApplyAnimationAfterScrollQuietThreshold() {
        #expect(
            !MediaGridAnimation.suppressesApplyAnimation(
                lastScrollTickAge: MediaGridAnimation.applyAnimationScrollQuietThreshold
            )
        )
        #expect(MediaGridAnimation.suppressesApplyAnimation(lastScrollTickAge: 1) == false)
        #expect(MediaGridAnimation.suppressesApplyAnimation(lastScrollTickAge: .infinity) == false)
    }
}
