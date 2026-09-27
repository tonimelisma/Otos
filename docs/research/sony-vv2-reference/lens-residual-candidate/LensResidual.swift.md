# LensResidual.swift

Scalar geometry reference. Coordinates use the Core Image bottom-left origin,
with integer pixel centers matching the calibration harness. This mapping does
not inspect images or infer a lens profile. The caller must enforce the scope in
`model.json`. Resample all color channels together with bilinear interpolation;
perform this once after color evaluation, before display/output conversion.

```swift
import Foundation

enum LensResidualError: Error { case unsupportedModel, invalidCoordinates }

struct LensResidual: Decodable {
    let coefficients: [Double]
    private enum CodingKeys: String, CodingKey {
        case formatVersion, referenceWidth, referenceHeight, coefficients
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .formatVersion) == 1,
              try c.decode(Int.self, forKey: .referenceWidth) == 2048,
              try c.decode(Int.self, forKey: .referenceHeight) == 1366 else {
            throw LensResidualError.unsupportedModel
        }
        coefficients = try c.decode([Double].self, forKey: .coefficients)
        guard coefficients.count == 6, coefficients.allSatisfy(\.isFinite) else {
            throw LensResidualError.unsupportedModel
        }
    }
    init(json: Data) throws { self = try JSONDecoder().decode(Self.self, from: json) }

    // Forward map: an existing Apple-corrected source point moves by this vector.
    func displacement(x: Double, y: Double, width: Int, height: Int) throws -> (Double, Double) {
        guard width > 1, height > 1, x.isFinite, y.isFinite else {
            throw LensResidualError.invalidCoordinates
        }
        let nx = (x - Double(width) / 2) / (Double(width) / 2)
        let ny = (y - Double(height) / 2) / (Double(width) / 2)
        let r = nx * nx + ny * ny, scale = Double(width) / 2048
        let c = coefficients
        let dx = scale * (c[0] + c[2] * nx + c[4] * nx * r + c[5] * nx * r * r)
        let dy = scale * (c[1] + c[3] * ny + c[4] * ny * r + c[5] * ny * r * r)
        guard dx.isFinite, dy.isFinite else { throw LensResidualError.invalidCoordinates }
        return (dx, dy)
    }

    // Inverse map for rendering an output pixel. Five fixed-point iterations
    // reproduce the measured preview renderer. Clamp to the source edge.
    func sourcePoint(x: Double, y: Double, width: Int, height: Int) throws -> (Double, Double) {
        var u = x, v = y
        for _ in 0..<5 {
            let d = try displacement(x: u, y: v, width: width, height: height)
            u = x - d.0; v = y - d.1
        }
        return (min(Double(width - 1), max(0, u)), min(Double(height - 1), max(0, v)))
    }
}
```
