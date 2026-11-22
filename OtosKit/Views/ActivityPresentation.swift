import Foundation

// Activity presentation (ADR 0058, `docs/design/activity.md`)
//
// Pure mappings from the board's snapshot, the Immich accounts' statuses and People's
// unchecked tally to the words the sidebar's Activity line and its popover draw. Every string
// on those surfaces is composed here, so the views are passive and the words are tested
// without a window. The popover lists only work that runs or waits, each row named by what
// it does for the user (DES-035) and, when something stops it, saying what in a sentence:
// the cause its owner reported (`OwnerTrouble`), never a bare "waiting". Everything else is
// one line: up to date. It never says when work ran. A count appears only where Otos holds an
// exact one — People's unchecked tally, the items a trouble stops — never an estimate
// (DES-031).

/// One Immich account as the Activity surface reads it.
nonisolated struct ActivityAccount: Equatable, Sendable {
    let name: String
    let status: ImmichAccountStatus
}

nonisolated struct ActivityPresentation: Equatable, Sendable {
    /// What a row, or the line, shows by its glyph (DES-124).
    enum Status: Equatable, Sendable {
        case working
        case waiting
        case upToDate
    }

    /// One row of the popover: what the work does (L2), what stops it or how much is left
    /// under it (L3, each its own line), and its status's glyph at the trailing edge.
    struct Row: Equatable, Sendable, Identifiable {
        let id: String
        let systemImage: String
        let title: String
        let details: [String]
        let status: Status
    }

    /// The sidebar line's L2: the work that has run longest, else what waits, else
    /// `Up to date`; nil before the window's owners are watched, when nothing is known (drawn
    /// as blank space, DES-053).
    let line: String?
    /// The sidebar line's L3: how many more rows the popover lists, or, for one waiting row
    /// alone, what stops it; nil when there is nothing to add.
    let lineDetail: String?
    /// The line's glyph: a spinner while anything works (DES-072), a pause while something
    /// waits, a checkmark when everything is up to date; nil while nothing is known.
    let lineStatus: Status?
    /// The popover's L1 (DES-010).
    let header: String
    /// The work that runs or waits, in `ActivityKind` order, the accounts after.
    let rows: [Row]
    /// Under the rows, for the rest: `Everything else is up to date`; nil when no row is
    /// listed or nothing else is watched.
    let footer: String?
    /// The line as VoiceOver reads it.
    let accessibilityLabel: String

    static func map(
        _ snapshot: ActivitySnapshot,
        accounts: [ActivityAccount] = [],
        uncheckedFaces: MediaCount? = nil
    ) -> ActivityPresentation {
        guard snapshot.watching else {
            return ActivityPresentation(
                line: nil, lineDetail: nil, lineStatus: nil, header: "", rows: [], footer: nil,
                accessibilityLabel: "Activity"
            )
        }
        var rows: [Row] = []
        var working: [(since: Date, title: String)] = []
        var upToDate = 0
        for entry in snapshot.entries {
            guard let row = row(entry, uncheckedFaces: uncheckedFaces) else {
                upToDate += 1
                continue
            }
            rows.append(row)
            if case let .working(since) = entry.state {
                working.append((since, row.title))
            }
        }
        for account in accounts {
            guard let row = row(account) else {
                upToDate += 1
                continue
            }
            rows.append(row)
            if row.status == .working {
                working.append((.distantFuture, row.title))
            }
        }
        let waiting = rows.filter { $0.status == .waiting }
        let line: String
        let lineDetail: String?
        let lineStatus: Status
        let header: String
        if let first = working.min(by: { $0.since < $1.since }) {
            line = first.title
            lineDetail = more(rows.count - 1)
            lineStatus = .working
            header = "Working on \(things(working.count))"
        } else if let first = waiting.first {
            line = first.title
            lineDetail = more(rows.count - 1) ?? first.details.first.map(firstSentence)
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
            footer: rows.isEmpty || upToDate == 0 ? nil : "Everything else is up to date",
            accessibilityLabel: ["Activity", line, lineDetail].compactMap(\.self).joined(separator: ", ")
        )
    }

    /// A watched kind's row, or nil when it is up to date: what it does, then what pauses or
    /// stops it, else how much is left where Otos holds that count.
    private static func row(_ entry: ActivityEntry, uncheckedFaces: MediaCount?) -> Row? {
        let troubles = entry.troubles.map(troubleText)
        let (status, details): (Status, [String])
        switch entry.state {
        case .working:
            status = .working
            details = troubles.isEmpty ? countText(entry.kind, uncheckedFaces: uncheckedFaces).map { [$0] } ?? [] : troubles
        case let .paused(hold):
            status = .waiting
            details = [holdText(hold)] + troubles
        case .stuck:
            status = .waiting
            details = troubles
        case .upToDate:
            return nil
        }
        return Row(
            id: entry.kind.rawValue, systemImage: systemImage(entry.kind), title: title(entry.kind),
            details: details, status: status
        )
    }

    /// An Immich account's row, or nil when it is up to date: syncing or connecting works,
    /// offline or signed out waits.
    private static func row(_ account: ActivityAccount) -> Row? {
        let status: Status
        let details: [String]
        if account.status.isSyncing {
            (status, details) = (.working, [])
        } else {
            switch account.status.reach {
            case .connecting: (status, details) = (.working, ["Connecting to the server"])
            case .offline: (status, details) = (.waiting, ["The server isn’t answering. Otos will try again."])
            case .signedOut: (status, details) = (.waiting, ["You’re signed out of this account."])
            case .online: return nil
            }
        }
        return Row(
            id: "immich.\(account.name)", systemImage: "server.rack", title: "Syncing \(account.name)",
            details: details, status: status
        )
    }

    private static func more(_ count: Int) -> String? {
        count > 0 ? "and \(count) more" : nil
    }

    private static func things(_ count: Int) -> String {
        "\(count) \(count == 1 ? "thing" : "things")"
    }

    /// A detail's first sentence without its period: what the line has room for.
    private static func firstSentence(_ text: String) -> String {
        let sentence = text.split(separator: ". ", maxSplits: 1).first.map(String.init) ?? text
        return sentence.hasSuffix(".") ? String(sentence.dropLast()) : sentence
    }

    /// What the work does, in the user's words: the row's L2, and the line's while it works.
    static func title(_ kind: ActivityKind) -> String {
        switch kind {
        case .readingPhotos: "Reading photos"
        case .downloadingOriginals: "Downloading photos"
        case .findingPeople: "Finding people"
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
        case .findingPeople: "person.2"
        case .namingPlaces: "map"
        case .preparingSearch: "magnifyingglass"
        case .describingPhotos: "text.below.photo"
        case .findingDuplicates: "square.on.square"
        }
    }

    /// Why a kind is paused: the machine condition its owners wait out (ADR 0057).
    static func holdText(_ hold: BackgroundHold) -> String {
        switch hold {
        case .memoryWarning, .memoryCritical: "Paused while memory is low."
        case .thermal: "Paused while the Mac cools down."
        case .lowPower: "Paused in Low Power Mode."
        }
    }

    /// What stops work, in sentences: the cause, then what happens next or what the user can
    /// do (HIG, Progress indicators: a stalled process says what the problem is and what
    /// people can do about it).
    static func troubleText(_ trouble: OwnerTrouble) -> String {
        let items = trouble.count.map(itemsText)
        switch trouble.cause {
        case .downloadsFailed:
            return "\(items.map { "\(capitalizedFirst($0)) didn’t" } ?? "Some items didn’t") download. Otos will try again."
        case .diskFull:
            return "The disk is almost full. Otos will go on when there’s room."
        case .serverDidNotAnswer:
            return "The server didn’t answer for \(items ?? "some items"). Otos will try again."
        case .sentOnlyWhenOpened:
            return "The server sends \(items ?? "some items") only when you open them. Otos will try again."
        case .facesUnread:
            return "Faces in \(items ?? "some items") couldn’t be read. Otos will try again."
        case .faceModelUnavailable:
            return "The face finder couldn’t start. Otos will try again."
        case .appleIntelligenceOff:
            return "Turn on Apple Intelligence in System Settings to describe photos."
        case .appleIntelligenceUnsupported:
            return "This Mac can’t run Apple Intelligence."
        case .appleIntelligenceNotReady:
            return "Apple Intelligence isn’t ready yet. Otos will try again."
        case .appleIntelligenceNotResponding:
            return "Apple Intelligence isn’t responding. Otos will try again."
        case .appleIntelligenceBusy:
            return "Apple Intelligence is busy. Otos will try again."
        case .descriptionsFailed:
            return "\(items.map(capitalizedFirst) ?? "Some items") couldn’t be described. Otos will try again."
        case .providerNotAnswering:
            return "The cloud provider isn’t answering. Otos will try again."
        case .placeNamesFailed:
            return "Place names couldn’t be looked up. Otos will try again."
        case .searchFailed:
            return "Search couldn’t be updated. Otos will try again."
        }
    }

    /// The text with its first letter capitalized: a count opening a sentence starts with a
    /// digit, so this changes only a word.
    private static func capitalizedFirst(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func itemsText(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "item" : "items")"
    }

    /// The one exact count Otos holds for a kind's remaining work: People's unchecked tally.
    private static func countText(_ kind: ActivityKind, uncheckedFaces: MediaCount?) -> String? {
        guard kind == .findingPeople, let uncheckedFaces, uncheckedFaces.total > 0 else { return nil }
        return "\(uncheckedFaces.text) to check"
    }
}
