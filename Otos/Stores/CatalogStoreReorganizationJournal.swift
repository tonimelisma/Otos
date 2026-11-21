import Foundation
import GRDB
import OSLog

extension CatalogStore {
    // MARK: - Reorganization journal CRUD

    static func insertActiveReorganizationComponent(
        _ component: ActiveReorganizationComponent,
        db: Database
    ) throws {
        try db.execute(
            sql: ReorganizationJournalSQL.insertComponentSQL,
            arguments: [
                component.componentKey.rawValue,
                component.libraryRootPath.rawValue,
                Int64(component.planGeneration),
                Int64(component.plannedRootRevision),
                component.phase.rawValue,
                component.nextStepIndex,
                component.createdAt.timeIntervalSince1970,
                component.updatedAt.timeIntervalSince1970,
            ]
        )
        for member in component.members {
            try db.execute(
                sql: ReorganizationJournalSQL.insertMemberSQL,
                arguments: [
                    component.componentKey.rawValue,
                    member.memberIndex,
                    member.kind.rawValue,
                    member.logicalSourceRelativePath.rawValue,
                    member.currentRelativePath.rawValue,
                    member.finalRelativePath.rawValue,
                    member.byteSize,
                    member.contentModifiedAt.timeIntervalSince1970,
                ]
            )
        }
        for step in component.steps {
            try db.execute(
                sql: ReorganizationJournalSQL.insertStepSQL,
                arguments: [
                    component.componentKey.rawValue,
                    step.stepIndex,
                    step.memberIndex,
                    step.sourceRelativePath.rawValue,
                    step.destinationRelativePath.rawValue,
                    step.phase.rawValue,
                ]
            )
        }
        for directory in component.directories {
            try db.execute(
                sql: ReorganizationJournalSQL.insertDirectorySQL,
                arguments: [
                    component.componentKey.rawValue,
                    directory.relativePath.rawValue,
                    directory.phase.rawValue,
                ]
            )
        }
    }

    static func deleteActiveReorganizationComponent(
        key: ReorganizationComponentKey,
        db: Database
    ) throws {
        try db.execute(
            sql: ReorganizationJournalSQL.deleteComponentSQL,
            arguments: [key.rawValue]
        )
    }

    static func fetchAllActiveReorganizationComponents(db: Database) throws -> [ActiveReorganizationComponent] {
        let rows = try Row.fetchAll(
            db,
            sql: ReorganizationJournalSQL.componentsSQL
        )
        return try rows.compactMap { try activeReorganizationComponent(from: $0, db: db) }
    }

    static func fetchActiveReorganizationComponent(
        key: ReorganizationComponentKey,
        db: Database
    ) throws -> ActiveReorganizationComponent? {
        guard let row = try Row.fetchOne(
            db,
            sql: ReorganizationJournalSQL.componentSQL,
            arguments: [key.rawValue]
        ) else {
            return nil
        }
        return try activeReorganizationComponent(from: row, db: db)
    }

    static func updateComponentPhase(
        key: ReorganizationComponentKey,
        phase: ActiveReorganizationComponentPhase,
        nextStepIndex: Int,
        updatedAt: Date,
        db: Database
    ) throws {
        try db.execute(
            sql: ReorganizationJournalSQL.setComponentPhaseSQL,
            arguments: [phase.rawValue, nextStepIndex, updatedAt.timeIntervalSince1970, key.rawValue]
        )
    }

    static func updateStepPhase(
        key: ReorganizationComponentKey,
        stepIndex: Int,
        phase: ActiveReorganizationStepPhase,
        db: Database
    ) throws {
        try db.execute(
            sql: ReorganizationJournalSQL.setStepPhaseSQL,
            arguments: [phase.rawValue, key.rawValue, stepIndex]
        )
    }

    static func updateMemberCurrentPath(
        key: ReorganizationComponentKey,
        memberIndex: Int,
        currentRelativePath: MediaRelativePath,
        db: Database
    ) throws {
        try db.execute(
            sql: ReorganizationJournalSQL.setMemberPathSQL,
            arguments: [currentRelativePath.rawValue, key.rawValue, memberIndex]
        )
    }

    static func updateDirectoryPhase(
        key: ReorganizationComponentKey,
        relativePath: MediaRelativePath,
        phase: ActiveReorganizationDirectoryPhase,
        db: Database
    ) throws {
        try db.execute(
            sql: ReorganizationJournalSQL.setDirectoryPhaseSQL,
            arguments: [phase.rawValue, key.rawValue, relativePath.rawValue]
        )
    }

    /// Set-based identity remap (ARC-051). Private intermediate keys never publish.
    /// The remaps are the component's own media members, logical source to final path;
    /// they are recorded as a pending batch in this transaction (ARC-052) and the
    /// component's journal is deleted with it.
    static func settleRelocationComponent(
        rootRowID: Int64,
        component: ActiveReorganizationComponent,
        db: Database
    ) throws -> CatalogIdentityRemapBatch {
        guard component.phase == .filesystemComplete else {
            throw CatalogStoreError.catalogUnavailable
        }
        let libraryRootPath = component.libraryRootPath
        let remaps = identityRemaps(for: component)
        // Every path this settlement writes takes its name key with it (ARC-056), so a row
        // is never found by the key of a path it has left.
        let capabilities = try storedCapabilities(rootRowID: rootRowID, db: db)

        let privatePrefix = ".otos-reorg-tx/\(component.componentKey.rawValue)"
        for (index, remap) in remaps.enumerated() {
            let privatePath = MediaRelativePath(rawValue: "\(privatePrefix)/\(index)")
            try remapMediaAssetPath(
                rootRowID: rootRowID,
                from: remap.oldID.relativePath,
                to: privatePath,
                capabilities: capabilities,
                recomputeDerived: false,
                db: db
            )
        }
        for (index, remap) in remaps.enumerated() {
            let privatePath = MediaRelativePath(rawValue: "\(privatePrefix)/\(index)")
            try remapMediaAssetPath(
                rootRowID: rootRowID,
                from: privatePath,
                to: remap.newID.relativePath,
                capabilities: capabilities,
                recomputeDerived: true,
                db: db
            )
        }

        // Companion relative_path swaps need the same private-key hop as media_asset.
        try remapCompanionPathsForSettlement(
            rootRowID: rootRowID,
            privatePrefix: privatePrefix,
            companions: component.members.filter { $0.kind == .companion },
            remaps: remaps,
            capabilities: capabilities,
            db: db
        )

        try deleteActiveReorganizationComponent(key: component.componentKey, db: db)
        return try insertPendingIdentityRemapBatch(libraryRootPath: libraryRootPath, remaps: remaps, db: db)
    }

    /// Each media member's move, from the path the catalog knows it by to its final path.
    static func identityRemaps(for component: ActiveReorganizationComponent) -> [CatalogIdentityRemap] {
        component.members.compactMap { member in
            guard member.kind == .media else { return nil }
            return CatalogIdentityRemap(
                oldID: MediaAssetID(
                    libraryRootPath: component.libraryRootPath,
                    relativePath: member.logicalSourceRelativePath
                ),
                newID: MediaAssetID(
                    libraryRootPath: component.libraryRootPath,
                    relativePath: member.finalRelativePath
                )
            )
        }
    }

    private static func insertPendingIdentityRemapBatch(
        libraryRootPath: LibraryRootPath,
        remaps: [CatalogIdentityRemap],
        db: Database
    ) throws -> CatalogIdentityRemapBatch {
        try db.execute(
            sql: ReorganizationJournalSQL.insertRemapBatchSQL,
            arguments: [libraryRootPath.rawValue]
        )
        let batchID = db.lastInsertedRowID
        for (ordinal, remap) in remaps.enumerated() {
            try db.execute(
                sql: ReorganizationJournalSQL.insertRemapSQL,
                arguments: [batchID, ordinal, remap.oldID.relativePath.rawValue, remap.newID.relativePath.rawValue]
            )
        }
        return CatalogIdentityRemapBatch(id: batchID, libraryRootPath: libraryRootPath, remaps: remaps)
    }

    /// Every batch the window has not acknowledged, oldest first. Read inside the same
    /// transaction as the window's ordered IDs.
    static func fetchPendingIdentityRemapBatches(db: Database) throws -> [CatalogIdentityRemapBatch] {
        let batchRows = try Row.fetchAll(
            db,
            sql: ReorganizationJournalSQL.remapBatchesSQL
        )
        guard !batchRows.isEmpty else { return [] }
        let remapRows = try Row.fetchAll(
            db,
            sql: ReorganizationJournalSQL.remapsSQL
        )
        var remapsByBatch: [Int64: [(old: String, new: String)]] = [:]
        for row in remapRows {
            remapsByBatch[row["batch_id"], default: []].append((row["old_relative_path"], row["new_relative_path"]))
        }
        return batchRows.map { row in
            let id: Int64 = row["id"]
            let root = LibraryRootPath(rawValue: row["library_root_path"])
            return CatalogIdentityRemapBatch(
                id: id,
                libraryRootPath: root,
                remaps: (remapsByBatch[id] ?? []).map { pair in
                    CatalogIdentityRemap(
                        oldID: MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: pair.old)),
                        newID: MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: pair.new))
                    )
                }
            )
        }
    }

    /// Deletes acknowledged batches. Idempotent: a batch already gone is acknowledged.
    static func deletePendingIdentityRemapBatches(ids: [Int64], db: Database) throws {
        guard !ids.isEmpty else { return }
        try db.execute(
            sql: ReorganizationJournalSQL.deleteRemapBatchesSQL(count: ids.count),
            arguments: StatementArguments(ids)
        )
    }

    static func deleteAllPendingIdentityRemapBatches(db: Database) throws {
        try db.execute(sql: ReorganizationJournalSQL.deleteAllRemapBatchesSQL)
    }

    private static func remapCompanionPathsForSettlement(
        rootRowID: Int64,
        privatePrefix: String,
        companions: [ActiveReorganizationMember],
        remaps: [CatalogIdentityRemap],
        capabilities: VolumeNamespaceCapabilities,
        db: Database
    ) throws {
        for (index, member) in companions.enumerated() {
            let privatePath = MediaRelativePath(rawValue: "\(privatePrefix)/companion/\(index)")
            try db.execute(
                sql: MediaCompanionSQL.remapCompanionPathSQL,
                arguments: [
                    privatePath.rawValue,
                    FilesystemNamespaceSemantics.nameKey(relativePath: privatePath, capabilities: capabilities).rawValue,
                ]
                    + AssetKey(rootID: rootRowID, path: member.logicalSourceRelativePath).arguments
            )
        }
        for (index, member) in companions.enumerated() {
            let privatePath = MediaRelativePath(rawValue: "\(privatePrefix)/companion/\(index)")
            try db.execute(
                sql: MediaCompanionSQL.remapCompanionPathSQL,
                arguments: [member.finalRelativePath.rawValue, FilesystemNamespaceSemantics.nameKey(
                    relativePath: member.finalRelativePath,
                    capabilities: capabilities
                ).rawValue] + AssetKey(rootID: rootRowID, path: privatePath).arguments
            )
        }
        for (index, remap) in remaps.enumerated() {
            let privatePrimary = MediaRelativePath(rawValue: "\(privatePrefix)/primary/\(index)")
            try db.execute(
                sql: MediaCompanionSQL.remapPrimaryPathSQL,
                arguments: [
                    privatePrimary.rawValue,
                    rootRowID,
                    remap.oldID.relativePath.rawValue,
                ]
            )
        }
        for (index, remap) in remaps.enumerated() {
            let privatePrimary = MediaRelativePath(rawValue: "\(privatePrefix)/primary/\(index)")
            try db.execute(
                sql: MediaCompanionSQL.remapPrimaryPathSQL,
                arguments: [
                    remap.newID.relativePath.rawValue,
                    rootRowID,
                    privatePrimary.rawValue,
                ]
            )
        }
    }

    private static func remapMediaAssetPath(
        rootRowID: Int64,
        from: MediaRelativePath,
        to: MediaRelativePath,
        capabilities: VolumeNamespaceCapabilities,
        recomputeDerived: Bool,
        db: Database
    ) throws {
        let key = FilesystemNamespaceSemantics.nameKey(relativePath: to, capabilities: capabilities).rawValue
        if recomputeDerived {
            let name = to.rawValue.split(separator: "/").last.map(String.init) ?? to.rawValue
            try db.execute(
                sql: AssetRowSQL.remapAssetPathRenamingSQL,
                arguments: [to.rawValue, key, MediaSortKey.naturalKey(name), name]
                    + AssetKey(rootID: rootRowID, path: from).arguments
            )
        } else {
            try db.execute(
                sql: AssetRowSQL.remapAssetPathSQL,
                arguments: [to.rawValue, key] + AssetKey(rootID: rootRowID, path: from).arguments
            )
        }
    }

    private static func activeReorganizationComponent(
        from row: Row,
        db: Database
    ) throws -> ActiveReorganizationComponent? {
        guard let phase = ActiveReorganizationComponentPhase(rawValue: row["phase"]) else {
            return nil
        }
        let key = ReorganizationComponentKey(rawValue: row["component_key"])
        let members = try Row.fetchAll(
            db,
            sql: ReorganizationJournalSQL.membersSQL,
            arguments: [key.rawValue]
        ).compactMap(activeReorganizationMember(from:))
        let steps = try Row.fetchAll(
            db,
            sql: ReorganizationJournalSQL.stepsSQL,
            arguments: [key.rawValue]
        ).compactMap(activeReorganizationStep(from:))
        let directories = try Row.fetchAll(
            db,
            sql: ReorganizationJournalSQL.directoriesSQL,
            arguments: [key.rawValue]
        ).compactMap(activeReorganizationDirectory(from:))
        let created: Double = row["created_at"]
        let updated: Double = row["updated_at"]
        let planGeneration: Int64 = row["plan_generation"]
        let plannedRevision: Int64 = row["planned_root_revision"]
        return ActiveReorganizationComponent(
            componentKey: key,
            libraryRootPath: LibraryRootPath(rawValue: row["library_root_path"]),
            planGeneration: UInt64(planGeneration),
            plannedRootRevision: UInt64(plannedRevision),
            phase: phase,
            nextStepIndex: row["next_step_index"],
            createdAt: Date(timeIntervalSince1970: created),
            updatedAt: Date(timeIntervalSince1970: updated),
            members: members,
            steps: steps,
            directories: directories
        )
    }

    private static func activeReorganizationMember(from row: Row) -> ActiveReorganizationMember? {
        guard let kind = ActiveReorganizationMemberKind(rawValue: row["member_kind"]) else {
            return nil
        }
        let modified: Double = row["content_modified_at"]
        return ActiveReorganizationMember(
            memberIndex: row["member_index"],
            kind: kind,
            logicalSourceRelativePath: MediaRelativePath(rawValue: row["logical_source_relative_path"]),
            currentRelativePath: MediaRelativePath(rawValue: row["current_relative_path"]),
            finalRelativePath: MediaRelativePath(rawValue: row["final_relative_path"]),
            byteSize: row["byte_size"],
            contentModifiedAt: Date(timeIntervalSince1970: modified)
        )
    }

    private static func activeReorganizationStep(from row: Row) -> ActiveReorganizationStep? {
        guard let phase = ActiveReorganizationStepPhase(rawValue: row["phase"]) else {
            return nil
        }
        return ActiveReorganizationStep(
            stepIndex: row["step_index"],
            memberIndex: row["member_index"],
            sourceRelativePath: MediaRelativePath(rawValue: row["source_relative_path"]),
            destinationRelativePath: MediaRelativePath(rawValue: row["destination_relative_path"]),
            phase: phase
        )
    }

    private static func activeReorganizationDirectory(from row: Row) -> ActiveReorganizationDirectory? {
        guard let phase = ActiveReorganizationDirectoryPhase(rawValue: row["phase"]) else {
            return nil
        }
        return ActiveReorganizationDirectory(
            relativePath: MediaRelativePath(rawValue: row["relative_path"]),
            phase: phase
        )
    }
}

/// Reorganization journal SQL guide (ADR 0002)
///
/// The statements of the reorganization journal: `active_reorganization_component` and its
/// members, steps and directories, which let an interrupted reorganization resume or roll back,
/// and `pending_identity_remap`, the path changes a settled reorganization owes the rest of the
/// app. The rows it moves are `AssetRowSQL`'s and `MediaCompanionSQL`'s. `CatalogStore` owns
/// when each runs; this enum owns only the text.
nonisolated enum ReorganizationJournalSQL {
    static let insertComponentSQL = """
    INSERT INTO active_reorganization_component (
        component_key, library_root_path, plan_generation, planned_root_revision,
        phase, next_step_index, created_at, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    """

    static let insertMemberSQL = """
    INSERT INTO active_reorganization_member (
        component_key, member_index, member_kind,
        logical_source_relative_path, current_relative_path, final_relative_path,
        byte_size, content_modified_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    """

    static let insertStepSQL = """
    INSERT INTO active_reorganization_step (
        component_key, step_index, member_index,
        source_relative_path, destination_relative_path, phase
    ) VALUES (?, ?, ?, ?, ?, ?)
    """

    static let insertDirectorySQL = """
    INSERT INTO active_reorganization_directory (
        component_key, relative_path, phase
    ) VALUES (?, ?, ?)
    """

    static let deleteComponentSQL = "DELETE FROM active_reorganization_component WHERE component_key = ?"

    static let componentsSQL = "SELECT * FROM active_reorganization_component ORDER BY created_at"

    static let componentSQL = "SELECT * FROM active_reorganization_component WHERE component_key = ?"

    static let setComponentPhaseSQL = """
    UPDATE active_reorganization_component
    SET phase = ?, next_step_index = ?, updated_at = ?
    WHERE component_key = ?
    """

    static let setStepPhaseSQL = """
    UPDATE active_reorganization_step
    SET phase = ?
    WHERE component_key = ? AND step_index = ?
    """

    static let setMemberPathSQL = """
    UPDATE active_reorganization_member
    SET current_relative_path = ?
    WHERE component_key = ? AND member_index = ?
    """

    static let setDirectoryPhaseSQL = """
    UPDATE active_reorganization_directory
    SET phase = ?
    WHERE component_key = ? AND relative_path = ?
    """

    static let insertRemapBatchSQL = "INSERT INTO pending_identity_remap_batch (library_root_path) VALUES (?)"

    static let insertRemapSQL = """
    INSERT INTO pending_identity_remap (batch_id, ordinal, old_relative_path, new_relative_path)
    VALUES (?, ?, ?, ?)
    """

    static let remapBatchesSQL = "SELECT id, library_root_path FROM pending_identity_remap_batch ORDER BY id"

    static let remapsSQL = """
    SELECT batch_id, old_relative_path, new_relative_path
    FROM pending_identity_remap
    ORDER BY batch_id, ordinal
    """

    static let deleteAllRemapBatchesSQL = "DELETE FROM pending_identity_remap_batch"

    static let membersSQL = """
    SELECT * FROM active_reorganization_member
    WHERE component_key = ?
    ORDER BY member_index
    """

    static let stepsSQL = """
    SELECT * FROM active_reorganization_step
    WHERE component_key = ?
    ORDER BY step_index
    """

    static let directoriesSQL = """
    SELECT * FROM active_reorganization_directory
    WHERE component_key = ?
    ORDER BY relative_path
    """

    /// Deletes `count` remap batches by id (bound).
    static func deleteRemapBatchesSQL(count: Int) -> String {
        "DELETE FROM pending_identity_remap_batch WHERE id IN (\(Array(repeating: "?", count: count).joined(separator: ",")))"
    }
}
