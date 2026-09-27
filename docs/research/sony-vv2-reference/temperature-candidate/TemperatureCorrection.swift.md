# TemperatureCorrection.swift

Extract this Swift block and compile alongside the original `NativeReference.swift`. Use `init(json:)` to validate the candidate. This scalar reference preserves exact behavior; it is not an optimized full-image renderer. Alpha is preserved by the caller.

```swift
import Foundation

// Apply after the original model's final [0,1] clamp, using ORIGINAL neutral RGB
// for cube coordinates. Temperature comes from CIRAWFilter.neutralTemperature.
struct TemperatureCorrection: Decodable {
    let formatVersion: Int
    let dimension: Int
    let domain: Double
    let temperatureCenterMired: Double
    let temperatureScaleMired: Double
    let coefficients: [Double]

    private enum CodingKeys: String, CodingKey {
        case formatVersion, dimension, domain, temperatureCenterMired
        case temperatureScaleMired, coefficients
    }
    init(json: Data) throws { self = try JSONDecoder().decode(Self.self, from: json) }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        dimension = try c.decode(Int.self, forKey: .dimension)
        domain = try c.decode(Double.self, forKey: .domain)
        temperatureCenterMired = try c.decode(Double.self, forKey: .temperatureCenterMired)
        temperatureScaleMired = try c.decode(Double.self, forKey: .temperatureScaleMired)
        coefficients = try c.decode([Double].self, forKey: .coefficients)
        guard formatVersion == 1, dimension == 9, domain == 1.25,
              temperatureCenterMired == 200, temperatureScaleMired == 100,
              coefficients.count == 4374, coefficients.allSatisfy(\.isFinite) else {
            throw ReferenceError.unsupportedModel
        }
    }

    func apply(neutral: [Double], base: [Double], temperature: Double) throws -> [Double] {
        guard neutral.count == 3, base.count == 3,
              neutral.allSatisfy(\.isFinite), base.allSatisfy(\.isFinite),
              temperature.isFinite, temperature > 0 else { throw ReferenceError.invalidPixels }
        let t = (1e6 / temperature - temperatureCenterMired) / temperatureScaleMired
        guard t.isFinite else { throw ReferenceError.invalidPixels }
        let q = neutral.map { min(domain, max(0, $0)) * 8 / domain }
        let lo = q.map { min(7, Int($0)) }
        let f = zip(q, lo).map { $0 - Double($1) }
        var result = base
        for r in 0...1 { for g in 0...1 { for b in 0...1 {
            let index = (lo[0] + r) * 81 + (lo[1] + g) * 9 + lo[2] + b
            let weight = (r == 0 ? 1 - f[0] : f[0]) * (g == 0 ? 1 - f[1] : f[1]) * (b == 0 ? 1 - f[2] : f[2])
            for channel in 0..<3 {
                let offset = channel * 1458 + index
                result[channel] += weight * (coefficients[offset] + t * coefficients[offset + 729])
            }
        } } }
        return result.map { min(1, max(0, $0)) }
    }
}
```
