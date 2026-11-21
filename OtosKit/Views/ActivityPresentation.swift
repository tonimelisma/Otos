import Foundation

// Activity presentation (ADR 0058, `docs/design/activity.md`)
//
// Pure mappings from the board's snapshot, the Immich accounts' statuses and People's
// unchecked tally to the words the sidebar's Activity line and its popover draw. Every string
// on those surfaces is composed here, so the views are passive and the words are tested
// without a window. The surface says each piece of work's status — working, waiting on
// something, or up to date — never when it ran. Each name is an outcome the user owns, never
// the owner that makes it (DES-035); a count appears only where Otos holds an exact one
// (People's unchecked tally, the rows waiting for their originals), never an estimate
// (DES-031).

/// One Immich account as the Activity surface reads it.
nonisolated struct ActivityAccount: Equatable, Sendable {
    let name: String
    let status: ImmichAccountStatus
}

nonisolated struct ActivityPresentation: Equatable, Sendable {
    /// The three things a piece of work can be (DES-124).
    enum Status: Equatable, Sendable {
        case working
        case waiting
        case upToDate
    }

    /// One row of the popover: the work's L2 name, its L3 status under it, and the status's
    /// glyph at the trailing edge.
    struct Row: Equatable, Sendable, Identifiable {
        let id: String
        let systemImage: String
        let title: String
        let detail: String
        let status: Status
    }

    /// The sidebar line's L2: the work that has run longest, else what waits, else
    /// `Up to date`; nil before the window's owners are watched, when nothing is known (drawn
    /// as blank space, DES-053).
    let line: String?
    /// The sidebar line's L3: how many more work or wait; nil when there is nothing to add.
    let lineDetail: String?
    /// The line's glyph: a spinner while anything works (DES-072), a pause while something
    /// waits, a checkmark when everything is up to date; nil while nothing is known.
    let lineStatus: Status?
    /// The popover's L1 (DES-010).
    let header: String
    /// Every watched piece of work, in `ActivityKind` order, the accounts after.
    let rows: [Row]
    /// The line as VoiceOver reads it.
    let accessibilityLabel: String

    static func map(
        _ snapshot: ActivitySnapshot,
        accounts: [ActivityAccount] = [],
        uncheckedFaces: MediaCount? = nil
    ) -> ActivityPresentation {
        guard snapshot.watching else {
            return ActivityPresentation(
                line: nil, lineDetail: nil, lineStatus: nil, header: "", rows: [], accessibilityLabel: "Activity"
            )
        }
        var rows: [Row] = []
        var working: [(since: Date, title: String)] = []
        var waiting: [String] = []
        for entry in snapshot.entries {
            let row = row(entry, uncheckedFaces: uncheckedFaces)
            rows.append(row)
            switch entry.state {
            case let .working(since): working.append((since, workingTitle(entry.kind)))
            case .waiting: waiting.append(row.detail)
            case .upToDate: break
            }
        }
        for account in accounts {
            let row = row(account)
            rows.append(row)
            switch row.status {
            case .working:
                let doing = account.status.isSyncing ? "Syncing" : "Connecting to"
                working.append((.distantFuture, "\(doing) \(account.name)"))
            case .waiting:
                let reason = account.status.reach == .offline ? "is offline" : "is signed out"
                waiting.append("\(account.name) \(reason)")
            case .upToDate: break
            }
        }
        let line: String
        let lineDetail: String?
        let lineStatus: Status
        let header: String
        if let first = working.min(by: { $0.since < $1.since }) {
            line = first.title
            lineDetail = more(working.count - 1)
            lineStatus = .working
            header = "Working on \(things(working.count))"
        } else if let first = waiting.first {
            line = first
            lineDetail = more(waiting.count - 1)
            lineStatus = .waiting
            header = "Waiting on \(things(waiting.count))"
        } else {
            line = "Up to date"
            lineDetail = nil
            lineStatus = .upToDate
            header = "Up to date"
        }
        return ActivityPresentation(
            line: line,
            lineDetail: lineDetail,
            lineStatus: lineStatus,
            header: header,
            rows: rows,
            accessibilityLabel: ["Activity", line, lineDetail].compactMap(\.self).joined(separator: ", ")
        )
    }

    /// A watched kind's row: its name, and its status in words.
    private static func row(_ entry: ActivityEntry, uncheckedFaces: MediaCount?) -> Row {
        let (status, detail): (Status, String) = switch entry.state {
        case .working:
            (.working, countText(entry.kind, uncheckedFaces: uncheckedFaces).map { "Working, \($0)" } ?? "Working")
        case let .waiting(wait): (.waiting, waitText(wait))
        case .upToDate: (.upToDate, "Up to date")
        }
        return Row(
            id: entry.kind.rawValue, systemImage: systemImage(entry.kind), title: title(entry.kind),
            detail: detail, status: status
        )
    }

    /// An Immich account's row: syncing or connecting works, offline or signed out waits.
    private static func row(_ account: ActivityAccount) -> Row {
        let (status, detail): (Status, String) = if account.status.isSyncing {
            (.working, "Syncing")
        } else {
            switch account.status.reach {
            case .connecting: (.working, "Connecting")
            case .offline: (.waiting, "Waiting for the server")
            case .signedOut: (.waiting, "Waiting for you to sign in")
            case .online: (.upToDate, "Up to date")
            }
        }
        return Row(
            id: "immich.\(account.name)", systemImage: "server.rack", title: account.name, detail: detail, status: status
        )
    }

    private static func more(_ count: Int) -> String? {
        count > 0 ? "and \(count) more" : nil
    }

    private static func things(_ count: Int) -> String {
        "\(count) \(count == 1 ? "thing" : "things")"
    }

    /// The work's name in the popover: what it keeps up to date.
    static func title(_ kind: ActivityKind) -> String {
        switch kind {
        case .readingPhotos: "Photos"
        case .downloadingOriginals: "Originals"
        case .updatingDetails: "Photo details"
        case .findingFaces: "Faces"
        case .recognizingPeople: "People"
        case .namingPlaces: "Places"
        case .preparingSearch: "Search"
        case .describingPhotos: "Descriptions"
        case .findingDuplicates: "Duplicates"
        }
    }

    /// What a kind waits on, in the user's words.
    static func waitText(_ wait: ActivityWait) -> String {
        switch wait {
        case let .paused(hold): holdText(hold)
        case .retrying: "Waiting to try again"
        case let .originals(count?): "Waiting for \(count.formatted()) \(count == 1 ? "original" : "originals")"
        case .originals(nil): "Waiting for originals"
        }
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
}
