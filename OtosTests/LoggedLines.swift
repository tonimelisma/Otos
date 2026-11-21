import Foundation
import OSLog
@testable import OtosKit

/// The lines this process wrote to Otos's log: what a test reads to see that a path logged what
/// it must, and how often. Tests run in parallel in one process, so a test names its own lines
/// by something only it holds (a temporary folder's path).
enum LoggedLines {
    /// The messages of `category` logged since `date` that start with `prefix` and contain
    /// `naming`, in the order they were logged.
    static func read(_ category: OtosLog.Category, since date: Date, prefix: String, naming: String) throws -> [String] {
        let log = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try log.getEntries(
            at: log.position(date: date),
            matching: NSPredicate(format: "subsystem == %@ AND category == %@", OtosLog.subsystem, category.rawValue)
        )
        return entries.compactMap { entry in
            guard let entry = entry as? OSLogEntryLog else { return nil }
            let message = entry.composedMessage
            return message.hasPrefix(prefix) && message.contains(naming) ? message : nil
        }
    }

    /// The `key=value` fields of one logged line.
    static func fields(of message: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in message.split(separator: " ") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                fields[String(parts[0])] = String(parts[1])
            }
        }
        return fields
    }
}
