import Foundation

// Activity presentation (ADR 0058, `docs/design/activity.md`)
//
// Pure mappings from the board's snapshot, the Immich accounts' statuses and People's
// unchecked tally to the words the sidebar's Activity line and its popover draw. Every string
// on those surfaces is composed here, so the views are passive and the words are tested
// without a window. Each name is an outcome the user owns, never the owner that makes it
// (DES-035); a count appears only where Otos holds an exact one (People's unchecked tally),
// and a time is the moment the board or the account saw, never an estimate (DES-031).

/// One Immich account as the Activity surface reads it.
nonisolated struct ActivityAccount: Equatable, Sendable {
    let name: String
    let status: ImmichAccountStatus
}

nonisolated struct ActivityPresentation: Equatable, Sendable {
    /// One row of the popover: L2 title, an optional L3 detail under it, and the L3 time at
    /// the trailing edge.
    struct Row: Equatable, Sendable, Identifiable {
        let id: String
        let systemImage: String
        let title: String
        let detail: String?
        let time: String
    }

    /// The sidebar line's L2: the work that has run longest, or `Up to date`; nil before the
    /// window's owners are watched, when nothing is known (drawn as blank space, DES-053).
    let line: String?
    /// The sidebar line's L3: how many more, or why the work waits; nil when there is
    /// nothing to add.
    let lineDetail: String?
    /// Whether anything works now: the line's spinner (DES-072).
    let isWorking: Bool
    /// The popover's L1 (DES-010).
    let header: String
    /// What works now, in `ActivityKind` order, the accounts after.
    let working: [Row]
    /// What finished this session (and each account's last sync), newest first.
    let finished: [Row]
    /// The line as VoiceOver reads it.
    let accessibilityLabel: String

    static func map(
        _ snapshot: ActivitySnapshot,
        accounts: [ActivityAccount] = [],
        uncheckedFaces: MediaCount? = nil,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> ActivityPresentation {
        let time = TimeText(now: now, calendar: calendar, locale: locale)
        var working: [(since: Date, row: Row, held: BackgroundHold?)] = []
        var finished: [(at: Date, row: Row)] = []
        for entry in snapshot.entries {
            switch entry.state {
            case let .working(since, heldBy):
                let detail = heldBy.map(holdText) ?? countText(entry.kind, uncheckedFaces: uncheckedFaces)
                working.append((since, Row(
                    id: entry.kind.rawValue, systemImage: systemImage(entry.kind), title: workingTitle(entry.kind),
                    detail: detail, time: "Since \(time.text(since))"
                ), heldBy))
            case let .finished(at):
                finished.append((at, Row(
                    id: entry.kind.rawValue, systemImage: systemImage(entry.kind), title: finishedTitle(entry.kind),
                    detail: nil, time: time.text(at)
                )))
            }
        }
        for account in accounts where account.status.reach != .signedOut {
            let id = "immich.\(account.name)"
            if account.status.isSyncing {
                working.append((.distantFuture, Row(
                    id: id, systemImage: "server.rack", title: "Syncing \(account.name)", detail: nil, time: ""
                ), nil))
            } else if let synced = account.status.lastSynced {
                finished.append((synced, Row(
                    id: id, systemImage: "server.rack", title: "\(account.name) synced", detail: nil, time: time.text(synced)
                )))
            }
        }
        let first = working.min { $0.since < $1.since }
        let line: String?
        let lineDetail: String?
        if let first {
            line = first.row.title
            lineDetail = working.count > 1
                ? "and \(working.count - 1) more"
                : first.held.map(holdText)
        } else {
            line = snapshot.watching ? "Up to date" : nil
            lineDetail = nil
        }
        let header = working.isEmpty
            ? "Up to date"
            : "Working on \(working.count) \(working.count == 1 ? "thing" : "things")"
        let label = ["Activity", line, lineDetail].compactMap(\.self).joined(separator: ", ")
        return ActivityPresentation(
            line: line,
            lineDetail: lineDetail,
            isWorking: !working.isEmpty,
            header: header,
            working: working.map(\.row),
            finished: finished.sorted { $0.at > $1.at }.map(\.row),
            accessibilityLabel: label
        )
    }

    static func workingTitle(_ kind: ActivityKind) -> String {
        switch kind {
        case .readingPhotos: "Reading photos"
        case .downloadingOriginals: "Downloading originals"
        case .updatingDetails: "Updating photo details"
        case .findingFaces: "Finding faces"
        case .recognizingPeople: "Recognizing people"
        case .namingPlaces: "Naming places"
        case .preparingSearch: "Preparing search"
        case .describingPhotos: "Describing photos"
        case .findingDuplicates: "Looking for duplicates"
        }
    }

    static func finishedTitle(_ kind: ActivityKind) -> String {
        switch kind {
        case .readingPhotos: "Photos read"
        case .downloadingOriginals: "Originals downloaded"
        case .updatingDetails: "Photo details updated"
        case .findingFaces: "Faces found"
        case .recognizingPeople: "People recognized"
        case .namingPlaces: "Places named"
        case .preparingSearch: "Search ready"
        case .describingPhotos: "Photos described"
        case .findingDuplicates: "Duplicates checked"
        }
    }

    static func systemImage(_ kind: ActivityKind) -> String {
        switch kind {
        case .readingPhotos: "photo.on.rectangle"
        case .downloadingOriginals: "icloud.and.arrow.down"
        case .updatingDetails: "info.circle"
        case .findingFaces: "person.crop.square"
        case .recognizingPeople: "person.2"
        case .namingPlaces: "map"
        case .preparingSearch: "magnifyingglass"
        case .describingPhotos: "text.below.photo"
        case .findingDuplicates: "square.on.square"
        }
    }

    /// Why a kind waits: the machine condition its owners wait out (ADR 0057).
    static func holdText(_ hold: BackgroundHold) -> String {
        switch hold {
        case .memoryWarning, .memoryCritical: "Paused while memory is low"
        case .thermal: "Paused while the Mac cools down"
        case .lowPower: "Paused in Low Power Mode"
        }
    }

    /// The one exact count Otos holds for a kind's remaining work: People's unchecked tally.
    private static func countText(_ kind: ActivityKind, uncheckedFaces: MediaCount?) -> String? {
        guard kind == .findingFaces, let uncheckedFaces, uncheckedFaces.total > 0 else { return nil }
        return "\(uncheckedFaces.text) to check"
    }

    /// A moment as the popover shows it: the time today, else the day and the time.
    private struct TimeText {
        let now: Date
        let calendar: Calendar
        let locale: Locale

        func text(_ date: Date) -> String {
            var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
            if !calendar.isDate(date, inSameDayAs: now) {
                style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: calendar)
            }
            style.timeZone = calendar.timeZone
            return date.formatted(style)
        }
    }
}
