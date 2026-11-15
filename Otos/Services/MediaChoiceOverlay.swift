import Foundation

/// Pending curation guide (DES-120, APP-086)
///
/// A Like, Dislike or Not Rated shows its result in the step that handles it, before the
/// catalog records it: the choices submitted and not yet read back are held here, and every
/// read of tile detail (`MediaTileDetailReader`) answers with them laid over what it read, so
/// a tile, a pane, the toolbar control and the Info pane all show the choice from the moment
/// it is made and a read that started before the write landed can never take it back.
///
/// Each item keeps the choices submitted for it, oldest first, over the value the window
/// showed before the first of them (`base`); it shows the newest. A choice is retired when
/// a read that *started* after its write landed answers for the item (ADR 0032 rule 2: a read
/// numbers its start, a landing records the number reached): that read saw the write, so it
/// shows the same value without the overlay, and every older choice for the item retires
/// with it. A write that failed is withdrawn: the item shows the choice below it, or the
/// value it showed before. Nothing here waits on time; a choice for an item no read ever
/// asks about again stays held, which costs one small entry.
///
/// Main-actor state: the view model submits, lands and withdraws in the step that handles the
/// intent or the store's answer, and the reader numbers and answers its reads on the main
/// actor around its one await, so no read interleaves with a change here.
@MainActor
final class MediaChoiceOverlay {
    private struct Held {
        let command: UInt64
        let choice: MediaChoice
        /// The `readsStarted` value when the write landed; nil until it has.
        var landedAt: UInt64?
    }

    private struct Item {
        /// What the window showed before the oldest held choice: what a withdrawal of every
        /// held choice returns to, and the read value once an older choice retires.
        var base: MediaChoice
        var held: [Held]
    }

    private var items: [MediaAssetID: Item] = [:]
    /// Numbers every read of tile detail as it starts.
    private var readsStarted: UInt64 = 0
    private var commandsSubmitted: UInt64 = 0

    /// The choice the window shows for `id` while one is held; nil when none is.
    func choice(for id: MediaAssetID) -> MediaChoice? {
        items[id]?.held.last?.choice
    }

    /// Whether any choice is held, for tests and diagnostics.
    var isEmpty: Bool {
        items.isEmpty
    }

    /// Holds `assignments` under a new command. `shown` is what the window shows for each
    /// item now, from its last read; an item held already keeps the base it had.
    func submit(_ assignments: [MediaAssetID: MediaChoice], shown: (MediaAssetID) -> MediaChoice) -> UInt64 {
        commandsSubmitted &+= 1
        let command = commandsSubmitted
        for (id, choice) in assignments {
            let held = Held(command: command, choice: choice)
            if items[id] != nil {
                items[id]?.held.append(held)
            } else {
                items[id] = Item(base: shown(id), held: [held])
            }
        }
        return command
    }

    /// The command's write landed: a read that starts from now on sees it.
    func landed(_ command: UInt64, ids: some Sequence<MediaAssetID>) {
        for id in ids {
            guard let index = items[id]?.held.firstIndex(where: { $0.command == command }) else { continue }
            items[id]?.held[index].landedAt = readsStarted
        }
    }

    /// The command's write failed or found nothing to change: its choices come off, and each
    /// item shows the choice below it, or its base. Returns what each item now shows.
    @discardableResult
    func withdraw(_ command: UInt64, ids: some Sequence<MediaAssetID>) -> [MediaAssetID: MediaChoice] {
        var shown: [MediaAssetID: MediaChoice] = [:]
        for id in ids {
            guard var item = items[id] else { continue }
            item.held.removeAll { $0.command == command }
            shown[id] = item.held.last?.choice ?? item.base
            items[id] = item.held.isEmpty ? nil : item
        }
        return shown
    }

    /// A read of tile detail starts: its number, for `answer(_:asked:startedAt:)`.
    func readStarted() -> UInt64 {
        readsStarted &+= 1
        return readsStarted
    }

    /// The read numbered `started` answered `details` for `asked`: retires every choice whose
    /// write landed before the read started, and lays the newest choice still held over each
    /// detail. An asked item the read found no row for retires what landed for it too.
    func answer(
        _ details: [MediaAssetID: MediaTileDetail],
        asked: some Sequence<MediaAssetID>,
        startedAt started: UInt64
    ) -> [MediaAssetID: MediaTileDetail] {
        guard !items.isEmpty else {
            return details
        }
        var answered = details
        for id in asked {
            guard var item = items[id] else { continue }
            if let covered = item.held.lastIndex(where: { ($0.landedAt ?? .max) < started }) {
                item.held.removeSubrange(...covered)
                if let read = details[id]?.mediaChoice {
                    item.base = read
                }
            }
            items[id] = item.held.isEmpty ? nil : item
            if let choice = item.held.last?.choice, let detail = details[id], detail.mediaChoice != choice {
                answered[id] = detail.with(mediaChoice: choice)
            }
        }
        return answered
    }
}
