import SwiftUI

// The Person sheet (`docs/design/people.md`): Add Name…, Rename…, Set Birthday… and
// New Person… open one sheet — the name, and the birthday as a year, or a full date with
// `Exact date`. A year alone counts from 1 January (owner decision, 2026-11-10). Save is
// disabled, with the reason as its tooltip, while the name is empty or the birthday comes
// after a photo the user gave the person. A name another person has is saved as a merge,
// asked first. Passive: the reason and the save are the view model's.

struct PersonSheetView: View {
    /// The person's name and birthday as they are; nil for New Person….
    let person: PersonSummary?
    let refusal: (String, String?) -> String?
    let save: (String, String?) -> Void
    let cancel: () -> Void

    @State private var name: String
    @State private var year: String
    @State private var exact: Bool
    @State private var date: Date
    @Environment(\.colorScheme) private var colorScheme

    init(
        person: PersonSummary?,
        refusal: @escaping (String, String?) -> String?,
        save: @escaping (String, String?) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.person = person
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

    var body: some View {
        let reason = refusal(name, birthday)
        VStack(alignment: .leading, spacing: 16) {
            Text(person?.displayName ?? "New Person")
                .font(.title3.weight(.semibold))
                .foregroundStyle(DesignPalette.label(for: colorScheme))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    Text("Name")
                        .font(.callout)
                        .gridColumnAlignment(.trailing)
                    TextField("Name", text: $name)
                        .labelsHidden()
                        .frame(width: 220)
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
