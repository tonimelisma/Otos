import Foundation
@testable import OtosKit
import Testing

struct EnrichmentLeaseGatewayTests {
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
            enrichedSourceSize: needsEnrichment ? nil : 1024,
            enrichedSourceMTimeSeconds: needsEnrichment ? nil : 1
        )
    }

    @Test func claimedUntilAddsLeaseDuration() {
        let now = Date(timeIntervalSince1970: 1000)
        let claimedUntil = EnrichmentLeaseGateway.claimedUntil(from: now)
        #expect(claimedUntil == now.timeIntervalSince1970 + EnrichmentLeaseGateway.claimLeaseDuration)
    }

    @Test func unclaimedPriorityIDsSkipsDuplicatesInClaimedSet() {
        let first = assetID()
        let second = MediaAssetID(
            libraryRootPath: rootPath,
            relativePath: MediaRelativePath(rawValue: "other.jpg")
        )
        var claimedIDs: Set<MediaAssetID> = [first]

        let unique = EnrichmentLeaseGateway.unclaimedPriorityIDs([first, second], claimedIDs: &claimedIDs)

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
            enrichedSourceSize: 1024,
            enrichedSourceMTimeSeconds: 1,
            contentHash: XXH3Digest128.empty,
            contentHashSourceSize: 1024,
            contentHashSourceMTimeSeconds: 1
        )
        #expect(currentAsset.needsEnrichment(hashRequired: true) == false)
        let assetsByID = [
            id: staleAsset,
            currentAsset.id: currentAsset,
        ]
        let rootIDsByPath = [rootPath: Int64(7)]

        let eligible = EnrichmentLeaseGateway.priorityClaimInputs(
            ids: [id, currentAsset.id],
            assetsByID: assetsByID,
            rootIDsByPath: rootIDsByPath,
            isRootEnrichable: { $0 == rootPath },
            isHashRequired: { _ in true }
        )

        #expect(eligible.count == 1)
        #expect(eligible[0].asset == staleAsset)
        #expect(eligible[0].rootID == 7)
    }

    @Test func enrichmentClaimQueryReturnsNilForEmptyInputs() {
        #expect(
            EnrichmentLeaseGateway.enrichmentClaimQuery(
                rootIDs: [],
                now: 0,
                claimNotAfter: 300,
                limit: 1,
                hashRequired: true
            ) == nil
        )
        #expect(
            EnrichmentLeaseGateway.enrichmentClaimQuery(
                rootIDs: [1],
                now: 0,
                claimNotAfter: 300,
                limit: 0,
                hashRequired: true
            ) == nil
        )
    }
}
