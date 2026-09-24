import Foundation
@testable import OtosKit
import Testing
import UniformTypeIdentifiers

struct MediaEligibilityTests {
    @Test func catalogMediaIncludesImageAndMovieTypes() {
        #expect(MediaEligibility.isCatalogMedia(contentType: .jpeg))
        #expect(MediaEligibility.isCatalogMedia(contentType: .heic))
        #expect(MediaEligibility.isCatalogMedia(contentType: .png))
        #expect(MediaEligibility.isCatalogMedia(contentType: .mpeg4Movie))
        #expect(MediaEligibility.isCatalogMedia(contentType: .quickTimeMovie))
        #expect(MediaEligibility.isCatalogMedia(contentTypeIdentifier: "public.jpeg"))
        #expect(MediaEligibility.isCatalogMedia(contentTypeIdentifier: "public.mpeg-4"))
    }

    @Test func catalogMediaExcludesNilPlainTextAudioAndDocuments() {
        #expect(!MediaEligibility.isCatalogMedia(contentType: nil))
        #expect(!MediaEligibility.isCatalogMedia(contentTypeIdentifier: nil))
        #expect(!MediaEligibility.isCatalogMedia(contentType: .plainText))
        #expect(!MediaEligibility.isCatalogMedia(contentType: .mp3))
        #expect(!MediaEligibility.isCatalogMedia(contentType: .pdf))
        #expect(!MediaEligibility.isCatalogMedia(contentTypeIdentifier: "public.swift-source"))
    }

    @Test func videoUsesMovieConformanceOnly() {
        #expect(MediaEligibility.isVideo(contentTypeIdentifier: "public.mpeg-4"))
        #expect(MediaEligibility.isVideo(contentTypeIdentifier: "com.apple.quicktime-movie"))
        #expect(!MediaEligibility.isVideo(contentTypeIdentifier: "public.jpeg"))
        #expect(!MediaEligibility.isVideo(contentTypeIdentifier: nil))
    }

    @Test func skipsDeviceArtifactAndTrashPaths() {
        #expect(MediaEligibility.shouldSkipDirectory(name: ".Trash-1000"))
        #expect(MediaEligibility.shouldSkipDirectory(name: "$RECYCLE.BIN"))
        #expect(MediaEligibility.shouldSkipRelativePath(MediaRelativePath(rawValue: "M4ROOT/THMBNL/a.jpg")))
        #expect(MediaEligibility.shouldSkipRelativePath(MediaRelativePath(rawValue: "M4ROOT/CLIP/clip.xml")))
        #expect(MediaEligibility.shouldSkipRelativePath(MediaRelativePath(rawValue: "M4ROOT/SUB/a.jpg")))
        #expect(!MediaEligibility.shouldSkipRelativePath(MediaRelativePath(rawValue: "M4ROOT/CLIP/clip.mp4")))
        #expect(MediaEligibility.isRecognizedCompanion(relativePath: MediaRelativePath(rawValue: "a.xmp")))
        #expect(!MediaEligibility.isRecognizedCompanion(relativePath: MediaRelativePath(rawValue: "a.lrc")))
    }

    @Test func sourceEraseClassificationIsCaseInsensitiveAndLeavesUnknownUntouched() {
        #expect(SourceFileClass.classify(relativePath: MediaRelativePath(rawValue: "PRIVATE/M4ROOT/THMBNL/a.jpg"))
            == .sourceArtifact("sonyThumbnailDirectory"))
        #expect(SourceFileClass.classify(relativePath: MediaRelativePath(rawValue: "private/m4root/clip/C1.XML"))
            == .sourceArtifact("sonyClipXML"))
        #expect(SourceFileClass.classify(relativePath: MediaRelativePath(rawValue: "A.XMP")) == .usefulSidecar)
        #expect(SourceFileClass.classify(relativePath: MediaRelativePath(rawValue: "DCIM/A.AAE")) == .cruftSidecar)
        #expect(SourceFileClass.classify(relativePath: MediaRelativePath(rawValue: "notes.txt")) == .unknown)
    }
}
