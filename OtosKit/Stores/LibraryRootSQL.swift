import GRDB

/// Library root SQL guide (ADR 0002)
///
/// The statements of `library_root`, one row per library, card, camera or account Otos holds:
/// its row id, which every asset key names, and the sync facts an account's row carries.
/// `CatalogStore` owns when each runs; this enum owns only the text.
nonisolated enum LibraryRootSQL {
    static let updateIdentitySQL = """
    UPDATE library_root
    SET device_identity = ?, display_name = ?, last_seen_at = ?,
        case_sensitive_names = ?, device_model = ?
    WHERE id = ?
    """

    static let lastSyncedAtSQL = "SELECT last_synced_at FROM library_root WHERE id = ?"

    static let setLastSyncedAtSQL = "UPDATE library_root SET last_synced_at = ? WHERE id = ?"

    static let resyncOwedSQL = "SELECT resync_owed FROM library_root WHERE id = ?"

    static let oweResyncSQL = "UPDATE library_root SET resync_owed = resync_owed + 1 WHERE id = ?"

    static let settleResyncSQL = "UPDATE library_root SET resync_owed = 0 WHERE id = ? AND resync_owed = ?"

    static let rowIDOfPathSQL = "SELECT id FROM library_root WHERE path = ?"

    /// Any read of the table: what holds a reader's snapshot open.
    static let countSQL = "SELECT count(*) FROM library_root"

    static let kindsSQL = "SELECT kind FROM library_root"

    static let rootsSQL = """
    SELECT id, path, kind, device_identity, display_name, last_seen_at, sort_index,
           case_sensitive_names, device_model, remote_base_url
    FROM library_root
    ORDER BY sort_index, path COLLATE NOCASE, path
    """

    static let caseSensitiveNamesSQL = "SELECT case_sensitive_names FROM library_root WHERE id = ?"

    static let highestSortIndexSQL = "SELECT MAX(sort_index) FROM library_root"

    static let insertSQL = """
    INSERT INTO library_root (
        path, kind, device_identity, display_name, last_seen_at, sort_index,
        case_sensitive_names, device_model, remote_base_url
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

    static let setSortIndexSQL = "UPDATE library_root SET sort_index = ? WHERE path = ?"

    static let setPathSQL = "UPDATE library_root SET path = ? WHERE id = ?"

    static let setLastSeenAtSQL = "UPDATE library_root SET last_seen_at = ? WHERE id = ?"

    static let updateDeviceRootSQL = """
    UPDATE library_root
    SET path = ?, display_name = ?, last_seen_at = ?,
        case_sensitive_names = ?, device_model = ?
    WHERE id = ?
    """

    static let changeJournalPositionsSQL = """
    SELECT library_root_id, volume_uuid, event_id, root_identity FROM library_root_change_journal
    """

    static let writeChangeJournalPositionSQL = """
    INSERT INTO library_root_change_journal (library_root_id, volume_uuid, event_id, root_identity)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(library_root_id) DO UPDATE SET
        volume_uuid = excluded.volume_uuid,
        event_id = excluded.event_id,
        root_identity = excluded.root_identity
    """

    static let deleteSQL = "DELETE FROM library_root WHERE id = ?"
}
