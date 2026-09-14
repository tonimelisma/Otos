import Foundation

/// One entry of the Open With submenu: an app bundle and the name the menu shows.
nonisolated struct OpenWithApplication: Hashable, Sendable, Identifiable {
    let url: URL
    let displayName: String

    var id: URL {
        url
    }
}

/// Open With menu model guide
///
/// The pure answer to "what can open the current targets": computed once per target
/// change off the MainActor, rendered by the File menu without touching LaunchServices
/// during layout. Targets are grouped by file extension so a five-hundred-item
/// selection costs one LaunchServices query per distinct type, not per file.
///
/// `defaultApplication` is set only when every target group agrees; a mixed selection
/// (an image and a video) titles the command plain `Open` and each group opens in its
/// own default, which is what Finder's ⌘O does. `applications` is the intersection of
/// every group's list in the best-first order of the first group, so nothing offered
/// can refuse part of the selection.
nonisolated struct OpenWithMenuModel: Equatable, Sendable {
    /// The app shared by every target as its default, or nil when they disagree or
    /// there are no targets.
    var defaultApplication: OpenWithApplication?
    /// Best-first apps able to open every target.
    var applications: [OpenWithApplication]
    /// Each target with the default app that opens it; targets with no registered
    /// default are absent and are reported by count in `targetsWithoutDefault`.
    var defaultsByTarget: [URL: URL]
    var targetCount: Int
    var targetsWithoutDefault: Int

    static let empty = OpenWithMenuModel(
        defaultApplication: nil,
        applications: [],
        defaultsByTarget: [:],
        targetCount: 0,
        targetsWithoutDefault: 0
    )

    var canOpen: Bool {
        targetCount > 0 && !defaultsByTarget.isEmpty
    }

    var canOpenWith: Bool {
        targetCount > 0
    }

    /// `Open in Preview` when one default serves every target, otherwise `Open`.
    var openTitle: String {
        if let defaultApplication {
            return "Open in \(defaultApplication.displayName)"
        }
        return "Open"
    }

    /// Targets grouped by the default app that opens them, in first-seen app order.
    func targetsByDefaultApplication(order targets: [URL]) -> [(application: URL, targets: [URL])] {
        var groups: [(application: URL, targets: [URL])] = []
        var indexByApplication: [URL: Int] = [:]
        for target in targets {
            guard let application = defaultsByTarget[target] else { continue }
            if let index = indexByApplication[application] {
                groups[index].targets.append(target)
            } else {
                indexByApplication[application] = groups.count
                groups.append((application, [target]))
            }
        }
        return groups
    }

    static func make(targets: [URL], workspace: any WorkspaceOpening) -> OpenWithMenuModel {
        guard !targets.isEmpty else { return .empty }

        // One query per distinct extension; the first URL of each group represents it.
        var representativeByExtension: [String: URL] = [:]
        var extensionOrder: [String] = []
        for target in targets {
            let key = target.pathExtension.lowercased()
            if representativeByExtension[key] == nil {
                representativeByExtension[key] = target
                extensionOrder.append(key)
            }
        }

        var defaultByExtension: [String: URL] = [:]
        var applicationLists: [[URL]] = []
        for key in extensionOrder {
            guard let representative = representativeByExtension[key] else { continue }
            if let defaultURL = workspace.defaultApplicationURL(toOpen: representative) {
                defaultByExtension[key] = defaultURL
            }
            applicationLists.append(workspace.applicationURLs(toOpen: representative))
        }

        var defaultsByTarget: [URL: URL] = [:]
        var withoutDefault = 0
        for target in targets {
            if let defaultURL = defaultByExtension[target.pathExtension.lowercased()] {
                defaultsByTarget[target] = defaultURL
            } else {
                withoutDefault += 1
            }
        }

        let distinctDefaults = Set(defaultByExtension.values)
        let sharedDefault: OpenWithApplication? =
            if withoutDefault == 0, distinctDefaults.count == 1, let url = distinctDefaults.first {
                OpenWithApplication(url: url, displayName: workspace.displayName(forApplicationAt: url))
            } else {
                nil
            }

        let intersection: [URL] = applicationLists.dropFirst().reduce(applicationLists.first ?? []) { current, next in
            let allowed = Set(next)
            return current.filter { allowed.contains($0) }
        }
        let applications = intersection.map { url in
            OpenWithApplication(url: url, displayName: workspace.displayName(forApplicationAt: url))
        }

        return OpenWithMenuModel(
            defaultApplication: sharedDefault,
            applications: applications,
            defaultsByTarget: defaultsByTarget,
            targetCount: targets.count,
            targetsWithoutDefault: withoutDefault
        )
    }
}
