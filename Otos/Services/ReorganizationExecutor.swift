import Foundation
import OSLog

/// Same-volume reorganization executor (ARC-051).
///
/// Persists the component recipe before the first move, executes ordered
/// no-overwrite steps, and marks `.filesystemComplete` for Store settlement.
/// Cancellation is honored only between components (caller stops scheduling).
nonisolated enum ReorganizationExecutor {
    /// Builds a durable journal component from a planner component + snapshot facts.
    static func makeJournalComponent(
        plan: ReorganizationPlan,
        plannerComponent: ReorganizationComponent,
        snapshot: ReorganizationPlanningSnapshot,
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

    /// Executes remaining steps for a journaled component. Store APIs are injected.
    static func executeComponent(
        component: ActiveReorganizationComponent,
        rootURL: URL,
        markWillMove: (ActiveReorganizationStep) async throws -> Void,
        markDidMove: (ActiveReorganizationStep, MediaRelativePath) async throws -> Void,
        markFilesystemComplete: () async throws -> Void,
        shouldContinue: () -> Bool
    ) async -> ReorganizationExecutionOutcome {
        var working = component
        for directory in working.directories where directory.phase == .planned {
            do {
                try ensureDirectory(rootURL: rootURL, relativePath: directory.relativePath)
            } catch {
                return .failed(reason: "directoryPrerequisite")
            }
        }

        while working.nextStepIndex < working.steps.count {
            guard shouldContinue() else {
                return .cancelled
            }
            let step = working.steps[working.nextStepIndex]
            if step.phase == .didMove {
                working.nextStepIndex += 1
                continue
            }
            let member = working.members.first { $0.memberIndex == step.memberIndex }
            guard let member else {
                return .failed(reason: "missingMember")
            }

            let observation = observeStep(
                rootURL: rootURL,
                step: step,
                expectedByteSize: member.byteSize,
                expectedModifiedAt: member.contentModifiedAt
            )
            switch observation {
            case .moveHappened:
                do {
                    try await markDidMove(step, step.destinationRelativePath)
                    working.nextStepIndex += 1
                } catch {
                    return .failed(reason: "markDidMove")
                }
                continue
            case .ambiguousBothExist, .ambiguousNeitherExists:
                return .blocked(reason: "ambiguousRecovery")
            case .moveDidNotHappen:
                break
            }

            do {
                try await markWillMove(step)
            } catch {
                return .failed(reason: "markWillMove")
            }

            let sourceURL = rootURL.appending(path: step.sourceRelativePath.rawValue)
            let destinationURL = rootURL.appending(path: step.destinationRelativePath.rawValue)
            let parent = destinationURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

            let outcome = ExclusivePublication.publish(staging: sourceURL, final: destinationURL)
            switch outcome {
            case .published:
                do {
                    try await markDidMove(step, step.destinationRelativePath)
                    working.nextStepIndex += 1
                } catch {
                    return .failed(reason: "markDidMoveAfterPublish")
                }
            case .destinationExists:
                return .blocked(reason: "destinationExists")
            case let .failed(reason):
                return .failed(reason: reason)
            }
        }

        do {
            try await markFilesystemComplete()
            return .filesystemComplete(component.componentKey)
        } catch {
            return .failed(reason: "markFilesystemComplete")
        }
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

    private static func ensureDirectory(rootURL: URL, relativePath: MediaRelativePath) throws {
        let url = rootURL.appending(path: relativePath.rawValue, directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CocoaError(.fileWriteFileExists)
            }
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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
