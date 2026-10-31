import Foundation

nonisolated struct CaptureWallComponents: Equatable, Sendable {
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
    let second: Int

    var dateTimeFileName: String {
        String(format: "%04d%02d%02d_%02d%02d%02d", year, month, day, hour, minute, second)
    }

    var yearMonthFolder: String {
        String(format: "%04d/%02d", year, month)
    }
}

/// Import naming guide
///
/// The one implementation of the import naming policy (ARC-046): which files name
/// together, which date names them, the destination folder and file name, the collision
/// suffix, and a companion's name beside its primary. Import planning uses it to name
/// copies; Reorganize uses it to apply the same policy to a library already in place
/// (ARC-050), so the two can never name one file differently.
nonisolated enum ImportNaming {
    /// Files that name together: one folder, one stem compared case-insensitively — a
    /// RAW and its JPEG, say — and a Live Photo's movie with its still, whatever its stem
    /// (ADR 0041). They share one name date and one collision suffix.
    struct Bundle: Equatable, Sendable {
        let members: [PlanningFileFacts]
        let stem: String
        let directoryKey: String
        /// The latest capture wall time any member has.
        let wallCompact: Int64?
        /// The earliest modification date any member has, used when no member has a
        /// capture wall time.
        let fallbackModifiedAt: Date?

        init(members: [PlanningFileFacts]) {
            self.members = members
            let namedPath = members.first.map { $0.livePhotoStillPath ?? $0.relativePath }
            stem = namedPath.map(MediaCompanionPairing.stem(of:)) ?? ""
            directoryKey = namedPath.map(MediaCompanionPairing.directoryKey(of:)) ?? ""
            wallCompact = members.compactMap(\.captureWallCompact).max()
            fallbackModifiedAt = members.compactMap(\.contentModifiedAt).min()
        }

        /// Whether the policy can name this bundle: a policy that needs a date names a
        /// bundle only when every member has one.
        func isNameable(under policy: ImportPolicy) -> Bool {
            !ImportNaming.needsDate(policy) || members.allSatisfy(\.hasAnyDate)
        }
    }

    /// Groups files into naming bundles, in the order the policy names them: by capture
    /// time under a date-time name, then by natural file order.
    static func bundles(from media: [PlanningFileFacts], policy: ImportPolicy) -> [Bundle] {
        let sorted = media.sorted { left, right in
            if policy.destinationNamePolicy == .captureDateTime {
                let leftKey = left.captureWallCompact ?? Int64.max
                let rightKey = right.captureWallCompact ?? Int64.max
                if leftKey != rightKey {
                    return leftKey < rightKey
                }
                let leftDate = left.contentModifiedAt ?? .distantFuture
                let rightDate = right.contentModifiedAt ?? .distantFuture
                if leftDate != rightDate {
                    return leftDate < rightDate
                }
            }
            let leftNatural = MediaSortKey.naturalKey(left.relativePath.rawValue)
            let rightNatural = MediaSortKey.naturalKey(right.relativePath.rawValue)
            if leftNatural != rightNatural {
                return leftNatural < rightNatural
            }
            return left.relativePath.rawValue < right.relativePath.rawValue
        }
        var groups: [String: [PlanningFileFacts]] = [:]
        var order: [String] = []
        for item in sorted {
            let namedPath = item.livePhotoStillPath ?? item.relativePath
            let key = MediaCompanionPairing.directoryKey(of: namedPath)
                + "\u{1}"
                + MediaCompanionPairing.stem(of: namedPath)
            if groups[key] == nil {
                order.append(key)
            }
            groups[key, default: []].append(item)
        }
        return order.compactMap { key in groups[key].map(Bundle.init(members:)) }
    }

    /// Whether the policy needs a capture date: a dated folder or a date-time name.
    static func needsDate(_ policy: ImportPolicy) -> Bool {
        policy.destinationFolderPolicy == .yearMonth || policy.destinationNamePolicy == .captureDateTime
    }

    /// The date a bundle is named by, or nil when it has none.
    static func timestamp(of bundle: Bundle, calendar: Calendar, timeZone: TimeZone) -> CaptureWallComponents? {
        timestamp(
            wallCompact: bundle.wallCompact,
            fallbackModifiedAt: bundle.fallbackModifiedAt,
            calendar: calendar,
            timeZone: timeZone
        )
    }

    /// The folder a bundle named by `timestamp` goes in, "" at the root.
    static func folder(timestamp: CaptureWallComponents?, policy: ImportPolicy) -> String? {
        switch policy.destinationFolderPolicy {
        case .none:
            ""
        case .yearMonth:
            timestamp?.yearMonthFolder
        }
    }

    /// Where `member` goes under the policy with collision suffix `suffix` (0 for none),
    /// or nil when the policy needs a date that `timestamp` does not supply.
    static func destination(
        for member: PlanningFileFacts,
        timestamp: CaptureWallComponents?,
        policy: ImportPolicy,
        suffix: Int
    ) -> MediaRelativePath? {
        guard let folder = folder(timestamp: timestamp, policy: policy) else { return nil }
        let baseName: String
        switch policy.destinationNamePolicy {
        case .original:
            baseName = member.relativePath.stem
        case .captureDateTime:
            guard let timestamp else { return nil }
            baseName = timestamp.dateTimeFileName
        }
        let ext = destinationExtension(for: member, policy: policy)
        let fileName = baseName + suffixToken(suffix) + (ext.isEmpty ? "" : ".\(ext)")
        return MediaRelativePath(folder: folder, fileName: fileName)
    }

    /// A companion's destination beside its primary's, under the primary's new name.
    /// Original naming keeps the companion's own extension spelling (`IMG_1.XMP` stays
    /// `.XMP`); date-time naming uses the companion's kind (`.xmp`, `.srt`).
    static func companionDestination(
        _ companion: MediaCompanion,
        primaryDestination: MediaRelativePath,
        policy: ImportPolicy
    ) -> MediaRelativePath {
        let ext = switch policy.destinationNamePolicy {
        case .original:
            companion.relativePath.fileExtension
        case .captureDateTime:
            companion.kind.rawValue
        }
        return MediaRelativePath(
            folder: primaryDestination.folder,
            fileName: ext.isEmpty ? primaryDestination.stem : "\(primaryDestination.stem).\(ext)"
        )
    }

    /// "" for no suffix, "_001" for the first.
    static func suffixToken(_ suffix: Int) -> String {
        suffix == 0 ? "" : String(format: "_%03d", suffix)
    }

    static func destinationExtension(for member: PlanningFileFacts, policy: ImportPolicy) -> String {
        switch policy.destinationNamePolicy {
        case .original:
            member.fileExtension
        case .captureDateTime:
            CanonicalMediaExtension.forDateTimeName(
                contentTypeIdentifier: member.contentTypeIdentifier,
                sourceExtension: member.fileExtension
            )
        }
    }

    static func timestamp(
        wallCompact: Int64?,
        fallbackModifiedAt: Date?,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> CaptureWallComponents? {
        if let wallCompact, let components = components(fromCompact: wallCompact) {
            return CaptureWallComponents(
                year: components.year,
                month: components.month,
                day: components.day,
                hour: components.hour,
                minute: components.minute,
                second: components.second
            )
        }
        guard let fallbackModifiedAt else { return nil }
        var localCalendar = calendar
        localCalendar.timeZone = timeZone
        let components = localCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fallbackModifiedAt
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day,
              let hour = components.hour,
              let minute = components.minute,
              let second = components.second
        else { return nil }
        return CaptureWallComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
    }

    private static func components(fromCompact compact: Int64) -> CaptureWallComponents? {
        guard compact >= 1_000_000_000_000, compact <= 99_999_999_999_999 else { return nil }
        let year = Int(compact / 10_000_000_000)
        let month = Int((compact / 100_000_000) % 100)
        let day = Int((compact / 1_000_000) % 100)
        let hour = Int((compact / 10000) % 100)
        let minute = Int((compact / 100) % 100)
        let second = Int(compact % 100)
        guard (1 ... 12).contains(month),
              (1 ... 31).contains(day),
              (0 ... 23).contains(hour),
              (0 ... 59).contains(minute),
              (0 ... 59).contains(second)
        else { return nil }
        return CaptureWallComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }
}
