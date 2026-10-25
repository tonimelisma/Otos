import Foundation
import GRDB

/// Makes every catalog read of `table` fail, as an unreadable schema does, by renaming it
/// from a second connection to the store's database file; `restore()` names it back. The
/// store's own connections see the change on their next statement, so a read made while
/// the table is hidden fails inside the store, exactly where a real query failure would.
struct HiddenCatalogTable {
    private let databaseURL: URL
    private let table: String

    init(_ table: String, in databaseURL: URL) async throws {
        self.databaseURL = databaseURL
        self.table = table
        try await rename(from: table, to: hiddenName)
    }

    func restore() async throws {
        try await rename(from: hiddenName, to: table)
    }

    private var hiddenName: String {
        "\(table)_hidden"
    }

    private func rename(from source: String, to destination: String) async throws {
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).write { db in
            try db.execute(sql: "ALTER TABLE \(source) RENAME TO \(destination)")
        }
    }
}
