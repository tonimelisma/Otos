# Auto straighten and crop suggestions: what to build on

Date: 2026-11-01. Question: are Apple's built-in APIs good enough for auto straighten
and crop suggestions, should Otos adopt a published algorithm, or should it write its
own? And can camera metadata stand in for analyzing the pixels?

The first versions shipped in #541 and #542 were built on API documentation alone:
- Auto straighten: Vision's `VNDetectHorizonRequest`.
- Crop suggestions: Vision saliency plus two placement heuristics.

This note supplies the measurement and the literature they lacked.

## 1. Measured: Vision horizon and Core Image auto-level on real photos

Setup:
- **Photos:** 40 photos picked at random from the Camera Roll library, local files only (no
  dataless placeholders, so nothing was downloaded). The mix is 24 iPhone (11 Pro, 15 Pro,
  18 Pro), 5 Sony ILCE-6700, 4 Ray-Ban Meta, and 7 without make metadata.
- **Size:** each was decoded at 1024 px.
- **Tilts:** each was turned by 0°, ±3° and ±6°, scaled to fill its frame.
- **Accuracy measure:** the readings' *differences* across tilts, scored against the known
  differences. This measures precision without needing to know each photo's true level.

| Measure | Vision `VNDetectHorizonRequest` | Core Image `autoAdjustmentFilters(.level)` |
| --- | --- | --- |
| Photos with a horizon at 0° | 19 / 40 | same 19 |
| Detection stable across all 5 tilts | 4 / 40 photos | — |
| Relative angle error, median | 0.25° | 0.25° |
| Within 1° | 84% | 87% |
| Worst | 8.0° | 7.1° |
| Agrees with Vision on whether there is a horizon | — | 190 / 200 |

Findings:
- Core Image's `.level` returns a `CIAffineTransform` plus a `CICrop`, not a straighten
  filter.
- `.level`'s angle equals Vision's (median difference 0.00°), so it is the same estimator
  and not a second opinion.
- `confidence` is always 1.0 when a horizon is returned (survey probe), so the only
  "no horizon" signal is a missing result.
- **False readings on everyday photos:**
  - I inspected four photos for which Vision reported a 5–9° tilt as shot: a selfie by a
    window, a child on stairs, a mirror selfie, and a wide-angle room.
  - None has a horizon. Three are visibly level, by their window frame, shelf uprights,
    or the phone's own gravity reading.
  - So Vision is precise when the photo has a real horizon. On photos without one it returns
    confident wrong angles that nothing can filter.

## 2. Measured: camera metadata

- **iPhone:** iPhones write the gravity vector at capture into Apple's maker note
  (`AccelerationVector`, in g, in the device's frame; read here with exiftool).
  - 24 of the 40 photos carry it.
  - 20 of those were held within about 45° of upright (`hypot(x, y) ≥ 0.7`).
  - In the other three the phone pointed nearly straight up or down, which leaves roll
    undefined.
- **How roll is derived:** the angle of gravity in the device's x–y plane, less the
  nearest quarter turn (how the phone was held).
- **Checked against the photos Vision misread:**

  | Photo | Vision (as shot) | Gravity |
  | --- | --- | --- |
  | Child on stairs | +6.9° | −0.2° |
  | Mirror selfie | −5.3° | +0.4° |
  | Window selfie | −9.1° | +2.6° |

  Gravity agrees with what the photos show.
- **Sign:** straighten = `atan2(−x, −y)` less the hold, so a positive straighten turns
  clockwise. Confirmed on **one** photo, where a bed post leans the way the gravity
  reading predicts (9° from gravity against about 12° visible, with downward pitch adding
  perspective). One data point is not enough; the sign and frame need a fixture test with
  a known iPhone capture.
- **Other cameras:**
  - The Sony ILCE-6700 files carry no level reading. Neither do the Ray-Ban Meta files.
  - Olympus/OM System, Panasonic and Canon write a roll angle from their electronic level;
    DJI drones write gimbal roll in XMP. This is exiftool's tag documentation, not measured
    here.
- **Limit:** gravity gives the camera's roll, not the scene's. A photo taken lying down, or
  looking down at a table, is not aligned with gravity, and levelling it to gravity would
  be wrong. The pitch gate removes the looking-down case; lying down remains a case where
  Auto is wrong and is one undo away. Lightroom's line-based Auto has the same exposure on
  deliberately tilted shots.
- **Where it belongs:** MediaMetadata (as of `2c5bbb1`) reads neither `AccelerationVector` nor any roll
  tag. Under ADR 0039 the fact belongs in the library.

## 3. Literature and ready-made models

### Straightening

- **Lightroom Upright:** Lee, Shechtman, Wang and Lee, "Automatic Upright Adjustment of
  Photographs" (CVPR 2012; TPAMI 2014) is the work POSTECH says it transferred to Lightroom.
  - Adobe holds the patents US 9,008,460 and US 9,582,855 on it, so it must not be
    reimplemented.
  - Measured roll accuracy (Perspective Fields, Table 4): mean 6.19°, median 0.43°. It is
    precise when it works, with a long tail.
- **GeoCalib** (Veicht et al., ECCV 2024): the strongest option that may be shipped.
  - Licence: code Apache-2.0, weights CC-BY-4.0.
  - Median roll error 0.28–0.43° on four benchmarks, AUC@10° 89.8–95.0.
  - Returns roll and pitch with uncertainties that track the real error. That gives a
    principled "no suggestion", which Vision lacks.
  - Converting it to Core ML is untried, and its least-squares optimisation step would need
    porting to Swift.
- **Cannot be shipped:** Perspective Fields (non-commercial licence), DeepCalib (no licence).
- **Horizon Lines in the Wild:** the dataset and model licence could not be read.

### Crop suggestions

- **Heuristic and saliency croppers score worst on every benchmark:**
  - The eDN saliency window scores an FCDB IoU of 0.486, against 0.638 for not cropping at
    all (A2-RL, Table 1).
  - smartcrop.js scores a GAICD Acc1/5 of 6.6 (CROP, Table 2).
  - Otos's two heuristics are in this class. They were not measured here.
- **A general aesthetics score cannot rank crops of one photo:**
  - On GAICD, models trained on general aesthetics are no better than "take the largest
    crop" (Acc1/5 24.5; GAIC TPAMI, Table 5).
  - So Vision's `CalculateImageAestheticsScoresRequest` cannot rank them either. In the survey
    probe its score also moved about 0.06 under ±5° turns of the same photo.
- **GAIC fits best** (Zeng et al., CVPR 2019 / TPAMI 2020):
  - Grid-anchor candidates, scored and ranked.
  - The aspect ratio constrains the candidates.
  - Acc1/5 62.5, under 2.5M parameters, 6–12 frames/s on a CPU.
  - **Blocker:** the official weights carry no licence. The PyTorch repository's MIT notice is
    inherited from ssd.pytorch. Using it needs the authors' written permission, or
    retraining on GAICD once the dataset's terms are checked.
- **CACNet:** scores higher (Acc1/5 68.8), but returns a single crop and has no official
  code.
- **Vision-language models:** current models (Cropper with Gemini, CROP on a fine-tuned
  Qwen2.5-VL-7B) reach Acc1/5 86–89. They need a cloud model or a 7B on-device model, and
  zero-shot they are poor (GPT-5: 26.9). They are not an option for a local editor.
- **Apple:** Apple publishes no crop-ranking API. The WWDC26 saliency cropping sample crops
  to the most prominent salient box, which is less than Otos already does. Core Image's
  `.crop` crops around faces. Photos' own Auto is not exposed (`PHAdjustmentData` carries
  only an app's own data).
- **Competitors:**
  - Lightroom's crop Auto only straightens. Adobe has not shipped crop suggestions; a
    September 2025 moderator post folds the requests into a future evaluation.
  - Capture One 16.4 has AI Crop, which places by faces or subject.
  - Photos' Auto crops and straightens; how it works is unpublished.

## 4. Conclusions

**Auto straighten:**
1. **Metadata first.** Read the camera's own level from MediaMetadata: iPhone gravity, and the
   roll tags other makers write. Use it when the camera was held within about 45° of
   upright.
   - On the photos tested it was right where Vision was wrong, it costs no pixel analysis,
     and it is what the camera knew.
   - Before it ships, its sign and frame need a fixture test with a known capture.
2. **Pixels second.**
   - Vision's horizon stays only as the fallback for photos with no level reading, because it
     misreads photos without a horizon.
   - Replacing it with GeoCalib is the evidence-backed upgrade. Per the measure-first rule,
     that decision waits for a labelled comparison on Otos's own photos.
3. **Do not reimplement Upright** (Adobe patents).

**Crop suggestions:**
1. The current two heuristics are in the weakest published class.
2. The evidence points to GAIC-style ranked candidates, blocked on its weights' licence.
3. Neither Apple's aesthetics score nor a vision-language model is a substitute.

## Sources

**Apple**
- `DetectHorizonRequest`: https://developer.apple.com/documentation/vision/detecthorizonrequest
- Core Image `.level`: https://developer.apple.com/documentation/coreimage/ciimageautoadjustmentoption/level
- Core Image `.crop`: https://developer.apple.com/documentation/coreimage/ciimageautoadjustmentoption/crop
- Aesthetics scores: https://developer.apple.com/documentation/vision/calculateimageaestheticsscoresrequest
- WWDC26 saliency cropping: https://developer.apple.com/documentation/vision/implementing-saliency-based-image-cropping-in-ios-and-watchos
- WWDC26 session 237: https://developer.apple.com/videos/play/wwdc2026/237/
- Photos crop and straighten: https://support.apple.com/guide/photos/pht13f0918f0/mac

**Upright**
- Lee et al. 2012: https://research.adobe.com/publication/automatic-upright-adjustment-of-photographs
- POSTECH technology transfer: https://cg.postech.ac.kr/our-research/
- US 9,008,460: https://uspto.report/patent/grant/9008460
- US 9,582,855: https://patentimages.storage.googleapis.com/ad/ff/90/5746172a2060db/US9582855.pdf

**Calibration models**
- Perspective Fields: https://arxiv.org/abs/2212.03239 · https://github.com/jinlinyi/PerspectiveFields
- GeoCalib: https://arxiv.org/abs/2409.06704 · https://github.com/cvg/GeoCalib
- DeepCalib: https://github.com/alexvbogdan/DeepCalib
- Horizon Lines in the Wild: https://arxiv.org/abs/1604.02129

**Cropping**
- GAIC: https://arxiv.org/abs/1909.08989 · https://github.com/HuiZeng/Grid-Anchor-based-Image-Cropping-Pytorch
- A2-RL: https://arxiv.org/abs/1709.04595
- Cropper: https://arxiv.org/abs/2408.07790
- CROP: https://arxiv.org/abs/2605.12545
- CACNet (unofficial port): https://github.com/bo-zhang-cs/CACNet-Pytorch
- Capture One AI Crop: https://support.captureone.com/hc/en-us/articles/18155069152797
- Adobe AI crop request: https://community.adobe.com/feature-requests-676/p-ai-use-ai-to-recommend-composition-and-crop-images-664791

**Metadata**
- exiftool Apple tags (`AccelerationVector`): https://exiftool.org/TagNames/Apple.html
