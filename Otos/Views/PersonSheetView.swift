import SwiftUI

// The Person sheet (`docs/design/people.md`): Add Name…, New Name…, Rename…, Set Birthday…
// and Someone Else… open one sheet — who is being named and how many photos Save changes,
// over a row of their faces; the name, suggesting the people who already have one; and the
// birthday as a year, or a full date with `Exact date`. A year alone counts from 1 January
// (owner decision, 2026-11-10). Save is disabled, with the reason as its tooltip, while the
// name is empty or the birthday comes after a photo the user gave the person. A name another
// person has is saved as a merge, asked first, or for faces gives them to that person.
// Passive: the context, the reason and the save are the view model's.

struct PersonSheetView: View {
    let context: PersonSheetContext
    let images: FaceTileImages?
    let derivedImageDirectory: URL?
    let refusal: (String, String?) -> String?
    let save: (String, String?) -> Void
    let cancel: () -> Void

    @State private var name: String
    @State private var year: String
    @State private var exact: Bool
    @State private var date: Date
    @Environment(\.colorScheme) private var colorScheme

    init(
        context: PersonSheetContext,
        images: FaceTileImages?,
        derivedImageDirectory: URL?,
        refusal: @escaping (String, String?) -> String?,
        save: @escaping (String, String?) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.context = context
        self.images = images
        self.derivedImageDirectory = derivedImageDirectory
        let person = context.person
        self.refusal = refusal
        self.save = save
        self.cancel = cancel
        let birthday = person?.birthday
        _name = State(initialValue: person?.name ?? "")
        _year = State(initialValue: birthday.map { String($0.prefix(4)) } ?? "")
        _exact = State(initialValue: (birthday?.count ?? 0) > 4)
        _date = State(initialValue: birthday.flatMap(PersonBirthday.seconds).map { Date(timeIntervalSince1970: $0) } ?? .now)
    }

    /// The birthday as the catalog stores it: `YYYY-MM-DD` with Exact date, `YYYY` with a
    /// year alone, nil with neither.
    private var birthday: String? {
        if exact {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let y = parts.year, let m = parts.month, let d = parts.day else { return nil }
            return String(format: "%04d-%02d-%02d", y, m, d)
        }
        let trimmed = year.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The people whose name holds what is typed, so an existing person is chosen, not
    /// retyped.
    private var suggestions: [String] {
        let typed = name.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return [] }
        return context.names.filter { $0 != typed && $0.localizedStandardContains(typed) }
    }

    var body: some View {
        let reason = refusal(name, birthday)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(context.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(DesignPalette.label(for: colorScheme))
                Text(PeopleText.count(context.photoCount, "photo"))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
            }
            if !context.faces.isEmpty {
                // Who Save names: up to eight of the faces, newest first.
                HStack(spacing: 6) {
                    ForEach(context.faces) { tile in
                        FaceTileView(tile: tile, edge: 40, isSelected: false, images: images, derivedImageDirectory: derivedImageDirectory)
                    }
                }
                .accessibilityHidden(true)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    Text("Name")
                        .font(.callout)
                        .gridColumnAlignment(.trailing)
                    TextField("Name", text: $name)
                        .labelsHidden()
                        .frame(width: 220)
                        .textInputSuggestions {
                            ForEach(suggestions, id: \.self) { suggestion in
                                Text(suggestion)
                                    .textInputCompletion(suggestion)
                            }
                        }
                }
                GridRow {
                    Text("Birthday")
                        .font(.callout)
                    HStack(spacing: 12) {
                        TextField("Year", text: $year)
                            .labelsHidden()
                            .frame(width: 64)
                            .monospacedDigit()
                            .disabled(exact)
                        Toggle("Exact date", isOn: $exact)
                        DatePicker("Exact date", selection: $date, displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.field)
                            // A birthday is a calendar date, stored as UTC midnight.
                            .environment(\.timeZone, TimeZone(identifier: "UTC") ?? .gmt)
                            .disabled(!exact)
                    }
                }
            }
            Text("Faces from before this date are never given to \(name.isEmpty ? "this person" : name).")
                .font(.subheadline)
                .foregroundStyle(DesignPalette.l3(for: colorScheme))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(name, birthday) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(reason != nil)
                    .help(reason ?? "")
            }
        }
        .padding(20)
        .frame(width: 440)
        .onChange(of: exact) { _, isExact in
            // Turning Exact date on starts from the year typed; off keeps the date's year.
            if isExact, let y = Int(year), let start = PersonBirthday.seconds(String(format: "%04d", y)) {
                date = Date(timeIntervalSince1970: start)
            } else if !isExact {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
                year = String(calendar.component(.year, from: date))
            }
        }
    }
}
