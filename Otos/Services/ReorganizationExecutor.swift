import Foundation
import OSLog

/// Same-volume reorganization executor (ARC-051).
///
/// Persists the component recipe before the first move, executes ordered
/// no-overwrite steps, and marks `.filesystemComplete` for Store settlement. A component
/// that cannot finish is rolled back: its completed steps are reversed and the folders
/// it created removed, so a component either happens whole or leaves the library as it
/// was. Every transition goes through `CatalogStore`'s journal before and after the
/// filesystem change it describes, which is what makes crash recovery a resume.
nonisolated enum ReorganizationExecutor {
    /// Builds a durable journal component from a planner component + snapshot facts.
    static func makeJournalComponent(
        plan: ReorganizationPlan,
        plannerComponent: ReorganizationComponent,
        factsByPath: [MediaRelativePath: (byteSize: Int64, contentModifiedAt: Date)]
    ) -> ActiveReorganizationComponent? {
        let key = ReorganizationComponentKey.make()
        var members: [ActiveReorganizationMember] = []
        var memberIndexByID: [String: Int] = [:]
        for (index, memberID) in plannerComponent.memberIDs.enumerated() {
            guard let physical = plan.members.first(where: { $0.id == memberID }) else {
                return nil
            }
            guard let facts = factsByPath[physical.source] else {
                return nil
            }
            memberIndexByID[memberID] = index
            members.append(
                ActiveReorganizationMember(
                    memberIndex: index,
                    kind: physical.isCompanion ? .companion : .media,
                    logicalSourceRelativePath: physical.source,
                    currentRelativePath: physical.source,
                    finalRelativePath: physical.finalDestination,
                    byteSize: facts.byteSize,
                    contentModifiedAt: facts.contentModifiedAt
                )
            )
        }

        // Map steps from the member that currently occupies `from`, updating as steps emit.
        // Matching `finalRelativePath` would mis-bind chain steps (A→B binds to A when looking up B).
        var memberIndexByCurrentPath: [String: Int] = [:]
        for member in members {
            memberIndexByCurrentPath[member.currentRelativePath.rawValue] = member.memberIndex
        }

        var steps: [ActiveReorganizationStep] = []
        var stepIndex = 0
        for move in plannerComponent.steps {
            switch move {
            case let .move(from, to):
                guard let memberIndex = memberIndexByCurrentPath[from.rawValue] else {
                    return nil
                }
                steps.append(
                    ActiveReorganizationStep(
                        stepIndex: stepIndex,
                        memberIndex: memberIndex,
                        sourceRelativePath: from,
                        destinationRelativePath: to,
                        phase: .planned
                    )
                )
                stepIndex += 1
                memberIndexByCurrentPath.removeValue(forKey: from.rawValue)
                memberIndexByCurrentPath[to.rawValue] = memberIndex
            case let .moveViaTemporary(from, temporary, to):
                guard let memberIndex = memberIndexByCurrentPath[from.rawValue] else {
                    return nil
                }
                steps.append(
                    ActiveReorganizationStep(
                        stepIndex: stepIndex,
                        memberIndex: memberIndex,
                        sourceRelativePath: from,
                        destinationRelativePath: temporary,
                        phase: .planned
                    )
                )
                stepIndex += 1
                memberIndexByCurrentPath.removeValue(forKey: from.rawValue)
                memberIndexByCurrentPath[temporary.rawValue] = memberIndex
                steps.append(
                    ActiveReorganizationStep(
                        stepIndex: stepIndex,
                        memberIndex: memberIndex,
                        sourceRelativePath: temporary,
                        destinationRelativePath: to,
                        phase: .planned
                    )
                )
                stepIndex += 1
                memberIndexByCurrentPath.removeValue(forKey: temporary.rawValue)
                memberIndexByCurrentPath[to.rawValue] = memberIndex
            }
        }

        let directories = directoryPrerequisites(for: members).map {
            ActiveReorganizationDirectory(relativePath: $0, phase: .planned)
        }
        let now = Date()
        return ActiveReorganizationComponent(
            componentKey: key,
            libraryRootPath: plan.libraryRoot,
            planGeneration: plan.generation,
            plannedRootRevision: plan.rootRevision,
            phase: .prepared,
            nextStepIndex: 0,
            createdAt: now,
            updatedAt: now,
            members: members,
            steps: steps,
            directories: directories
        )
    }

    static func observeStep(
        rootURL: URL,
        step: ActiveReorganizationStep,
        expectedByteSize: Int64,
        expectedModifiedAt: Date
    ) -> ReorganizationRecoveryObservation {
        let sourceURL = rootURL.appending(path: step.sourceRelativePath.rawValue)
        let destinationURL = rootURL.appending(path: step.destinationRelativePath.rawValue)
        let sourceExists = matchesFacts(
            url: sourceURL,
            byteSize: expectedByteSize,
            modifiedAt: expectedModifiedAt
        )
        let destinationExists = matchesFacts(
            url: destinationURL,
            byteSize: expectedByteSize,
            modifiedAt: expectedModifiedAt
        )
        switch (sourceExists, destinationExists) {
        case (true, false):
            return .moveDidNotHappen
        case (false, true):
            return .moveHappened
        case (true, true):
            return .ambiguousBothExist
        case (false, false):
            return .ambiguousNeitherExists
        }
    }

    /// Moves a journaled component forward from where its journal stands, writing each
    /// transition before and after the filesystem change it describes. Resuming after a
    /// crash takes the same path: a step journaled as `willMove` is observed on disk
    /// first, so a move that happened is recorded rather than repeated.
    static func executeComponent(
        _ component: ActiveReorganizationComponent,
        rootURL: URL,
        store: CatalogStore
    ) async -> ReorganizationExecutionOutcome {
        let key = component.componentKey
        for directory in component.directories where directory.phase == .planned {
            switch ensureDirectory(rootURL: rootURL, relativePath: directory.relativePath) {
            case .preexisting:
                continue
            case .created:
                do {
                    try await store.recordReorganizationDirectoryCreated(key: key, relativePath: directory.relativePath)
                } catch {
                    return stopped(.journalWrite, key: key, error: error)
                }
            case .unavailable:
                return stopped(.folderUnavailable(directory.relativePath), key: key, error: nil)
            }
        }

        var nextStepIndex = component.nextStepIndex
        while nextStepIndex < component.steps.count {
            let step = component.steps[nextStepIndex]
            if step.phase == .didMove {
                nextStepIndex += 1
                continue
            }
            guard let member = component.members.first(where: { $0.memberIndex == step.memberIndex }) else {
                return stopped(.fileChanged(step.sourceRelativePath), key: key, error: nil)
            }
            switch observeStep(
                rootURL: rootURL,
                step: step,
                expectedByteSize: member.byteSize,
                expectedModifiedAt: member.contentModifiedAt
            ) {
            case .moveHappened:
                do {
                    try await store.recordReorganizationMoveCompletion(
                        key: key,
                        step: step,
                        nextStepIndex: nextStepIndex + 1
                    )
                } catch {
                    return stopped(.journalWrite, key: key, error: error)
                }
                nextStepIndex += 1
                continue
            case .ambiguousBothExist:
                return stopped(.destinationTaken(step.destinationRelativePath), key: key, error: nil)
            case .ambiguousNeitherExists:
                return stopped(.fileChanged(step.sourceRelativePath), key: key, error: nil)
            case .moveDidNotHappen:
                break
            }

            do {
                try await store.recordReorganizationMoveIntent(key: key, stepIndex: step.stepIndex)
            } catch {
                return stopped(.journalWrite, key: key, error: error)
            }
            let sourceURL = rootURL.appending(path: step.sourceRelativePath.rawValue)
            let destinationURL = rootURL.appending(path: step.destinationRelativePath.rawValue)
            switch ExclusivePublication.publish(staging: sourceURL, final: destinationURL) {
            case .published:
                do {
                    try await store.recordReorganizationMoveCompletion(
                        key: key,
                        step: step,
                        nextStepIndex: nextStepIndex + 1
                    )
                } catch {
                    return stopped(.journalWrite, key: key, error: error)
                }
                nextStepIndex += 1
            case .destinationExists:
                return stopped(.destinationTaken(step.destinationRelativePath), key: key, error: nil)
            case let .failed(detail):
                OtosLog.catalog.errorOperation("reorganization.execute", phase: "moveRefused", fields: [
                    "key": key.rawValue,
                    "path": step.sourceRelativePath.rawValue,
                    "detail": detail,
                ])
                return stopped(.moveRefused(step.sourceRelativePath), key: key, error: nil)
            }
        }

        do {
            try await store.recordReorganizationFilesystemCompletion(key: key, nextStepIndex: component.steps.count)
            return .filesystemComplete
        } catch {
            return stopped(.journalWrite, key: key, error: error)
        }
    }

    /// Undoes a component that will not finish: every step that moved a file is moved
    /// back, newest first, and every folder the component created is removed once empty,
    /// so the library is as it was before the component. Resuming after a crash takes
    /// the same path; each step is observed on disk before it is reversed.
    static func rollBackComponent(
        _ component: ActiveReorganizationComponent,
        rootURL: URL,
        store: CatalogStore
    ) async -> ReorganizationRollbackOutcome {
        let key = component.componentKey
        if component.phase != .rollingBack {
            do {
                try await store.recordReorganizationRollbackStart(key: key, nextStepIndex: component.nextStepIndex)
            } catch {
                return await stuck(.journalWrite, component: component, store: store, error: error)
            }
        }
        for step in component.steps.reversed() where step.phase == .willMove || step.phase == .didMove {
            guard let member = component.members.first(where: { $0.memberIndex == step.memberIndex }) else {
                return await stuck(.fileChanged(step.sourceRelativePath), component: component, store: store, error: nil)
            }
            // The reverse move: what is at the destination goes back to the source.
            switch observeStep(
                rootURL: rootURL,
                step: step,
                expectedByteSize: member.byteSize,
                expectedModifiedAt: member.contentModifiedAt
            ) {
            case .moveDidNotHappen:
                break
            case .moveHappened:
                let sourceURL = rootURL.appending(path: step.sourceRelativePath.rawValue)
                let destinationURL = rootURL.appending(path: step.destinationRelativePath.rawValue)
                switch ExclusivePublication.publish(staging: destinationURL, final: sourceURL) {
                case .published:
                    break
                case .destinationExists:
                    return await stuck(
                        .destinationTaken(step.sourceRelativePath),
                        component: component,
                        store: store,
                        error: nil
                    )
                case let .failed(detail):
                    OtosLog.catalog.errorOperation("reorganization.rollback", phase: "moveRefused", fields: [
                        "key": key.rawValue,
                        "path": step.destinationRelativePath.rawValue,
                        "detail": detail,
                    ])
                    return await stuck(
                        .moveRefused(step.destinationRelativePath),
                        component: component,
                        store: store,
                        error: nil
                    )
                }
            case .ambiguousBothExist:
                return await stuck(.destinationTaken(step.sourceRelativePath), component: component, store: store, error: nil)
            case .ambiguousNeitherExists:
                return await stuck(.fileChanged(step.destinationRelativePath), component: component, store: store, error: nil)
            }
            do {
                try await store.recordReorganizationStepRolledBack(key: key, step: step)
            } catch {
                return await stuck(.journalWrite, component: component, store: store, error: error)
            }
        }
        for directory in component.directories.reversed() where directory.phase == .created {
            removeIfEmpty(rootURL: rootURL, relativePath: directory.relativePath, key: key)
        }
        do {
            try await store.discardRolledBackReorganizationComponent(key: key)
        } catch {
            return await stuck(.journalWrite, component: component, store: store, error: error)
        }
        OtosLog.catalog.noticeOperation("reorganization.rollback", phase: "restored", fields: ["key": key.rawValue])
        return .restored
    }

    private static func stopped(
        _ fault: ReorganizationFault,
        key: ReorganizationComponentKey,
        error: (any Error)?
    ) -> ReorganizationExecutionOutcome {
        var fields = ["key": key.rawValue, "fault": fault.logCode]
        if let error {
            fields["error"] = String(describing: error)
        }
        OtosLog.catalog.errorOperation("reorganization.execute", phase: "stopped", fields: fields)
        return .stopped(fault)
    }

    private static func stuck(
        _ fault: ReorganizationFault,
        component: ActiveReorganizationComponent,
        store: CatalogStore,
        error: (any Error)?
    ) async -> ReorganizationRollbackOutcome {
        var fields = ["key": component.componentKey.rawValue, "fault": fault.logCode]
        if let error {
            fields["error"] = String(describing: error)
        }
        do {
            try await store.recordReorganizationBlocked(key: component.componentKey)
        } catch {
            fields["blockedWrite"] = String(describing: error)
        }
        OtosLog.catalog.faultOperation("reorganization.rollback", phase: "stuck", fields: fields)
        return .stuck(fault)
    }

    private enum DirectoryResult {
        case preexisting
        case created
        case unavailable
    }

    private static func ensureDirectory(rootURL: URL, relativePath: MediaRelativePath) -> DirectoryResult {
        let url = rootURL.appending(path: relativePath.rawValue, directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? .preexisting : .unavailable
        }
        do {
            // One level at a time: `directoryPrerequisites` lists every ancestor in
            // order, so each created folder is journaled on its own and rollback can
            // remove exactly the ones this component made.
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return .created
        } catch {
            OtosLog.catalog.errorOperation("reorganization.execute", phase: "folderUnavailable", fields: [
                "path": relativePath.rawValue,
                "error": String(describing: error),
            ])
            return .unavailable
        }
    }

    /// `rmdir(2)` removes only an empty folder, so anything placed there since stays.
    private static func removeIfEmpty(rootURL: URL, relativePath: MediaRelativePath, key: ReorganizationComponentKey) {
        let path = rootURL.appending(path: relativePath.rawValue, directoryHint: .isDirectory).path
        guard rmdir(path) != 0 else { return }
        let code = errno
        guard code != ENOTEMPTY, code != ENOENT else { return }
        OtosLog.catalog.errorOperation("reorganization.rollback", phase: "folderKept", fields: [
            "key": key.rawValue,
            "path": relativePath.rawValue,
            "errno": "\(code)",
        ])
    }

    private static func directoryPrerequisites(
        for members: [ActiveReorganizationMember]
    ) -> [MediaRelativePath] {
        var seen = Set<String>()
        var result: [MediaRelativePath] = []
        for member in members {
            let parts = member.finalRelativePath.rawValue.split(separator: "/").map(String.init)
            guard parts.count > 1 else { continue }
            for end in 1 ..< parts.count {
                let ancestor = parts[0 ..< end].joined(separator: "/")
                if seen.insert(ancestor).inserted {
                    result.append(MediaRelativePath(rawValue: ancestor))
                }
            }
        }
        return result.sorted { $0.rawValue.localizedStandardCompare($1.rawValue) == .orderedAscending }
    }

    private static func matchesFacts(url: URL, byteSize: Int64, modifiedAt: Date) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]),
            values.isRegularFile == true,
            let size = values.fileSize,
            Int64(size) == byteSize,
            let modified = values.contentModificationDate
        else {
            return false
        }
        return abs(modified.timeIntervalSince1970 - modifiedAt.timeIntervalSince1970) < 1.0
    }
}
