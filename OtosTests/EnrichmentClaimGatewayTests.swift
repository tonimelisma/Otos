import Foundation
@testable import OtosKit
import Testing

struct EnrichmentClaimGatewayTests {
    private let rootPath = LibraryRootPath(rawValue: "/tmp/enrichment-lease-root")
    private let assetPath = MediaRelativePath(rawValue: "photo.jpg")

    private func assetID() -> MediaAssetID {
        MediaAssetID(libraryRootPath: rootPath, relativePath: assetPath)
    }

    private func asset(needsEnrichment: Bool = true) -> MediaAsset {
        MediaAsset(
            libraryRootPath: rootPath,
            relativePath: assetPath,
            name: "photo",
            contentTypeIdentifier: "public.jpeg",
            byteSize: 1024,
            createdAt: nil,
            contentModifiedAt: nil,
            metadataSourceSize: needsEnrichment ? nil : 1024,
            metadataSourceMTimeSeconds: needsEnrichment ? nil : 1
        )
    }

    @Test func unclaimedPriorityIDsSkipsDuplicatesInClaimedSet() {
        let first = assetID()
        let second = MediaAssetID(
            libraryRootPath: rootPath,
            relativePath: MediaRelativePath(rawValue: "other.jpg")
        )
        var claimedIDs: Set<MediaAssetID> = [first]

        let unique = EnrichmentClaimGateway.unclaimedPriorityIDs([first, second], claimedIDs: &claimedIDs)

        #expect(unique == [second])
        #expect(claimedIDs == [first, second])
    }

    @Test func priorityClaimInputsFiltersUnavailableAndNonStaleAssets() {
        let id = assetID()
        let staleAsset = asset(needsEnrichment: true)
        let currentRelativePath = MediaRelativePath(rawValue: "current.jpg")
        let currentAsset = MediaAsset(
            libraryRootPath: rootPath,
            relativePath: currentRelativePath,
            name: "current",
            contentTypeIdentifier: "public.jpeg",
            byteSize: 1024,
            createdAt: nil,
            contentModifiedAt: Date(timeIntervalSince1970: 1),
            metadataSourceSize: 1024,
            metadataSourceMTimeSeconds: 1,
            renderedSourceSize: 1024,
            renderedSourceMTimeSeconds: 1,
            contentHash: XXH3Digest128.empty,
            contentHashSourceSize: 1024,
            contentHashSourceMTimeSeconds: 1
        )
        #expect(currentAsset.needsEnrichment(.products) == false)
        let assetsByID = [
            id: staleAsset,
            currentAsset.id: currentAsset,
        ]
        let rootIDsByPath = [rootPath: Int64(7)]

        let eligible = EnrichmentClaimGateway.priorityClaimInputs(
            ids: [id, currentAsset.id],
            assetsByID: assetsByID,
            rootIDsByPath: rootIDsByPath,
            isRootEnrichable: { $0 == rootPath },
            firstClaim: { _ in .products }
        )

        #expect(eligible.count == 1)
        #expect(eligible[0].asset == staleAsset)
        #expect(eligible[0].rootID == 7)
    }
}
