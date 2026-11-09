import CoreGraphics
import Foundation
import ImageIO
@testable import OtosKit
import Testing

/// The bundled search model (ADR 0048): the tokenizer reproduces the one SigLIP 2 was trained
/// with, the int8 text path reproduces the full-precision embeddings, and the two towers
/// agree about what a picture shows.
struct SearchModelTests {
    private static let bundle = Bundle(for: CatalogWindowViewModel.self)
    private static let fixtures = SourceTree.root.appending(path: "OtosTests/Fixtures/Search")

    /// 2,682 strings — the bake-off's queries in 17 languages, their translations, dictionary
    /// words and edge cases — tokenize to exactly open_clip's ids.
    @Test func theTokenizerMatchesTheTrainedOne() throws {
        let tokenizer = try SearchTextTokenizer(bundle: Self.bundle)
        let reference = try String(decoding: Data(contentsOf: Self.fixtures.appending(path: "tokenizer-reference.tsv")), as: UTF8.self)
        var checked = 0
        var mismatches: [String] = []
        for line in reference.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            let expected = fields[1].split(separator: " ").compactMap { Int32($0) }
            if tokenizer.tokenIDs(for: String(fields[0])) != expected {
                mismatches.append(String(fields[0]))
            }
            checked += 1
        }
        #expect(checked == 2682)
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5))")
    }

    @Test func canonicalTextIsLowerCaseWithoutPunctuation() {
        #expect(SearchTextTokenizer.canonical("  Child’s  red-hat! ") == "childs redhat")
        #expect(SearchTextTokenizer.canonical("ﬁsh_tank") == "fish tank")
        #expect(SearchTextTokenizer.canonical("ＡＢＣ") == "abc")
    }

    /// The shipped text path — int8 weights and the int8 token table — gives the
    /// full-precision model's embeddings, in four scripts.
    @Test func theTextPathReproducesFullPrecision() throws {
        let tokenizer = try SearchTextTokenizer(bundle: Self.bundle)
        let model = try SearchTextModel(bundle: Self.bundle)
        let data = try Data(contentsOf: Self.fixtures.appending(path: "text-embeddings.json"))
        let reference = try JSONDecoder().decode([String: [Float]].self, from: data)
        #expect(reference.count == 4)
        for (text, expected) in reference {
            let embedding = try model.embedding(of: tokenizer.tokenIDs(for: text))
            #expect(embedding.count == SearchEmbedding.dimensions)
            #expect(Self.cosine(embedding, expected) > 0.99, "\(text)")
        }
    }

    /// A red picture is nearer "red" than "blue", and a blue one the other way: the towers
    /// share one space. The same picture embeds the same twice, at unit length.
    @Test func theTowersAgreeAboutColour() throws {
        let tokenizer = try SearchTextTokenizer(bundle: Self.bundle)
        let text = try SearchTextModel(bundle: Self.bundle)
        let image = try SearchImageModel(bundle: Self.bundle)
        let red = try image.embedding(of: Self.solid(red: 1, green: 0, blue: 0))
        let blue = try image.embedding(of: Self.solid(red: 0, green: 0, blue: 1))
        let redText = try text.embedding(of: tokenizer.tokenIDs(for: "red"))
        let blueText = try text.embedding(of: tokenizer.tokenIDs(for: "blue"))

        #expect(Self.cosine(red, redText) > Self.cosine(red, blueText))
        #expect(Self.cosine(blue, blueText) > Self.cosine(blue, redText))
        #expect(try image.embedding(of: Self.solid(red: 1, green: 0, blue: 0)) == red)
        #expect(abs(Self.cosine(red, red) - 1) < 1e-3)
    }

    /// The resize reproduces PIL's bicubic, which the model was trained and measured with,
    /// when enlarging and when shrinking: every channel within 1 of PIL's.
    @Test(arguments: [
        ("resample-source.png", "resample-pil-256.png"),
        ("resample-source-large.png", "resample-pil-256-from-large.png"),
    ])
    func theResizeIsPILsBicubic(source: String, expected: String) throws {
        let image = try Self.decode(Self.fixtures.appending(path: source))
        let square = try #require(SearchImageResampler.square(image, side: 256))
        let reference = try Self.rgb(Self.decode(Self.fixtures.appending(path: expected)))
        let got = try Self.rgb(square)
        #expect(got.count == reference.count)
        let worst = zip(got, reference).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(worst <= 1)
    }

    static func decode(_ url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// The image's values as stored, 3 bytes a pixel.
    static func rgb(_ image: CGImage) throws -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(image.colorSpace)
        rgba.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return rgba.enumerated().compactMap { $0.offset % 4 == 3 ? nil : $0.element }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
            / ((a.reduce(0) { $0 + $1 * $1 }).squareRoot() * (b.reduce(0) { $0 + $1 * $1 }).squareRoot())
    }

    static func solid(red: CGFloat, green: CGFloat, blue: CGFloat, width: Int = 320, height: Int = 240) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
