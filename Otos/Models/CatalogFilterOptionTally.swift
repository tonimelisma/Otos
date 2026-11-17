import Foundation

/// Filter option tally guide (ADR 0005, "Keyed re-reads")
///
/// The filter's options for a sidebar row, held as what each of its rows gives them: its file
/// type and the map cell it falls in, by the row's SQLite row id. The options are derived from
/// the counts (`options`): a type is offered while a row has it, a place with the number of
/// rows in its named cells, most first. So a change that names its rows and moves only their
/// locations or types re-reads those rows by key and replaces what they gave (`replace(_:)`),
/// and a change of the cells' names re-reads the names alone, instead of reading the row's
/// whole scope again: on the owner's library a sync moved the locations of rows a batch at a
/// time, and each batch re-read All Media's options whole
/// (`docs/research/2026-11-16-window-reads-owner-catalog.md`).
///
/// Held compactly, because it is held for the shown row while the window is open: per row, its
/// row id and two small indexes into the tables of the types and cells present, so All Media's
/// 159,000 rows hold about 2.2 MB, not a dictionary entry with two optionals each. A row id
/// names a row while it exists; a change that adds or removes rows is a membership change,
/// which reads the tally whole, so a held id never names another row.
nonisolated struct CatalogFilterOptionTally: Sendable {
    /// A file type: a kind, and the format MediaMetadata names, when it names one.
    struct FileType: Hashable, Sendable {
        let kind: MediaKind
        let format: MediaFormatToken?
    }

    /// What one row of the scope gives the options; nil members give nothing.
    struct Fact: Equatable, Sendable {
        var type: FileType?
        var cell: PlaceCell?
    }

    /// One re-read row: its fact, or nil for a row the scope no longer counts.
    struct Row: Equatable, Sendable {
        let rowID: Int64
        let fact: Fact?
    }

    /// The index no type or cell has: a row of no type, an unlocated row, or a row the scope no
    /// longer counts.
    private static let noType = UInt16.max
    private static let noCell = UInt32.max

    /// Each counted row's id, type and cell, in the order the read gave them.
    private var rowIDs: [Int64] = []
    private var typeOfRow: [UInt16] = []
    private var cellOfRow: [UInt32] = []
    /// The types and cells seen, each with the number of rows that give it now.
    private var typeTable: [FileType] = []
    private var typeIndex: [FileType: UInt16] = [:]
    private var typeCounts: [Int] = []
    private var cellTable: [PlaceCell] = []
    private var cellIndex: [PlaceCell: UInt32] = [:]
    private var cellCounts: [Int] = []
    /// The cells Maps named in `language`, with their names.
    var names: [PlaceCell: PlaceNames]
    /// The language the places are offered in; nil offers none (`CatalogFilterOptions`).
    let language: PlaceNameLanguage?

    /// An empty tally, which a whole read fills (`take(rowIDs:types:cells:)`).
    init(names: [PlaceCell: PlaceNames], language: PlaceNameLanguage?) {
        self.names = names
        self.language = language
    }

    /// How many rows the tally counts.
    var rowCount: Int {
        rowIDs.count
    }

    /// How many distinct types and cells the counted rows give.
    var typeCount: Int {
        typeCounts.count { $0 > 0 }
    }

    var cellCount: Int {
        cellCounts.count { $0 > 0 }
    }

    /// A run of consecutive rows of a whole read of one type, or of one cell: its slot in this
    /// tally (`typeSlot(_:)`, `cellSlot(_:)`) and how many rows it holds. A read walking every
    /// row of the scope counts a run once, at its end (`count(_:)`), not a count per row.
    struct TypeRun {
        let slot: UInt16
        var rows = 0
    }

    struct CellRun {
        let slot: UInt32
        var rows = 0
    }

    mutating func count(_ run: TypeRun) {
        if run.slot != Self.noType {
            typeCounts[Int(run.slot)] += run.rows
        }
    }

    mutating func count(_ run: CellRun) {
        if run.slot != Self.noCell {
            cellCounts[Int(run.slot)] += run.rows
        }
    }

    /// The columns of every row a whole read walked, in its order, each made once at its length
    /// (`MappedArrayBuilder`); the read counted the rows by runs as it walked them.
    mutating func take(rowIDs: [Int64], types: [UInt16], cells: [UInt32]) {
        self.rowIDs = rowIDs
        typeOfRow = types
        cellOfRow = cells
    }

    /// Replaces what each of `rows` gave by what it gives now, in place. False, with the tally
    /// unchanged, when a row the scope counts now was not counted: it entered the scope, which
    /// only a change of which rows the row holds does, and the tally is read again whole.
    mutating func replace(_ rows: [Row]) -> Bool {
        guard !rows.isEmpty else {
            return true
        }
        var wanted = [Int64: Int](minimumCapacity: rows.count)
        for (offset, row) in rows.enumerated() {
            wanted[row.rowID] = offset
        }
        var positions = [Int?](repeating: nil, count: rows.count)
        for (position, rowID) in rowIDs.enumerated() {
            if let offset = wanted[rowID] {
                positions[offset] = position
            }
        }
        for (offset, row) in rows.enumerated() where positions[offset] == nil && row.fact != nil {
            return false
        }
        for (offset, row) in rows.enumerated() {
            guard let position = positions[offset] else { continue }
            set(row.fact ?? Fact(), at: position)
        }
        return true
    }

    private mutating func set(_ fact: Fact, at position: Int) {
        let type = typeSlot(fact.type)
        let cell = cellSlot(fact.cell)
        let oldType = typeOfRow[position]
        if oldType != type {
            if oldType != Self.noType {
                typeCounts[Int(oldType)] -= 1
            }
            if type != Self.noType {
                typeCounts[Int(type)] += 1
            }
            typeOfRow[position] = type
        }
        let oldCell = cellOfRow[position]
        if oldCell != cell {
            if oldCell != Self.noCell {
                cellCounts[Int(oldCell)] -= 1
            }
            if cell != Self.noCell {
                cellCounts[Int(cell)] += 1
            }
            cellOfRow[position] = cell
        }
    }

    /// The slot of `type` in this tally, made when it is new; the no-type slot for none.
    mutating func typeSlot(_ type: FileType?) -> UInt16 {
        guard let type else {
            return Self.noType
        }
        if let slot = typeIndex[type] {
            return slot
        }
        // Fewer than 65,535 file types: MediaMetadata names a few dozen.
        let slot = UInt16(typeTable.count)
        typeTable.append(type)
        typeCounts.append(0)
        typeIndex[type] = slot
        return slot
    }

    /// The slot of `cell` in this tally, made when it is new; the no-cell slot for none.
    mutating func cellSlot(_ cell: PlaceCell?) -> UInt32 {
        guard let cell else {
            return Self.noCell
        }
        if let slot = cellIndex[cell] {
            return slot
        }
        let slot = UInt32(cellTable.count)
        cellTable.append(cell)
        cellCounts.append(0)
        cellIndex[cell] = slot
        return slot
    }

    /// The options the counts give: every kind present with its formats, and, in `language`,
    /// the countries and towns named for the counted cells, most rows first, then the name in
    /// the locale's order (ADR 0051). A cell named no country offers nothing.
    var options: CatalogFilterOptions {
        var formatsByKind: [MediaKind: Set<MediaFormatToken>] = [:]
        for (slot, type) in typeTable.enumerated() where typeCounts[slot] > 0 {
            var formats = formatsByKind[type.kind, default: []]
            if let format = type.format {
                formats.insert(format)
            }
            formatsByKind[type.kind] = formats
        }
        let kinds = formatsByKind.mapValues { $0.sorted() }
        guard let language else {
            return CatalogFilterOptions(formatsByKind: kinds)
        }
        var countryItems: [String: Int] = [:]
        var townItems: [String: [String: Int]] = [:]
        for (slot, cell) in cellTable.enumerated() where cellCounts[slot] > 0 {
            guard let named = names[cell], let country = named.country else { continue }
            countryItems[country, default: 0] += cellCounts[slot]
            if let town = named.town {
                townItems[country, default: [:]][town, default: 0] += cellCounts[slot]
            }
        }
        let countries = PlaceFilterCountry.mostItemsFirst(countryItems).map { country in
            PlaceFilterCountry(name: country, towns: PlaceFilterCountry.mostItemsFirst(townItems[country] ?? [:]))
        }
        return CatalogFilterOptions(formatsByKind: kinds, countries: countries, placeNameLanguage: language)
    }

    /// The tally with `read` taken in: each re-read row's fact replaced, and the names when it
    /// read them. False, with the tally unchanged, when a re-read row is one it did not count
    /// (`replace(_:)`).
    mutating func take(_ read: CatalogFilterOptionRows) -> Bool {
        guard replace(read.rows) else {
            return false
        }
        if let names = read.names {
            self.names = names
        }
        return true
    }
}

/// What a keyed re-read of a tally's rows gives (`CatalogStore.filterOptionsOfRows`): each
/// named row's fact now, and the cells' names when the changes moved them.
nonisolated struct CatalogFilterOptionRows: Sendable {
    let rows: [CatalogFilterOptionTally.Row]
    let names: [PlaceCell: PlaceNames]?
}
