import CoreGraphics
import Foundation

/// Photo description prompt guide (ADR 0053)
///
/// What Apple's on-device language model is told beside a still's stored preview: when and
/// where it was taken, each face's place in the picture with that person's name and age, the
/// text Vision is certain of and its confident scene labels. The model sees the picture; these
/// facts tell it what it cannot see — who people are — and what Otos already knows, so it
/// names the right person at the right face and never guesses an identity.
///
/// The text is built here, once, as a value: the writer passes it to the model, and a test
/// reads exactly what the model would be told. `revision` is part of every stored
/// description's source, so a change to what the model is told writes every description
/// again.
nonisolated struct PhotoDescriptionPrompt: Equatable, Sendable {
    /// What the stored descriptions were written from; raised whenever the instructions or the
    /// facts' wording change.
    static let revision = 1

    /// What the model is asked to be: the same for every photo.
    static let instructions = """
    You write short descriptions of the photos in a family's photo library, for the family to \
    enjoy reading. Write two or three lively, warm sentences about what is happening in the \
    photo and what makes it worth remembering. When people are named, call each one by name \
    where their face is. Never name anyone who is not named, and never guess who someone is. \
    Ages help you tell people apart and choose words such as baby, toddler or grandparent; \
    mention an age only when it adds something. Describe only what is visible: do not invent \
    events, feelings or relationships. Write in English.
    """

    /// One face as the model is told of it: where it is in the picture it is shown.
    nonisolated struct Face: Equatable, Sendable {
        /// The face on the picture the model sees, as fractions from its top-left corner.
        let box: CGRect
        let name: String?
        let age: String?
    }

    /// The facts as the model reads them.
    let facts: String

    /// The facts for a still whose faces are already placed on the picture the model sees.
    init(faces: [Face], facts: PhotoDescriptionFacts) {
        var lines: [String] = []
        if let taken = Self.taken(facts) {
            lines.append(taken)
        }
        let shown = faces.sorted { ($0.box.midX, $0.box.midY) < ($1.box.midX, $1.box.midY) }
        if !shown.isEmpty {
            lines.append("People in the photo, by where their faces are:")
            for face in shown {
                let who = face.name.map { name in face.age.map { "\(name), \($0)" } ?? name } ?? "Someone not named"
                lines.append("- \(who): face \(Self.position(of: face.box)).")
            }
        }
        let text = facts.textLines.prefix(Self.maximumTextLines).joined(separator: " / ")
        if !text.isEmpty {
            lines.append("Text in the photo: \"\(String(text.prefix(Self.maximumTextLength)))\".")
        }
        if !facts.labels.isEmpty {
            lines.append("Recognized in the scene: \(facts.labels.map(Self.labelName).joined(separator: ", ")).")
        }
        self.facts = lines.joined(separator: "\n")
    }

    static let maximumTextLines = 8
    static let maximumTextLength = 300

    /// "Taken on Saturday, 18 July 2026, in the afternoon, in Espoo, Finland." — the clock
    /// where it was taken, and the place's names as the catalog holds them. Nil when neither
    /// is known.
    static func taken(_ facts: PhotoDescriptionFacts) -> String? {
        let place = [facts.town, facts.country].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
        let when = facts.capturedAt.map { time -> String in
            let date = Date(timeIntervalSince1970: time.seconds)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            let style = Date.FormatStyle(locale: Locale(identifier: "en_GB"), calendar: calendar, timeZone: .gmt)
                .weekday(.wide).day().month(.wide).year()
            return "on \(date.formatted(style)), \(partOfDay(hour: calendar.component(.hour, from: date)))"
        }
        switch (when, place.isEmpty ? nil : place) {
        case let (when?, place?): return "Taken \(when), in \(place)."
        case let (when?, nil): return "Taken \(when)."
        case let (nil, place?): return "Taken in \(place)."
        case (nil, nil): return nil
        }
    }

    static func partOfDay(hour: Int) -> String {
        switch hour {
        case 5 ..< 12: "in the morning"
        case 12 ..< 17: "in the afternoon"
        case 17 ..< 21: "in the evening"
        default: "at night"
        }
    }

    /// "at the top left", "in the middle", "at the bottom right": the third of the picture the
    /// face's centre is in, across and down.
    static func position(of box: CGRect) -> String {
        let across = box.midX < 1.0 / 3 ? "left" : box.midX > 2.0 / 3 ? "right" : nil
        let down = box.midY < 1.0 / 3 ? "top" : box.midY > 2.0 / 3 ? "bottom" : nil
        switch (down, across) {
        case let (down?, across?): return "at the \(down) \(across)"
        case let (down?, nil): return "at the \(down)"
        case let (nil, across?): return "on the \(across)"
        case (nil, nil): return "in the middle"
        }
    }

    /// A Vision label identifier as words: `blue_sky` → `blue sky`.
    static func labelName(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }

    /// A person's age on the day a photo was taken: whole years, or months under two, from a
    /// whole birthday; "about" whole years from a year alone. Nil when the photo is from before
    /// they were born, or either date is unknown.
    static func age(birthday: PersonBirthday?, at captured: CaptureLocalTime?) -> String? {
        guard let birthday, let captured else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let taken = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: captured.seconds))
        guard let year = taken.year else { return nil }
        guard let monthDay = birthday.monthDay else {
            let years = year - birthday.year
            switch years {
            case ..<0: return nil
            case 0: return "under a year old"
            case 1: return "about 1 year old"
            default: return "about \(years) years old"
            }
        }
        guard let born = calendar.date(from: DateComponents(year: birthday.year, month: monthDay.month, day: monthDay.day)),
              let day = calendar.date(from: taken)
        else {
            return nil
        }
        let span = calendar.dateComponents([.year, .month], from: born, to: day)
        guard let years = span.year, let months = span.month, day >= born else { return nil }
        switch years {
        case 0 where months == 0: return "under a month old"
        case 0, 1:
            let total = years * 12 + months
            return total == 1 ? "1 month old" : "\(total) months old"
        default: return "\(years) years old"
        }
    }
}
