import Foundation
@testable import OtosKit

extension RecognizedTextLine {
    /// A line spanning the whole picture: where it sits matters only to the status bar rule.
    init(text: String, confidence: Float) {
        self.init(text: text, confidence: confidence, box: .whole)
    }
}

extension TextReading {
    /// `lines` read in a 1,000 × 1,000 picture.
    init(_ lines: [RecognizedTextLine]) {
        self.init(width: 1000, height: 1000, lines: lines)
    }
}
