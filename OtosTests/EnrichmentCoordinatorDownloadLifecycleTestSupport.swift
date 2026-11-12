import Foundation
@testable import OtosKit
import Testing

actor FakeMaterialization {
    private var dataless: Set<String>

    init(dataless: Set<String>) {
        self.dataless = dataless
    }

    func isDataless(_ path: String) -> Bool {
        dataless.contains(path)
    }

    func materialize(_ path: String) {
        dataless.remove(path)
    }
}
