import Foundation

// Activity presentation (ADR 0058, `docs/design/activity.md`)
//
// Pure mappings from the board's snapshot, the Immich accounts' statuses, People's unchecked
// tally and the libraries' names to the words the sidebar's Activity line and its popover
// draw. Every string on those surfaces is composed here, so the views are passive and the
// words are tested without a window.
//
// The popover answers what a user asks of background work (HIG Feedback, Progress
// indicators): is everything here yet, is something wrong that I can fix, and is Otos busy.
// So it lists outcomes the user would notice missing, each named by what it does for them
// (DES-035) with how many items it has left — an exact count, from its owner
// (`ActivityProgress`, DES-124) — and a determinate bar only while the work moves. A problem
// is said only when the user would notice it (`OwnerTrouble.Standing`): what they can fix
// first, then a source or service that is not available, named; one item failing and being
// tried again is never said, and an item only the user's work can read is no work left. It
// never says when work ran or how long is left, and never a percentage (DES-031).

/// One Immich account as the Activity surface reads it.
nonisolated struct ActivityAccount: Equatable, Sendable {
    let name: String
    let status: ImmichAccountStatus
}

nonisolated struct ActivityPresentation: Equatable, Sendable {
    /// What a row, or the line, shows by its glyph (DES-124).
    enum Status: Equatable, Sendable {
        /// Something only the user can fix stops it.
        case needsYou
        case working
        case waiting
        case upToDate
    }

    /// A row's determinate bar: `done` of `total`, both exact.
    struct Bar: Equatable, Sendable {
        let done: Int
        let total: Int
    }

    /// What a row offers the user to do about what stops it.
    enum Action: Equatable, Sendable {
        /// Opens Otos's Settings, where an account is signed in again.
        case openSettings(String)
    }

    /// One row of the popover: what the work does (L2); how far it is, what it waits on and
    /// what stops it under it (L3, each its own line); its bar; and what the user can do.
    struct Row: Equatable, Sendable, Identifiable {
        let id: String
        let systemImage: String
        let title: String
        let details: [String]
        let status: Status
        var bar: Bar?
        /// The first thing it says stops it, which the line says for it alone.
        var reason: String?
        var action: Action?
    }

    /// The sidebar line's L2: what needs the user, else the work that has run longest, else
    /// what waits, else `Up to date`; nil before the window's owners are watched, when nothing
    /// is known (drawn as blank space, DES-053).
    let line: String?
    /// The sidebar line's L3: how many more rows the popover lists, or, for one row that needs
    /// the user or waits alone, what stops it; nil when there is nothing to add.
    let lineDetail: String?
    /// The line's glyph: a warning while something needs the user, a spinner while anything
    /// works (DES-072), a pause while something waits, a checkmark when everything is up to
    /// date; nil while nothing is known.
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
        uncheckedFaces: MediaCount? = nil,
        sourceNames: [LibraryRootPath: String] = [:]
    ) -> ActivityPresentation {
        guard snapshot.watching else {
            return ActivityPresentation(
                line: nil, lineDetail: nil, lineStatus: nil, header: "", rows: [], footer: nil,
                accessibilityLabel: "Activity"
            )
        }
        var rows: [Row] = []
        var working: [(since: Date, row: Row, kind: ActivityKind?)] = []
        var unlisted = 0
        for entry in snapshot.entries {
            guard let row = row(entry, uncheckedFaces: uncheckedFaces, sourceNames: sourceNames) else {
                unlisted += 1
                continue
            }
            rows.append(row)
            if case let .working(since) = entry.state {
                working.append((since, row, entry.kind))
            }
        }
        for account in accounts {
            guard let row = row(account) else {
                unlisted += 1
                continue
            }
            rows.append(row)
            if row.status == .working {
                working.append((.distantFuture, row, nil))
            }
        }
        // `Reading details` names the line only when nothing else works: the user sees nothing
        // missing of it, but the line never says up to date while work runs.
        let named = working.filter { $0.kind != .readingDetails }
        let needsYou = rows.filter { $0.status == .needsYou }
        let waiting = rows.filter { $0.status == .waiting || $0.status == .needsYou }
        let line: String
        let lineDetail: String?
        let lineStatus: Status
        let header: String
        if let first = needsYou.first {
            line = first.title
            lineDetail = more(rows.count - 1) ?? first.reason.map(firstSentence)
            lineStatus = .needsYou
            header = working.isEmpty ? "Waiting on \(things(waiting.count))" : "Working on \(things(working.count))"
        } else if let first = (named.isEmpty ? working : named).min(by: { $0.since < $1.since }) {
            line = first.row.title
            lineDetail = more(rows.count - 1)
            lineStatus = .working
            header = "Working on \(things(working.count))"
        } else if let first = waiting.first {
            line = first.title
            lineDetail = more(rows.count - 1) ?? first.reason.map(firstSentence)
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
            footer: rows.isEmpty || unlisted == 0 ? nil : "Everything else is up to date",
            accessibilityLabel: ["Activity", line, lineDetail].compactMap(\.self).joined(separator: ", ")
        )
    }

    /// A watched kind's row, or nil when the user would see nothing of it: up to date, or
    /// `Reading details` while it does not work. What it does, how many items it has left, the
    /// downloads it waits on, then what pauses or stops it.
    private static func row(
        _ entry: ActivityEntry,
        uncheckedFaces: MediaCount?,
        sourceNames: [LibraryRootPath: String]
    ) -> Row? {
        let said = entry.troubles.filter { $0.cause.standing == .needsYou || $0.cause.standing == .unavailable }
        let troubles = said.compactMap { troubleText($0, sourceNames: sourceNames) }
        let progress = progressLine(entry, uncheckedFaces: uncheckedFaces).map { [$0] } ?? []
        let status: Status
        let details: [String]
        switch entry.state {
        case .working:
            status = .working
            details = progress + (entry.transfers.flatMap(transfersText).map { [$0] } ?? []) + troubles
        case let .paused(hold):
            status = .waiting
            details = progress + [holdText(hold)] + troubles
        case .waiting:
            guard entry.kind != .readingDetails else { return nil }
            status = said.contains { $0.cause.standing == .needsYou } ? .needsYou : .waiting
            // Items that wait out their own failures say only that they are tried again: which
            // failure is the log's, not the user's (HIG Feedback).
            details = progress + (troubles.isEmpty ? ["Otos will try these again later."] : troubles)
        case .upToDate:
            return nil
        }
        if entry.kind == .readingDetails, status != .working {
            return nil
        }
        return Row(
            id: entry.kind.rawValue, systemImage: systemImage(entry.kind), title: title(entry.kind),
            details: details, status: status, bar: status == .working ? bar(entry.progress) : nil,
            reason: troubles.first
        )
    }

    /// The bar for a working stretch with something to count. A row that waits has none: its
    /// work does not move, so a bar would claim progress there is none of; its count says how
    /// much is left.
    private static func bar(_ progress: ActivityProgress?) -> Bar? {
        guard let progress, progress.total > 0 else { return nil }
        return Bar(done: min(progress.done, progress.total), total: progress.total)
    }

    /// How many items a kind has left, in its own words; before its first count, People's
    /// unchecked tally where Otos holds it. Nil when nothing is counted.
    private static func progressLine(_ entry: ActivityEntry, uncheckedFaces: MediaCount?) -> String? {
        guard let progress = entry.progress, progress.total > 0 else {
            return countText(entry.kind, uncheckedFaces: uncheckedFaces)
        }
        let left = max(progress.left, 0)
        let count = left.formatted()
        switch entry.kind {
        case .showingPhotos, .preparingSearch, .readingDetails:
            return "\(count) \(left == 1 ? "photo or video" : "photos and videos") left"
        case .findingPeople:
            return "\(count) \(left == 1 ? "photo or video" : "photos and videos") to check"
        case .namingPlaces:
            return "\(count) \(left == 1 ? "place" : "places") left"
        case .describingPhotos:
            return "\(count) \(left == 1 ? "photo" : "photos") left"
        case .findingDuplicates:
            return "\(count) \(left == 1 ? "photo" : "photos") to compare"
        }
    }

    /// The downloads a row's work waits on: how many of the run finished, and their bytes when
    /// every one has a size on record. Nil for a run with nothing asked.
    static func transfersText(_ run: TransferRun) -> String? {
        guard run.total > 0 else { return nil }
        var text = "Downloading \(min(run.done, run.total).formatted()) of \(run.total.formatted())"
        if let bytesDone = run.bytesDone, let bytesTotal = run.bytesTotal {
            text += " · \(bytesText(bytesDone)) of \(bytesText(bytesTotal))"
        }
        return text
    }

    private static func bytesText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    /// An Immich account's row, or nil when it is up to date: syncing or connecting works,
    /// offline waits, and signed out needs the user, who signs in again in Settings. A server
    /// that stops answering is said here, on the account it is, never as the items it held
    /// back.
    private static func row(_ account: ActivityAccount) -> Row? {
        let status: Status
        let details: [String]
        var bar: Bar?
        var action: Action?
        if account.status.isSyncing {
            let progress = account.status.progress.flatMap(syncProgressLine)
            (status, details) = (.working, progress.map { [$0.text] } ?? [])
            bar = progress?.bar
        } else {
            switch account.status.reach {
            case .connecting: (status, details) = (.working, ["Connecting to the server"])
            case .offline: (status, details) = (.waiting, ["The server isn’t answering. Otos will try again."])
            case .signedOut:
                (status, details) = (.needsYou, ["You’re signed out of this account. Sign in again in Settings."])
                action = .openSettings("Open Settings…")
            case .online: return nil
            }
        }
        return Row(
            id: "immich.\(account.name)", systemImage: "server.rack", title: "Syncing Immich: \(account.name)",
            details: details, status: status, bar: bar, reason: status == .working ? nil : details.first, action: action
        )
    }

    /// How far an account's pass is: its listing so far, with no bar, since the stream names
    /// no total ahead of its end; then its images, with a bar when the rows owed them were
    /// counted. Nil before anything is listed or tried, which says nothing worth a line.
    static func syncProgressLine(_ progress: ImmichAccountStatus.SyncProgress) -> (text: String, bar: Bar?)? {
        switch progress {
        case let .listing(listed):
            guard listed > 0 else { return nil }
            return ("\(listed.formatted()) \(listed == 1 ? "photo or video" : "photos and videos") so far", nil)
        case let .images(done, total):
            guard let total, total > 0 else {
                guard done > 0 else { return nil }
                return ("\(done.formatted()) \(done == 1 ? "thumbnail" : "thumbnails") so far", nil)
            }
            let shown = min(done, total)
            return (
                "\(shown.formatted()) of \(total.formatted()) \(total == 1 ? "thumbnail" : "thumbnails")",
                Bar(done: shown, total: total)
            )
        }
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
        case .showingPhotos: "Showing photos"
        case .findingPeople: "Finding people"
        case .namingPlaces: "Naming places"
        case .preparingSearch: "Preparing search"
        case .describingPhotos: "Describing photos"
        case .findingDuplicates: "Looking for duplicates"
        case .readingDetails: "Reading details"
        }
    }

    static func systemImage(_ kind: ActivityKind) -> String {
        switch kind {
        case .showingPhotos: "photo.on.rectangle"
        case .findingPeople: "person.2"
        case .namingPlaces: "map"
        case .preparingSearch: "magnifyingglass"
        case .describingPhotos: "text.below.photo"
        case .findingDuplicates: "square.on.square"
        case .readingDetails: "info.circle"
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
    /// do (HIG Progress indicators: a stalled process says what the problem is and what people
    /// can do about it; Writing: an error says what can fix it). A source is named as the
    /// sidebar names it. Nil for a cause the user is never told (`OwnerTrouble.Standing`):
    /// one item failing and being tried again, or an item only their own work can read.
    static func troubleText(_ trouble: OwnerTrouble, sourceNames: [LibraryRootPath: String] = [:]) -> String? {
        switch trouble.cause {
        case .downloadsFailed, .serverDidNotAnswer, .rawSupportUnavailable, .sentOnlyWhenOpened,
             .facesUnread, .descriptionsFailed:
            return nil
        case .diskFull:
            return "The disk is almost full. Free up space, and Otos will go on."
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
        case .providerNotAnswering:
            let names = trouble.sources.compactMap { sourceNames[$0] }.map { "“\($0)”" }
            guard !names.isEmpty, names.count == trouble.sources.count else {
                return "The cloud provider isn’t answering. Otos will try again."
            }
            return "\(names.formatted(.list(type: .and))) \(names.count == 1 ? "isn’t" : "aren’t") answering. Otos will try again."
        case .placeNamesFailed:
            return "Place names couldn’t be looked up. Otos will try again."
        case .searchFailed:
            return "Search couldn’t be updated. Otos will try again."
        }
    }

    /// The one exact count Otos holds for a kind's remaining work: People's unchecked tally.
    private static func countText(_ kind: ActivityKind, uncheckedFaces: MediaCount?) -> String? {
        guard kind == .findingPeople, let uncheckedFaces, uncheckedFaces.total > 0 else { return nil }
        return "\(uncheckedFaces.text) to check"
    }
}
