import CoreGraphics
import Foundation
import MediaMetadata
@testable import OtosKit
import Testing

/// The Info pane's facts (APP-041, DES-088): every value Otos holds is formatted, an unknown
/// one says so instead of vanishing, and the rows a kind shows never change between items.
struct PhotoInfoTests {
    private let still = MediaAssetID(
        libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
        relativePath: MediaRelativePath(rawValue: "Trip/Day 1/IMG_0001.ARW")
    )

    @Test func unknownFactsReadUnknown() {
        let info = PhotoInfo.make(PhotoInfo.Source(id: still))

        #expect(info.title == "IMG_0001.ARW")
        #expect(info.captured == PhotoInfo.unknown)
        #expect(info.value("Kind") == "ARW")
        #expect(info.value("Camera") == PhotoInfo.unknown)
        #expect(info.value("Shutter Speed") == PhotoInfo.unknown)
        #expect(info.value("Place") == PhotoInfo.unknown)
        #expect(info.value("Size") == PhotoInfo.unknown)
        #expect(info.value("Folder") == "Pictures ▸ Trip ▸ Day 1")
        #expect(info.coordinate == nil)
    }

    @Test func aStillShowsEverythingOtosHolds() {
        let asset = MediaAsset(
            libraryRootPath: still.libraryRootPath,
            relativePath: still.relativePath,
            name: "IMG_0001.ARW",
            contentTypeIdentifier: nil,
            byteSize: 58_100_000,
            createdAt: nil,
            contentModifiedAt: nil,
            captureLocalTime: CaptureLocalTime(seconds: 1_794_066_120),
            bestKind: .raw,
            facesSourceSize: 58_100_000
        )
        let metadata = AssetMetadata(
            timestamps: [
                CaptureTimestampRecord(
                    role: "original", instant: Date(timeIntervalSince1970: 1_794_058_920), utcOffsetSeconds: 7200,
                    precision: "localWithOffset",
                    year: 2026, month: 11, day: 7, hour: 15, minute: 42, second: 0
                ),
            ],
            locations: [GeoRecord(source: "exifGPS", latitude: 60.16990, longitude: -24.93840, altitudeMeters: 12.4)],
            cameraMake: "SONY",
            cameraModel: "ILCE-7M4",
            lensModel: "FE 24-70mm F2.8 GM II",
            serialNumber: "1234567",
            exposure: ExposureRecord(Exposure(
                exposureTime: ExposureTime(numerator: 1, denominator: 250),
                fNumber: 2.8,
                isoSensitivity: 400,
                exposureBiasEV: 1.0 / 3.0,
                focalLengthMillimeters: 35,
                focalLengthIn35mmFilmMillimeters: 35,
                flash: Flash(fired: false, mode: .off),
                program: .aperturePriority,
                meteringMode: .pattern,
                whiteBalance: .auto
            ))
        )
        let overlay = PhotoInfoOverlay(companionFileNames: ["IMG_0001.xmp"], importedAt: nil, isEdited: true)

        var info = PhotoInfo.make(
            PhotoInfo.Source(
                id: still, asset: asset, metadata: metadata, overlay: overlay, kind: .raw,
                nativePixelSize: CGSize(width: 7008, height: 4672), libraryName: "Holiday", locality: .fetchable
            ),
            calendar: Calendar(identifier: .gregorian)
        )

        #expect(info.sections.map(\.id) == [.people, .recognized, .location, .file, .camera, .exposure])
        #expect(info.captured.hasSuffix(" UTC+02:00"))
        #expect(info.value("Camera") == "SONY ILCE-7M4")
        #expect(info.value("Lens") == "FE 24-70mm F2.8 GM II")
        #expect(info.value("Serial Number") == "1234567")
        #expect(info.value("Shutter Speed") == "1/250 s")
        #expect(info.value("Aperture") == "ƒ/2.8")
        #expect(info.value("ISO") == "400")
        #expect(info.value("Focal Length") == "35 mm (35 mm in 35 mm)")
        #expect(info.value("Compensation") == "+0.3 EV")
        #expect(info.value("Program") == "Aperture Priority")
        #expect(info.value("Metering") == "Evaluative")
        #expect(info.value("Flash") == "Did Not Fire, Off")
        #expect(info.value("White Balance") == "Auto")
        #expect(info.value("Coordinates") == "60.16990° N, 24.93840° W")
        #expect(info.value("Altitude") == "12 m")
        #expect(info.value("Kind") == "RAW image · ARW")
        #expect(info.value("Dimensions") == "7008 × 4672 (32.7 MP)")
        #expect(info.value("Folder") == "Holiday ▸ Trip ▸ Day 1")
        #expect(info.value("Original") == "Not Downloaded")
        #expect(info.value("Imported") == "Not Imported by Otos")
        #expect(info.value("Companions") == "IMG_0001.xmp")
        #expect(info.value("Edits") == "Edited")
        #expect(info.coordinate == PlaceCoordinate(latitude: 60.16990, longitude: -24.93840))

        info.placeName = "Helsinki, Finland"
        #expect(info.value("Place") == "Helsinki, Finland")
    }

    @Test func aVideoShowsVideoInsteadOfExposure() {
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "clip.mov")
        )
        let metadata = AssetMetadata(durationSeconds: 75, frameRate: 29.97, videoCodec: "hevc")

        let info = PhotoInfo.make(PhotoInfo.Source(
            id: id, metadata: metadata, kind: .video, nativePixelSize: CGSize(width: 3840, height: 2160), locality: .local
        ))

        #expect(info.sections.map(\.id) == [.people, .recognized, .location, .file, .camera, .video])
        #expect(info.value("Duration") == "1:15")
        #expect(info.value("Frame Rate") == "29.97 fps")
        #expect(info.value("Codec") == "HEVC")
        #expect(info.value("Kind") == "Video · MOV")
        #expect(info.value("Original") == "On This Mac")
    }

    /// With no face listed, People says `No Faces` only for a photo the catalog read and
    /// holds no face of, `Not Checked Yet` for one not read; anything it cannot know — several
    /// photos, a read not landed or of another photo, faces People does not list — is `—`.
    @Test func facesAreKnownOnlyOnceRead() {
        let other = MediaAssetID(libraryRootPath: still.libraryRootPath, relativePath: MediaRelativePath(rawValue: "IMG_0002.ARW"))
        let none = PhotoFacesRead(photo: still, isRead: true, faceCount: 0)
        #expect(PhotoFacesRead.line(for: [still], read: none) == "No Faces")
        #expect(PhotoFacesRead.line(for: [still], read: PhotoFacesRead(photo: still, isRead: false, faceCount: 0)) == "Not Checked Yet")
        #expect(PhotoFacesRead.line(for: [still], read: PhotoFacesRead(photo: still, isRead: true, faceCount: 2)) == PhotoInfo.notApplicable)
        #expect(PhotoFacesRead.line(for: [still], read: nil) == PhotoInfo.notApplicable)
        #expect(PhotoFacesRead.line(for: [other], read: none) == PhotoInfo.notApplicable)
        #expect(PhotoFacesRead.line(for: [still, other], read: none) == PhotoInfo.notApplicable)
        #expect(PhotoFacesRead.line(for: [], read: none) == PhotoInfo.notApplicable)
    }

    @Test func noSingleItemReadsDashesInTheStillLayout() {
        let none = PhotoInfo.none(itemCount: 0)
        let several = PhotoInfo.none(itemCount: 3)
        #expect(none.title == "No Selection")
        #expect(several.title == "3 Items")
        #expect(none.sections.map(\.id) == [.people, .recognized, .location, .file, .camera, .exposure])
        #expect(none.sections.flatMap(\.rows).allSatisfy { $0.value == PhotoInfo.notApplicable })
        #expect(none.captured == PhotoInfo.notApplicable)
    }

    /// In This Photo holds the named labels and the certain text; a reading still owed stays
    /// unknown rather than empty, and with no single item there is nothing to show.
    @Test func inThisPhotoShowsWhatSearchRecognised() {
        let overlay = PhotoInfoOverlay(
            companionFileNames: [], importedAt: nil, isEdited: false,
            sceneLabels: ["document", "screenshot"], textLines: ["BRIDGE CLOSED AHEAD"]
        )
        let read = PhotoInfo.make(PhotoInfo.Source(id: still, overlay: overlay, kind: .image, labelNames: ["asiakirja", "kuvakaappaus"]))
        #expect(read.recognized == PhotoInfo.Recognized(labels: ["asiakirja", "kuvakaappaus"], text: ["BRIDGE CLOSED AHEAD"]))
        let owed = PhotoInfo.make(PhotoInfo.Source(id: still, overlay: PhotoInfoOverlay(companionFileNames: [], importedAt: nil, isEdited: false)))
        #expect(owed.recognized == PhotoInfo.Recognized(labels: nil, text: nil))
        #expect(PhotoInfo.none(itemCount: 2).recognized == nil)
        #expect(PhotoInfo.Recognized.chipTitle("baseball hat", locale: Locale(identifier: "en_US")) == "Baseball hat")
        #expect(PhotoInfo.Recognized.chipTitle("iltapäivä", locale: Locale(identifier: "fi_FI")) == "Iltapäivä")
    }

    @Test func valuesAreWrittenAsPhotographersWriteThem() {
        #expect(PhotoInfo.shutterSpeed(ExposureTime(numerator: 10, denominator: 2500)) == "1/250 s")
        #expect(PhotoInfo.shutterSpeed(ExposureTime(numerator: 5, denominator: 2)) == "2.5 s")
        #expect(PhotoInfo.shutterSpeed(ExposureTime(numerator: 30, denominator: 1)) == "30 s")
        #expect(PhotoInfo.exposureBias(-2.0 / 3.0) == "−0.7 EV")
        #expect(PhotoInfo.exposureBias(0.02) == "0 EV")
        #expect(PhotoInfo.cameraName(make: "Canon", model: "Canon EOS R5") == "Canon EOS R5")
        #expect(PhotoInfo.cameraName(make: "Apple", model: "iPhone 17 Pro") == "Apple iPhone 17 Pro")
        #expect(PhotoInfo.flashDescription(Flash(exifValue: 0x20)) == "No Flash")
        #expect(PhotoInfo.flashDescription(Flash(exifValue: 0x59)) == "Fired, Auto, Red-Eye Reduction")
        #expect(PhotoInfo.utcOffset(-12600) == "UTC−03:30")
        #expect(PhotoInfo.codecName("other:XVID") == "XVID")
    }
}

extension PhotoInfo {
    /// The value of the row labelled `label`, in whichever section holds it.
    func value(_ label: String) -> String? {
        sections.flatMap(\.rows).first { $0.label == label }?.value
    }
}
