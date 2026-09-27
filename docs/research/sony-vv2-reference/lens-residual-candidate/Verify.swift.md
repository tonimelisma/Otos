# Verify.swift

Extract as `main.swift` and compile with `LensResidual.swift`. Arguments are model
JSON and synthetic fixtures JSON. No images or graphics framework are required.

```swift
import Foundation
let args = CommandLine.arguments
let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let model = try LensResidual(json: data)
let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [String: Any]
let vectors = json["vectors"] as! [[String: Any]]
var maximum = 0.0
for v in vectors {
    let p = v["point"] as! [Double], w = v["width"] as! Int, h = v["height"] as! Int
    let d = try model.displacement(x: p[0], y: p[1], width: w, height: h)
    let s = try model.sourcePoint(x: p[0], y: p[1], width: w, height: h)
    let actual = [d.0, d.1, s.0, s.1]
    let expected = (v["displacement"] as! [Double]) + (v["sourcePoint"] as! [Double])
    for (a, e) in zip(actual, expected) { maximum = max(maximum, abs(a - e)) }
}
precondition(maximum < 1e-10)
for point in [(Double.nan, 0.0, 2048, 1366), (0.0, 0.0, 1, 1366)] {
    do {
        _ = try model.sourcePoint(x: point.0, y: point.1, width: point.2, height: point.3)
        fatalError("Invalid input accepted")
    } catch LensResidualError.invalidCoordinates {}
}
var bad = try JSONSerialization.jsonObject(with: data) as! [String: Any]
bad["coefficients"] = [0.0]
do {
    _ = try JSONDecoder().decode(LensResidual.self, from: JSONSerialization.data(withJSONObject: bad))
    fatalError("Malformed model accepted")
} catch LensResidualError.unsupportedModel {}
print("op=lens.verify cases=\(vectors.count) maximumError=\(maximum) invalidInputs=rejected malformedModel=rejected")
```
