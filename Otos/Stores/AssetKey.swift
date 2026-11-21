import GRDB

/// Asset key guide (ADR 0002, ADR 0025)
///
/// Every catalog table that holds a fact about an asset — `media_asset`, `asset_metadata`,
/// `face`, `face_rejection`, `search_text`, `search_embedding`, `photo_description` and the
/// rest — names its row by the asset's library row and relative path. `AssetKey` is that key
/// and the one place its SQL is written: a statement asks for one asset's rows with
/// `AssetKey.exactText(table)` and binds `key.arguments` at that place in its arguments.
///
/// Two equalities find an asset by its path, and each statement names which one it asks:
/// - **Exact text**, `(library_root_id, relative_path)`: the path as stored, byte for byte.
///   It is the unique key of `media_asset` and the key every overlay table repeats, so a
///   statement that names an asset Otos already holds seeks it this way.
/// - **Volume-aware**, `(library_root_id, relative_path_key)`: the path as its volume compares
///   names (`FilesystemNamespaceSemantics.nameKey`), where two spellings that differ only in
///   case or Unicode form are one name. A scan or a companion inventory asks it to find a row
///   whose file the volume now spells differently, and respells that row.
///
/// The predicates are text spliced into a statement, never a statement of their own: the
/// statement around them keeps its own plan pins (`INDEXED BY`), and
/// `CatalogStoreQueryPlanTests` records the plan of every statement that names either key.
/// A migration writes its own SQL literally and never uses this type (ADR 0002).
nonisolated struct AssetKey: Hashable, Sendable {
    /// The asset's library row (`library_root.id`).
    let rootID: Int64
    let path: MediaRelativePath

    /// The exact-text equality on `table`'s key (unqualified when nil):
    /// `library_root_id = ? AND relative_path = ?`. Binds `arguments`.
    static func exactText(_ table: String? = nil) -> String {
        let column = table.map { "\($0)." } ?? ""
        return "\(column)library_root_id = ? AND \(column)relative_path = ?"
    }

    /// The values `exactText` binds, in its order.
    var arguments: StatementArguments {
        [rootID, path.rawValue]
    }

    /// The volume-aware equality on `table`'s key (unqualified when nil):
    /// `library_root_id = ? AND relative_path_key = ?`. Binds `volumeAwareArguments`.
    static func volumeAware(_ table: String? = nil) -> String {
        let column = table.map { "\($0)." } ?? ""
        return "\(column)library_root_id = ? AND \(column)relative_path_key = ?"
    }

    /// The values `volumeAware` binds for a path whose volume spells it `nameKey`.
    static func volumeAwareArguments(rootID: Int64, nameKey: FilesystemNameKey) -> StatementArguments {
        [rootID, nameKey.rawValue]
    }
}
