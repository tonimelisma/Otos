/// Small value carriers used while `CatalogProjection` builds a window state.
///
/// These are kept outside the actor file so the actor's source stays focused on
/// publication ownership rather than local tuple plumbing.
nonisolated struct CatalogProjectionWindowStateParts {
    let title: String
    let libraries: [CatalogLibraryState]
    let removableSources: [CatalogLibraryState]
    let resolvedDescriptor: CatalogQueryDescriptor
    let queryGeneration: UInt64
    let scopedAssetIDs: [MediaAssetID]
    let filterOptions: CatalogFilterOptions
    let mediaEmptyState: CatalogMediaEmptyState
}

nonisolated struct CatalogProjectionSupplementaryBuildInput {
    let resolvedDescriptor: CatalogQueryDescriptor
    let allRoots: [CatalogLibraryState]
    let orderedAssetIDs: [MediaAssetID]
    let scopedAssetIDs: [MediaAssetID]
    let store: CatalogStore?
    let availableLibraryPaths: Set<LibraryRootPath>
}

nonisolated struct CatalogProjectionEmptyStateBuildInput {
    let descriptor: CatalogQueryDescriptor
    let libraries: [CatalogLibraryState]
    let rootsByPath: [LibraryRootPath: CatalogLibraryState]
    let orderedAssetIDs: [MediaAssetID]
    let scopedAssetIDs: [MediaAssetID]
    let store: CatalogStore?
    let availableLibraryPaths: Set<LibraryRootPath>
}
