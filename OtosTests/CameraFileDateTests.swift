import Foundation
@testable import OtosKit
import Testing

struct CameraFileDateTests {
    private static let creation = Date(timeIntervalSince1970: 1000)
    private static let modification = Date(timeIntervalSince1970: 2000)

    @Test func captureDateIsCreationFirst() {
        let result = CameraFileDate.captureDate(
            creationDate: Self.creation,
            exifCreationDate: nil,
            fileCreationDate: nil,
            modificationDate: Self.modification,
            fileModificationDate: nil,
            exifModificationDate: nil
        )
        #expect(result == Self.creation)
    }

    @Test func modificationDateIsModificationFirst() {
        let result = CameraFileDate.modificationDate(
            creationDate: Self.creation,
            exifCreationDate: nil,
            fileCreationDate: nil,
            modificationDate: Self.modification,
            fileModificationDate: nil,
            exifModificationDate: nil
        )
        #expect(result == Self.modification)
    }

    @Test func captureAndModificationDifferWhenBothCamerasFieldsPresent() {
        let capture = CameraFileDate.captureDate(
            creationDate: Self.creation,
            exifCreationDate: nil,
            fileCreationDate: nil,
            modificationDate: Self.modification,
            fileModificationDate: nil,
            exifModificationDate: nil
        )
        let modification = CameraFileDate.modificationDate(
            creationDate: Self.creation,
            exifCreationDate: nil,
            fileCreationDate: nil,
            modificationDate: Self.modification,
            fileModificationDate: nil,
            exifModificationDate: nil
        )
        #expect(capture != modification)
    }

    @Test func captureDateFallsBackThroughPrecedenceWhenEarlierFieldsAreNil() {
        let result = CameraFileDate.captureDate(
            creationDate: nil,
            exifCreationDate: nil,
            fileCreationDate: nil,
            modificationDate: nil,
            fileModificationDate: nil,
            exifModificationDate: Self.modification
        )
        #expect(result == Self.modification)
    }

    @Test func modificationDateFallsBackThroughPrecedenceWhenEarlierFieldsAreNil() {
        let result = CameraFileDate.modificationDate(
            creationDate: nil,
            exifCreationDate: nil,
            fileCreationDate: Self.creation,
            modificationDate: nil,
            fileModificationDate: nil,
            exifModificationDate: nil
        )
        #expect(result == Self.creation)
    }

    @Test func allNilYieldsNilForBothFunctions() {
        #expect(CameraFileDate.captureDate(
            creationDate: nil, exifCreationDate: nil, fileCreationDate: nil,
            modificationDate: nil, fileModificationDate: nil, exifModificationDate: nil
        ) == nil)
        #expect(CameraFileDate.modificationDate(
            creationDate: nil, exifCreationDate: nil, fileCreationDate: nil,
            modificationDate: nil, fileModificationDate: nil, exifModificationDate: nil
        ) == nil)
    }

    @Test func epochZeroIsTreatedAsInvalidAndSkipped() {
        let epochZero = Date(timeIntervalSince1970: 0)
        let result = CameraFileDate.captureDate(
            creationDate: epochZero,
            exifCreationDate: epochZero,
            fileCreationDate: epochZero,
            modificationDate: Self.modification,
            fileModificationDate: nil,
            exifModificationDate: nil
        )
        #expect(result == Self.modification)
    }

    @Test func allEpochZeroYieldsNil() {
        let epochZero = Date(timeIntervalSince1970: 0)
        let result = CameraFileDate.modificationDate(
            creationDate: epochZero,
            exifCreationDate: epochZero,
            fileCreationDate: epochZero,
            modificationDate: epochZero,
            fileModificationDate: epochZero,
            exifModificationDate: epochZero
        )
        #expect(result == nil)
    }
}
