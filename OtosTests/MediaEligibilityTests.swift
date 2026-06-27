import Foundation
@testable import Otos
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
}
