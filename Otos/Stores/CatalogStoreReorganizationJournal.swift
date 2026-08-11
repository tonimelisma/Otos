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
            sql: """
            INSERT INTO active_reorganization_component (
                component_key, library_root_path, plan_generation, planned_root_revision,
                phase, next_step_index, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
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
                sql: """
                INSERT INTO active_reorganization_member (
                    component_key, member_index, member_kind,
                    logical_source_relative_path, current_relative_path, final_relative_path,
                    byte_size, content_modified_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
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
                sql: """
                INSERT INTO active_reorganization_step (
                    component_key, step_index, member_index,
                    source_relative_path, destination_relative_path, phase
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
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
                sql: """
                INSERT INTO active_reorganization_directory (
                    component_key, relative_path, phase
                ) VALUES (?, ?, ?)
                """,
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
            sql: "DELETE FROM active_reorganization_component WHERE component_key = ?",
            arguments: [key.rawValue]
        )
    }

    static func fetchAllActiveReorganizationComponents(db: Database) throws -> [ActiveReorganizationComponent] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM active_reorganization_component ORDER BY created_at"
        )
        return try rows.compactMap { try activeReorganizationComponent(from: $0, db: db) }
    }

    static func fetchActiveReorganizationComponent(
        key: ReorganizationComponentKey,
        db: Database
    ) throws -> ActiveReorganizationComponent? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM active_reorganization_component WHERE component_key = ?",
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
            sql: """
            UPDATE active_reorganization_component
            SET phase = ?, next_step_index = ?, updated_at = ?
            WHERE component_key = ?
            """,
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
            sql: """
            UPDATE active_reorganization_step
            SET phase = ?
            WHERE component_key = ? AND step_index = ?
            """,
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
            sql: """
            UPDATE active_reorganization_member
            SET current_relative_path = ?
            WHERE component_key = ? AND member_index = ?
            """,
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
            sql: """
            UPDATE active_reorganization_directory
            SET phase = ?
            WHERE component_key = ? AND relative_path = ?
            """,
            arguments: [phase.rawValue, key.rawValue, relativePath.rawValue]
        )
    }

    /// Set-based identity remap (ARC-051). Private intermediate keys never publish.
    static func settleRelocationComponent(
        rootRowID: Int64,
        libraryRootPath: LibraryRootPath,
        component: ActiveReorganizationComponent,
        remaps: [CatalogIdentityRemap],
        db: Database
    ) throws -> CatalogIdentityRemapBatch {
        guard component.phase == .filesystemComplete else {
            throw CatalogStoreError.catalogUnavailable
        }
        let mediaMembers = component.members.filter { $0.kind == .media }
        guard remaps.count == mediaMembers.count else {
            throw CatalogStoreError.catalogUnavailable
        }

        let privatePrefix = ".otos-reorg-tx/\(component.componentKey.rawValue)"
        for (index, remap) in remaps.enumerated() {
            let privatePath = MediaRelativePath(rawValue: "\(privatePrefix)/\(index)")
            try remapMediaAssetPath(
                rootRowID: rootRowID,
                libraryRootPath: libraryRootPath,
                from: remap.oldID.relativePath,
                to: privatePath,
                recomputeDerived: false,
                db: db
            )
        }
        for (index, remap) in remaps.enumerated() {
            let privatePath = MediaRelativePath(rawValue: "\(privatePrefix)/\(index)")
            try remapMediaAssetPath(
                rootRowID: rootRowID,
                libraryRootPath: libraryRootPath,
                from: privatePath,
                to: remap.newID.relativePath,
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
            db: db
        )

        try updateComponentPhase(
            key: component.componentKey,
            phase: .catalogCommitted,
            nextStepIndex: component.nextStepIndex,
            updatedAt: Date(),
            db: db
        )
        try deleteActiveReorganizationComponent(key: component.componentKey, db: db)

        return CatalogIdentityRemapBatch(
            libraryRootPath: libraryRootPath,
            remaps: remaps,
            rootRevision: 0
        )
    }

    private static func remapCompanionPathsForSettlement(
        rootRowID: Int64,
        privatePrefix: String,
        companions: [ActiveReorganizationMember],
        remaps: [CatalogIdentityRemap],
        db: Database
    ) throws {
        for (index, member) in companions.enumerated() {
            let privatePath = MediaRelativePath(rawValue: "\(privatePrefix)/companion/\(index)")
            try db.execute(
                sql: """
                UPDATE media_companion
                SET relative_path = ?
                WHERE library_root_id = ? AND relative_path = ?
                """,
                arguments: [
                    privatePath.rawValue,
                    rootRowID,
                    member.logicalSourceRelativePath.rawValue,
                ]
            )
        }
        for (index, member) in companions.enumerated() {
            let privatePath = MediaRelativePath(rawValue: "\(privatePrefix)/companion/\(index)")
            try db.execute(
                sql: """
                UPDATE media_companion
                SET relative_path = ?
                WHERE library_root_id = ? AND relative_path = ?
                """,
                arguments: [
                    member.finalRelativePath.rawValue,
                    rootRowID,
                    privatePath.rawValue,
                ]
            )
        }
        for (index, remap) in remaps.enumerated() {
            let privatePrimary = MediaRelativePath(rawValue: "\(privatePrefix)/primary/\(index)")
            try db.execute(
                sql: """
                UPDATE media_companion
                SET primary_relative_path = ?
                WHERE library_root_id = ?
                  AND primary_relative_path = ?
                """,
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
                sql: """
                UPDATE media_companion
                SET primary_relative_path = ?
                WHERE library_root_id = ?
                  AND primary_relative_path = ?
                """,
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
        libraryRootPath: LibraryRootPath,
        from: MediaRelativePath,
        to: MediaRelativePath,
        recomputeDerived: Bool,
        db: Database
    ) throws {
        if recomputeDerived {
            let name = to.rawValue.split(separator: "/").last.map(String.init) ?? to.rawValue
            try db.execute(
                sql: """
                UPDATE media_asset
                SET relative_path = ?,
                    sort_key = ?,
                    name_sort_key = ?,
                    name = ?
                WHERE library_root_id = ? AND relative_path = ?
                """,
                arguments: [
                    to.rawValue,
                    MediaSortKey.make(libraryRootPath: libraryRootPath, relativePath: to),
                    MediaSortKey.naturalKey(name),
                    name,
                    rootRowID,
                    from.rawValue,
                ]
            )
        } else {
            try db.execute(
                sql: """
                UPDATE media_asset
                SET relative_path = ?
                WHERE library_root_id = ? AND relative_path = ?
                """,
                arguments: [to.rawValue, rootRowID, from.rawValue]
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
            sql: """
            SELECT * FROM active_reorganization_member
            WHERE component_key = ?
            ORDER BY member_index
            """,
            arguments: [key.rawValue]
        ).compactMap(activeReorganizationMember(from:))
        let steps = try Row.fetchAll(
            db,
            sql: """
            SELECT * FROM active_reorganization_step
            WHERE component_key = ?
            ORDER BY step_index
            """,
            arguments: [key.rawValue]
        ).compactMap(activeReorganizationStep(from:))
        let directories = try Row.fetchAll(
            db,
            sql: """
            SELECT * FROM active_reorganization_directory
            WHERE component_key = ?
            ORDER BY relative_path
            """,
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
