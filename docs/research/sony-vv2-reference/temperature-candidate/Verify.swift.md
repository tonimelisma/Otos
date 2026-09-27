# Verify.swift

Extract as `main.swift`; compile with the original `NativeReference.swift` and the candidate `TemperatureCorrection.swift`. Arguments: original model JSON, candidate model JSON, candidate synthetic fixtures. No photographs required.

```swift
import Foundation
let args=CommandLine.arguments
let model=try LookModel(json:Data(contentsOf:URL(fileURLWithPath:args[1])))
let correction=try TemperatureCorrection(json:Data(contentsOf:URL(fileURLWithPath:args[2])))
let fixtures=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[3]))) as! [String:Any]
let vectors=fixtures["vectors"] as! [[String:Any]]
var maximum=0.0
for v in vectors {
 let x=v["input"] as! [Double],temperature=v["temperature"] as! Double
 let actual=try correction.apply(neutral:x,base:model.evaluateRGB(x),temperature:temperature)
 let expected=v["expected"] as! [Double]
 for c in 0..<3 {maximum=max(maximum,abs(actual[c]-expected[c]))}
}
guard maximum<=1e-12 else{fatalError("Candidate conformance failed")}
for temperature in [0.0,-1.0,Double.nan,Double.infinity] {
 do {_ = try correction.apply(neutral:[0.2,0.3,0.4],base:[0.2,0.3,0.4],temperature:temperature);fatalError("Invalid temperature accepted")} catch ReferenceError.invalidPixels {}
}
var bad = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [String: Any]
for (key, value) in [("dimension", 8 as Any), ("coefficients", [0.0] as Any), ("formatVersion", 2 as Any)] {
 var malformed = bad; malformed[key] = value
 do {
  _ = try JSONDecoder().decode(TemperatureCorrection.self, from: JSONSerialization.data(withJSONObject: malformed))
  fatalError("Malformed model accepted")
 } catch ReferenceError.unsupportedModel {}
}
for pixels in [[Double.nan, 0.2, 0.3], [0.2, 0.3]] {
 do { _ = try correction.apply(neutral: pixels, base: [0.2,0.3,0.4], temperature: 5000); fatalError("Invalid RGB accepted") } catch ReferenceError.invalidPixels {}
}
print("op=candidate.verify cases=\(vectors.count) maximumError=\(maximum) invalidTemperature=rejected malformedModels=rejected invalidRGB=rejected")
```
