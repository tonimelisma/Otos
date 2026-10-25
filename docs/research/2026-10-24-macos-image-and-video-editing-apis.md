# macOS 27 built-in image and video editing APIs

Date: 2026-10-24. What the operating system itself provides for non-destructive
editing, so Otos's first edits can be chosen by what is built in
(`2026-10-24-editing-foundation.md`). Apple frameworks only; no third-party code.

Method: the Xcode 27 `MacOSX27.0.sdk` headers and Swift interfaces, small probes on the
development Mac (Core Image filter catalog, `autoAdjustmentFilters` on three images,
Image I/O type lists, Vision requests on a HEIC fixture), and Apple documentation.
Labels: **[H]** header or Swift interface, **[R]** run on this Mac, **[D]** Apple
documentation or session, **[I]** inference. Header paths are relative to
`System/Library/Frameworks/`.

RAW decoding with `CIRAWFilter` and RAW9 is measured separately in the editing
foundation research.

## Core Image

The runtime catalog has 252 filters [R]; `CIFilterBuiltins.h` tags none with 27.0, so
macOS 27 added no built-in filters [H].

| Area | Built-in filters | Notes |
| --- | --- | --- |
| Exposure, tone | `CIExposureAdjust` (EV), `CIGammaAdjust`, `CIToneCurve`, `CIColorCurves`, `CIHighlightShadowAdjust`, `CIColorControls` (saturation, brightness, contrast) | `CIToneCurve` takes exactly five points (`CIFilterBuiltins.h:732-747`) [H]; `CIHighlightShadowAdjust` has radius, shadow amount, highlight amount (`:2015`) [H] |
| White balance | `CITemperatureAndTint` (neutral → target neutral, `:720`), `CIWhitePointAdjust` | A relative shift on rendered pixels, not sensor white balance |
| Colour | `CIVibrance` (skin-preserving, `:764`), `CIHueAdjust`, `CIColorMatrix`, `CIColorPolynomial`, `CIColorMonochrome`, `CISepiaTone`, Lab conversions | |
| LUT | `CIColorCube`, `CIColorCubeWithColorSpace`, `CIColorCubesMixedWithMask` | |
| Preset looks | `CIPhotoEffect` Chrome, Fade, Instant, Mono, Noir, Process, Tonal, Transfer | |
| Sharpen, noise | `CISharpenLuminance`, `CIUnsharpMask`, `CINoiseReduction` (`:2305`), `CIMedianFilter` | `CINoiseReduction` is a simple threshold blur |
| Geometry | `CICrop`, `CIAffineTransform`, `CIStraightenFilter`, `CIPerspectiveCorrection`, `CIPerspectiveTransform`, `CIKeystoneCorrection*`, `CILanczosScaleTransform` | |
| Lens | `CICameraCalibrationLensCorrection` | Needs capture-time `AVCameraCalibrationData` [R]; not a lens-profile database |
| Vignette | `CIVignette`, `CIVignetteEffect` | |
| Blur, edge-aware | Gaussian, box, disc, bokeh, motion, masked variable, depth blur; `CIGuidedFilter`, `CIEdgePreserveUpsampleFilter` | |
| Blend, gradients | 30 blend modes, `CIBlendWithMask`; linear, radial, Gaussian, distance gradients | |
| Analysis | `CIAreaHistogram`, `CIAreaLogarithmicHistogram`, `CIAreaAverage`, `CIAreaMinMax`, `CIHistogramDisplayFilter` | A histogram is built in |
| HDR | `CIToneMapHeadroom` (15), `CISystemToneMap` (26) | |
| ML | `CICoreMLModelFilter` | Runs a supplied model |

`CIImage.autoAdjustmentFilters(options:)` returned `CIFaceBalance`, `CIVibrance`, a
five-point `CIToneCurve` and `CIHighlightShadowAdjust` on the three test images, plus
`CICrop` only with the crop option [R]. The options are Enhance, RedEye, Features, Crop
and Level (`CIImage.h:746-780`) [H]. The results are ordinary filter parameters, so an
auto adjustment can be stored as recipe values. `CIFaceBalance` and `CIRedEyeCorrection`
can be created by name but are not in the public catalog [R].

HDR [H]: `kCIImageExpandToHDR` and `imageByApplyingGainMap` read HDR; `contentHeadroom`
describes it; `kCIImageRepresentationHDRImage` (`CIContext.h:748`) writes a gain map
when saving JPEG or HEIF. macOS 27 adds `CIRenderTask` render planning with peak-memory
estimates (`CIRenderDestination.h:232-334`) and tiled `CIImageProcessorKernel` options
[H].

## Image I/O

| Read and write | Read only |
| --- | --- |
| JPEG, PNG, TIFF, HEIC/HEICS, AVIF, JPEG 2000, OpenEXR, PSD, GIF, BMP | JPEG XL, WebP, DNG and camera RAW, HEIF (generic), Radiance, DICOM |

[R, `CGImageSourceCopyTypeIdentifiers` / `CGImageDestinationCopyTypeIdentifiers`]

- ISO gain-map HDR: read with `kCGImageSourceDecodeToHDR` / `ToSDR`; write with
  `kCGImageDestinationEncodeToISOHDR` / `ToISOGainmap` / `ToSDR` (`CGImageDestination.h:404-423`) [H].
- Auxiliary images (depth, disparity, portrait matte, semantic mattes) read and write
  [H].
- Metadata: `CGImageDestinationCopyImageSource` copies an image with edited metadata
  losslessly, with exclude-GPS and exclude-XMP options [H]. Otos never writes originals,
  so this matters only for export.
- macOS 27 adds `kCGImageSourceAllowableTypes` and `kCGImageSourcePrioritizeQuality` [H].

## Vision (analysis; produces values or masks, never edited pixels)

| Request | Output |
| --- | --- |
| `DetectHorizonRequest` | Angle and transform (straighten suggestion) [H] |
| Attention / objectness saliency | Heat map, salient boxes [H, R] |
| `GenerateForegroundInstanceMaskRequest`, person segmentation and instance masks | Subject or person masks [H, R] |
| `CalculateImageAestheticsScoresRequest` | `overallScore`, `isUtility` [H, R] |
| Face rectangles, landmarks, capture quality | [H] |
| Rectangles, document segmentation | Quadrilaterals for perspective correction [H] |
| `DetectLensSmudgeRequest` (26) | Confidence [H, R] |
| `GenerateIterativeSegmentationRequest` (27) | Mask from a tap, box or scribble; its model downloads on demand (`assetStatus = notReady` here) [H, R; D: [WWDC26 237](https://developer.apple.com/videos/play/wwdc2026/237)] |

VisionKit's `ImageAnalysisOverlayView` offers subject lifting as a UI overlay [H].
Core ML and the new Core AI framework are model runtimes and ship no image models [H].

## Pixel primitives

- **vImage** [H]: histogram, equalization and specification; convolution including
  Richardson–Lucy deconvolution; morphology; scaling and warps; any-to-any colour
  conversion.
- **Metal Performance Shaders** [H]: Gaussian, median and guided filters; histogram;
  Sobel and Canny; Gaussian and Laplacian pyramids; Lanczos scaling.

## Colour and EDR display [H]

`CGColorSpace` covers sRGB, Display P3, Adobe RGB, ITU-R 2020, the extended and linear
variants, and 2100 PQ/HLG. `NSScreen` reports current and potential EDR headroom;
`CAMetalLayer.wantsExtendedDynamicRangeContent` and `CALayer.preferredDynamicRange`
(26) display it. Apple's EDR pattern is an `MTKView` with an `rgba16Float` drawable
rendered through `CIRenderDestination`
([WWDC22 10114](https://developer.apple.com/videos/play/wwdc2022/10114/)) [D].

## Not available as API

No public Clean Up / object removal and no Photos-style Enhance beyond
`autoAdjustmentFilters`; Image Playground generates illustrations, not photo edits [H,
searched every framework header and interface].

## Video

| Edit | API | Constraint |
| --- | --- | --- |
| Trim | `AVMutableComposition.insertTimeRange(_:of:at:)` async (`AVComposition.h:224`); `AVAssetExportSession.timeRange` | [H] |
| Built-in trim UI | `AVPlayerView.beginTrimming() async -> .okButton / .cancelButton` (`AVPlayerView.h:220-239`) | Modal; how the chosen range is reported is not stated in the header or doc [H; I: `forwardPlaybackEndTime`] |
| Rotate, flip, crop | Layer-instruction transform and crop rectangle, `renderSize` (Swift `Configuration` structs, macOS 26) | The mutable composition classes are deprecated in 26 [H] |
| Per-frame Core Image | `AVVideoComposition(applyingFiltersTo:applier:)` (macOS 26) | Only the first enabled video track; render size fixed to the source; rotation must happen inside the handler [H] |
| Live preview | `AVPlayerItem.videoComposition` | The same composition drives playback, poster frames and export [H] |
| Speed | `scaleTimeRange(_:toDuration:)` | Retiming only; no frames synthesized [H] |
| Poster frame | `AVAssetImageGenerator.image(at:)` honouring `videoComposition`; `dynamicRangePolicy` `.forceSDR` / `.matchSource` | [H] |
| Export | `AVAssetExportSession.export(to:as:)`; HEVC, H.264, ProRes presets; resumable export (new in 27) | [H] |
| HDR | PQ/HLG transfer constants; composition colour properties; `CISystemToneMap` for explicit SDR | Preserving Dolby Vision through an edited export is [I] |
| Frame interpolation, motion blur, temporal noise filter, super resolution | VideoToolbox `VTFrameProcessor` (15.4 / 26) | Pixel buffers in and out; not an `AVVideoComposition` plug-in; super resolution input at most 1920 wide on macOS [H] |
| Cinematic focus | Cinematic `CNScript`, `CNRenderingSession`; macOS 27 preprocessing writes a new asset | [H] |
| Stabilization | **None** for existing files; only capture-time modes | [H, searched AVFoundation, VideoToolbox, Core Image, Vision, Cinematic, AVKit, Core Media] |

## Summary

Built in and mapping directly to a global photo adjustment: exposure, white balance
(RAW: sensor temperature/tint; other formats: relative temperature/tint), contrast,
highlights/shadows, vibrance, saturation, brightness, a five-point tone curve, crop,
rotate, flip, straighten, perspective, sharpening, basic noise reduction, vignette, LUTs
and preset looks, histogram, auto adjustment, HDR tone mapping and gain-map export;
and, for RAW only, the `CIRAWFilter` controls the decoder supports.

Needing Otos's own algorithm on top of these: free-form or per-channel curves beyond
five points, a hue-band colour mixer, clarity, texture, dehaze, whites/blacks, film
grain, lens correction for non-RAW files, local masks, retouch, and applying Vision's
suggestions (horizon, crop) as edits.

For video, trim, rotate, crop, per-frame colour, speed and poster frames are built in;
stabilization is not.
