//
//  OtosTests.swift
//  OtosTests
//
//  Created by Taylor on 6/2/26.
//

import Foundation
@testable import OtosKit
import Testing

struct OtosTests {
    @Test func mediaFixturesArePresent() {
        let fixtureDirectory = SourceTree.mediaFixtures

        let expectedFiles = [
            "jpeg-exif-offset-date.jpg",
            "ios-heic-offset-date.heic",
            "mp4-no-embedded-capture-date.mp4",
            "mov-no-embedded-capture-date.mov",
        ]

        for expectedFile in expectedFiles {
            let fixtureURL = fixtureDirectory.appending(path: expectedFile)
            #expect(FileManager.default.fileExists(atPath: fixtureURL.path()), "\(expectedFile) fixture is missing")
        }
    }
}
