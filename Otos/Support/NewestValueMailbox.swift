import Synchronization

/// Newest-value mailbox guide
///
/// Carries newest-wins state from a producer to one consumer that may be busy, so the
/// consumer applies the newest value there is *when it runs*, never one a later value has
/// already superseded (ADR 0032, rule 5).
///
/// Why not an `AsyncStream` with `.bufferingNewest(1)` alone: such a stream hands a value
/// straight to a consumer parked in `next()`, and that consumer's resumption then waits for
/// its actor with the value it was handed. On the main actor that wait is a whole
/// main-thread turn; a value published meanwhile lands in the buffer behind it, so the
/// consumer applies the superseded value first and the newest one a turn later. Here the
/// consumer's wake is a doorbell that carries nothing, and what it takes is read from the
/// slot at the moment it runs.
///
/// `put` may be called from any thread; the slot is guarded by a `Mutex`, and the
/// doorbell (`.bufferingNewest(1)`) only says that the slot may hold a value. One consumer
/// iterates; `finish` ends its iteration once the slot is empty.
final nonisolated class NewestValueMailbox<Value: Sendable>: AsyncSequence, Sendable {
    /// A value taken from the slot, with how many values put before it were never taken.
    nonisolated struct Delivery: Sendable {
        let value: Value
        let superseded: Int
    }

    private nonisolated struct Slot {
        var value: Value?
        var superseded = 0
    }

    private let slot = Mutex(Slot())
    private let rings: AsyncStream<Void>
    private let doorbell: AsyncStream<Void>.Continuation

    init() {
        (rings, doorbell) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Replaces any value not yet taken with `value` and wakes the consumer.
    func put(_ value: Value) {
        slot.withLock { slot in
            if slot.value != nil {
                slot.superseded += 1
            }
            slot.value = value
        }
        doorbell.yield()
    }

    /// Ends the consumer's iteration once it has taken what the slot holds.
    func finish() {
        doorbell.finish()
    }

    private func take() -> Delivery? {
        slot.withLock { slot in
            guard let value = slot.value else {
                return nil
            }
            let delivery = Delivery(value: value, superseded: slot.superseded)
            slot = Slot()
            return delivery
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(mailbox: self, rings: rings.makeAsyncIterator())
    }

    nonisolated struct AsyncIterator: AsyncIteratorProtocol {
        let mailbox: NewestValueMailbox
        var rings: AsyncStream<Void>.AsyncIterator

        /// The newest value, read when the consumer runs. A ring whose value an earlier
        /// take already delivered finds the slot empty and waits again. A cancelled
        /// consumer takes nothing more.
        mutating func next(isolation actor: isolated (any Actor)?) async -> Delivery? {
            while true {
                guard await rings.next(isolation: actor) != nil else {
                    return Task.isCancelled ? nil : mailbox.take()
                }
                if let delivery = mailbox.take() {
                    return delivery
                }
            }
        }

        mutating func next() async -> Delivery? {
            await next(isolation: #isolation)
        }
    }
}
