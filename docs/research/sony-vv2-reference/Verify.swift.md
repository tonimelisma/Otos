# Verify.swift

Standalone Apple-native reference listing. Extract the Swift block to the named file to compile; the verification entry point must be named `main.swift` in its own directory. No training media or third-party libraries are required.

```swift
import Foundation

let args = CommandLine.arguments
let modelData = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let model = try LookModel(json: modelData)
let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [String: Any]
let vectors = fixture["vectors"] as! [[String: Any]]
var cpuError = 0.0
var input = [Float]()
for vector in vectors {
    let rgb = vector["input"] as! [Double]
    let expected = vector["expected"] as! [Double]
    let actual = try model.evaluateRGB(rgb)
    for channel in 0 ..< 3 {
        cpuError = max(cpuError, abs(actual[channel] - expected[channel]))
    }
    input.append(contentsOf: rgb.map(Float.init)); input.append(1)
}

let metal = try MetalLook(model: model)
let output = try metal.apply(input)
var gpuError = 0.0
for (index, vector) in vectors.enumerated() {
    let expected = vector["expected"] as! [Double]
    for channel in 0 ..< 3 {
        gpuError = max(gpuError, abs(Double(output[index * 4 + channel]) - expected[channel]))
    }
    guard output[index * 4 + 3] == 1 else { fatalError("Alpha changed") }
}

guard cpuError <= 1e-12, gpuError <= 2e-6 else { fatalError("Numerical conformance failed") }
for bad in [[Double.nan, 0, 0], [Double.infinity, 0, 0], [0, 0]] {
    do { _ = try model.evaluateRGB(bad); fatalError("Invalid RGB accepted") } catch ReferenceError.invalidPixels {}
}

var object = try JSONSerialization.jsonObject(with: modelData) as! [String: Any]
object["formatVersion"] = 999
let future = try JSONSerialization.data(withJSONObject: object)
do { _ = try LookModel(json: future); fatalError("Future format accepted") } catch ReferenceError.unsupportedModel {}
object["formatVersion"] = 1; object["residualLUT"] = []
do { _ = try LookModel(json: JSONSerialization.data(withJSONObject: object)); fatalError("Malformed cube accepted") } catch ReferenceError.unsupportedModel {}
print("op=reference.verify vectors=\(vectors.count) cpuMaxError=\(cpuError) metalMaxError=\(gpuError) invalidInputs=rejected futureFormat=rejected malformedCube=rejected")
```
