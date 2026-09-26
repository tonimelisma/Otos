# Reference listing: decode.swift

Archived experiment source. Paths are historical execution paths, not dependencies of the learned transform.

```swift
import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Darwin

func localData(_ path: String) throws -> Data {
    var s = stat()
    guard lstat(path, &s) == 0, (s.st_flags & 0x40000000) == 0, (s.st_mode & S_IFMT) == S_IFREG else { throw NSError(domain:"notLocal",code:1) }
    return try Data(contentsOf: URL(fileURLWithPath:path))
}
func scaled(_ im: CIImage, edge: CGFloat) -> CIImage {
    let r=im.extent
    let moved=im.transformed(by:CGAffineTransform(translationX:-r.minX,y:-r.minY))
    let factor=edge/max(r.width,r.height)
    return moved.applyingFilter("CILanczosScaleTransform",parameters:[kCIInputScaleKey:factor,kCIInputAspectRatioKey:1])
}
let args=CommandLine.arguments
let start=Date()
let rawData=try localData(args[1]); let targetData=try localData(args[2])
guard let raw=CIRAWFilter(imageData:rawData,identifierHint:"com.sony.arw-raw-image"), let target=CIImage(data:targetData,options:[.applyOrientationProperty:true]) else { fatalError("decode unavailable") }
let source=CGImageSourceCreateWithData(targetData as CFData,nil)!
let decoded=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldAllowFloat:true] as CFDictionary)!
print("target decoded bitsPerComponent=\(decoded.bitsPerComponent) bitsPerPixel=\(decoded.bitsPerPixel) space=\(String(describing:decoded.colorSpace?.name))")
let out=URL(fileURLWithPath:args[3]);try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
let edge:CGFloat=args.count>4 ? CGFloat(Double(args[4])!) : 768
let ctx=CIContext(options:[.cacheIntermediates:false,.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!])
let srgb=CGColorSpace(name:CGColorSpace.sRGB)!
let extended=CGColorSpace(name:CGColorSpace.extendedSRGB)!
var meta:[String:Any]=["decoder":raw.decoderVersion.rawValue,"supportedDecoders":raw.supportedDecoderVersions.map{$0.rawValue},"nativeWidth":raw.nativeSize.width,"nativeHeight":raw.nativeSize.height,"baselineExposure":raw.baselineExposure,"boost":raw.boostAmount,"localTone":raw.localToneMapAmount,"shadowBias":raw.shadowBias,"temperature":raw.neutralTemperature,"tint":raw.neutralTint,"lensSupported":raw.isLensCorrectionSupported,"lensEnabled":raw.isLensCorrectionEnabled,"targetColorSpace":target.colorSpace?.name as String? ?? "unknown"]
raw.scaleFactor=Float(edge/max(raw.nativeSize.width,raw.nativeSize.height))
func save(_ im:CIImage,_ name:String,_ floats:Bool=false) throws {
 let s=scaled(im,edge:edge);let w=Int(s.extent.width.rounded()),h=Int(s.extent.height.rounded());let bounds=CGRect(x:0,y:0,width:w,height:h)
 try ctx.writePNGRepresentation(of:s,to:out.appendingPathComponent(name+".png"),format:.RGBA8,colorSpace:srgb)
 if floats {
  var pixels=[Float](repeating:0,count:w*h*4)
  pixels.withUnsafeMutableBytes { b in ctx.render(s,toBitmap:b.baseAddress!,rowBytes:w*16,bounds:bounds,format:.RGBAf,colorSpace:extended) }
  try pixels.withUnsafeBytes { try Data($0).write(to:out.appendingPathComponent(name+".rgba32f")) }
 }
 meta[name+"Width"]=w;meta[name+"Height"]=h
}
guard let defaultImage=raw.outputImage else {fatalError("nil default")}
try save(defaultImage,"apple")
raw.boostAmount=0;raw.localToneMapAmount=0;raw.contrastAmount=0;raw.sharpnessAmount=0;raw.detailAmount=0
// Keep camera white balance, baseline exposure, highlight recovery and lens correction.
guard let neutral=raw.outputImage else {fatalError("nil neutral")}
try save(neutral,"neutral",true);try save(target,"target",true)
meta["seconds"]=Date().timeIntervalSince(start)
try JSONSerialization.data(withJSONObject:meta,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("decode.json"))
print(String(data:try JSONSerialization.data(withJSONObject:meta,options:[.sortedKeys]),encoding:.utf8)!)
```
