import Darwin
@testable import OtosKit
import Testing

/// The open-file limit Otos raises at launch: `OPEN_MAX`, or the hard limit when lower,
/// never below the limit in force, because `setrlimit(2)` refuses more than `OPEN_MAX` for
/// `RLIMIT_NOFILE`.
struct OpenFileLimitTests {
    @Test func theTargetIsOpenMaxOrTheHardLimitAndNeverLower() {
        let openMax = rlim_t(OPEN_MAX)
        // `RLIM_INFINITY` in <sys/resource.h>, a macro Swift does not import.
        let unlimited = rlim_t(Int64.max)
        #expect(OpenFileLimit.target(current: 256, hard: unlimited) == openMax)
        #expect(OpenFileLimit.target(current: 256, hard: 4096) == 4096)
        #expect(OpenFileLimit.target(current: 20000, hard: unlimited) == 20000)
        #expect(OpenFileLimit.target(current: 256, hard: 256) == 256)
    }

    @Test func raisingLeavesTheProcessAtLeastAtTheTarget() {
        var before = rlimit()
        #expect(getrlimit(RLIMIT_NOFILE, &before) == 0)

        OpenFileLimit.raise()

        var after = rlimit()
        #expect(getrlimit(RLIMIT_NOFILE, &after) == 0)
        #expect(after.rlim_cur == OpenFileLimit.target(current: before.rlim_cur, hard: before.rlim_max))
    }
}
