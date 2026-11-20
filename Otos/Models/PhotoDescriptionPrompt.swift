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
/// What the model is asked depends on the photo, because the model writes whatever its
/// instructions mention. Measured on the owner's library (ADR 0053): instructions that spoke of
/// names and ages, sent for photos with no named face, came back with invented names ("Jasper",
/// "Aunt Per"), invented ages ("a 5-year-old and a 7-year-old") and placeholder people ("A, B,
/// and C" beside a box of fruit snacks). So a photo naming no one is described with
/// instructions that never mention names or ages; a photo whose faces are all named asks for
/// each by name and no other; and only a photo with unnamed faces too adds that everyone else
/// stays unnamed — that rule, sent where no one was unnamed, made the model drop names it was
/// given and add people who were not there.
///
/// The text is built here, once, as a value: the writer passes it to the model, and a test
/// reads exactly what the model would be told. `revision` is part of every stored
/// description's source, so a change to what the model is told writes every description
/// again.
nonisolated struct PhotoDescriptionPrompt: Equatable, Sendable {
    /// What the stored descriptions were written from; raised whenever the instructions or the
    /// facts' wording change.
    static let revision = 5

    /// What the model is asked to be for this photo (`init`).
    let instructions: String

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
        let named = faces.filter { $0.name != nil }.sorted { ($0.box.midX, $0.box.midY) < ($1.box.midX, $1.box.midY) }
        let othersUnnamed = named.count < faces.count
        instructions = Self.instructions(naming: !named.isEmpty, othersUnnamed: othersUnnamed)
        if !named.isEmpty {
            lines.append("People in the photo, by where their faces are:")
            for face in named {
                let who = face.name.map { name in face.age.map { "\(name), \($0)" } ?? name } ?? ""
                lines.append("- \(who): face \(Self.position(of: face.box)).")
            }
            if othersUnnamed {
                lines.append("Everyone else in the photo is unnamed.")
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

    /// The instructions for a photo: whether it names anyone, and whether anyone else in it is
    /// unnamed. The owner asked for "an extremely simple, matter of fact description of the
    /// image" (2026-11-19): asked for "lively, playful sentences", the model wrote "a superhero
    /// car ready for action" and "numbers and letters dancing across the screen" for a
    /// screenshot. A given age is never written: told to mention one "only when it adds
    /// something", the model wrote the owner's own age and gave unnamed children ages of its own
    /// ("Baby, 4"). Ages stay in the facts, where they tell a baby from an adult.
    static func instructions(naming: Bool, othersUnnamed: Bool) -> String {
        var parts = [
            "You write captions for photos in a family's photo library.",
            "Write one short, plain, matter-of-fact sentence that says what the photo shows.",
            "State only what is clearly visible: the main subject, what is happening, and the setting.",
            "No opinions, jokes, feelings, guesses or exclamation marks.",
            "If the photo is a screenshot or a document, say what it is and what it is about, without copying its text or numbers.",
        ]
        if naming {
            parts.append("The facts give the names of people in the photo and where their faces are: call each of them by name.")
            parts.append("Use no other names.")
            if othersUnnamed {
                parts.append("Everyone else stays unnamed and is called only what they clearly are, such as a child, a woman or another person.")
                parts.append("Never make up a name.")
            }
            parts.append("Never state anyone's age.")
        }
        parts.append("Write in English.")
        return parts.joined(separator: " ")
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
