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
- **Sign: calibrated by a controlled capture.** On 2026-11-01 six iPhone 18 Pro photos of a
  plumb door frame were taken:
  - back camera held upright, rolled each way;
  - front camera held upright, rolled each way;
  - back camera held landscape (hold −90°, `x` ≈ −1), rolled each way.

  Each photo's needed turn was measured from the frame's lean and compared with its gravity
  reading, roll = `atan2(x, −y)` less the hold. The landscape leans are least-squares fits of
  the frame-to-wall edge at 1000 px (residual 0.3–0.4 px).

  | Camera | Needed turn (frame lean) | `atan2(x, −y)` less hold | Agreement |
  | --- | --- | --- | --- |
  | Back | ≈ −14° (top leans right) | −15.8° | same sign |
  | Back | positive (top leans left) | +17.0° | same sign |
  | Front | +10.9° (measured at 1000 px) | −11.2° | opposite sign, same size |
  | Front | ≈ −25° (top leans right) | +27.4° | opposite sign |
  | Back, landscape | +9.8° (top leans left) | +10.9° | same sign, within 1.1° |
  | Back, landscape | −15.5° (top leans right) | −15.0° | same sign, within 0.5° |

  - **Back camera:** straighten = `atan2(x, −y)` less the hold. This is Core Motion's
    convention (+x toward the right of the screen). Exiftool's "+x toward the left edge" is
    the misleading one.
  - **Front camera:** the sign is reversed. iOS saves front-camera photos mirrored by default
    ("Mirror Front Camera"), and the file records no tag saying whether mirroring was on, so
    a front-camera photo's sign is not knowable from its metadata.
  - **Landscape:** the same formula holds with the hold taken as the nearest quarter turn.
    Only the −90° hold was captured; the +90° hold and upside-down are the same arithmetic
    and were not measured.
  - **Earlier evidence that misled:** a bed-post selfie (front camera, so mirrored), and
    back-camera photos pointed downward, whose lines showed perspective rather than roll.
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
- **Where it belongs:** under ADR 0039 the fact belongs in the library. MediaMetadata 0.9.1
  reports it as `levelingTurnDegrees`. On the six calibration photos it reads −15.8°, +17.1°,
  +10.9° and −15.0° for the back camera, and nil for both front-camera shots.
- **Checked against Vision on the library's local photos:** 25 iPhone 15 Pro and 18 Pro photos
  where both gave a reading.
  - Only 5 agreed within 2°.
  - In the disagreements inspected, gravity was right where the scene has gravity-aligned
    structure. A child on a sofa needed +9.7°: rotating by it made the background door
    frames plumb, while Vision's −10° leaned them. In a family photo the wall outlet and
    corner were already plumb (gravity −0.7°, Vision +8.1°).
  - The rest had no level for either to find: a snack bag shot at an angle, and a ceiling
    fixture's label.
  - Gravity follows the camera, so it levels the camera's world, not a tilted subject.

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
   - Back camera only: its sign is calibrated (section 2), upright and landscape. A
     front-camera photo's sign depends on a mirroring setting the file does not record, so
     it falls back to the pixels.
   - Built: MediaMetadata 0.9.1 reports iPhone gravity. Other makers' roll tags wait for
     sample files to calibrate against.
2. **Pixels only when confident.** Vision's horizon reports confidence 1.0 on every answer, so its
   wrong answers can't be filtered out. GeoCalib reports an uncertainty that tracks its error
   (section 5), so it is the fallback when the file has no gravity reading, used only when it
   is confident. Built (ADR 0045).
3. **Do not reimplement Upright** (Adobe patents).

**Crop suggestions:**
1. The first two heuristics (Subject, Thirds) were in the weakest published class, and the
   owner judged them unproven; they are gone.
2. FocalNet (MIT, 19 MB), a small ranker trained on human crop ratings, is the one built
   (ADR 0045). GAIC's weights stay unlicensed (above), and FrameLite is too large (section 5).
3. Neither Apple's aesthetics score nor a vision-language model is a substitute.

## 5. Measured: models for the shipped Auto crop and Auto straighten (2026-11-02)

**Crop models on public benchmarks** (this Mac, M1 Pro):
- **Data:**
  - FCDB: 301 of the 345 test photos are still on Flickr, each with one human crop.
  - GAICD: the 500 test photos of the journal version, about 90 candidate crops each, scored by
    human raters.
- **Checking the harness:** FocalNet's published GAICD ranking reproduced to three decimals (rank
  correlation 0.7646, top-5 43.7%, top-10 64.6%).
- **FCDB, overlap with the human crop** (the field's IoU):
  - no crop 0.643;
  - FocalNet's own choice 0.653;
  - FocalNet's best-scored crop at 90% of the frame or tighter 0.687;
  - FrameLite 0.717, against its paper's 0.712.
- **GAICD (150 photos with a fixed seed), share within IoU 0.85 of a top-5 human crop:**
  - FrameLite 89%;
  - FocalNet's own choice 7%;
  - no crop 0%.
- **Cost:**
  - FrameLite (Qwen3.5-0.8B fine-tune): 1.9 GB and 8 s a photo here. Ruled out by the owner.
  - FocalNet: 19 MB and 0.1 s.
- **Licences:** FocalNet MIT; FrameLite Apache-2.0; ProCrop non-commercial and no-derivatives,
  and unreleased.

**Crops on the owner's photos, blind:**
- **40 varied local photos,** each crop rated 1–5:
  - uncropped averaged 3.97;
  - FocalNet 4.03, but it kept 28 of 33 essentially whole;
  - FrameLite 3.70, better than uncropped on 13 and worse on 19.
  - The owner: tight crops are fine as suggestions, since the button is optional.
- **A/B on 10 photos FocalNet did crop**, drawn from 300 random local photos: the owner judged
  them good crops.
- **How often it crops:** FocalNet cropped 45 of the 300 (15%).

**GeoCalib against calibrated gravity:**
- **Photos:** 114 local iPhone back-camera photos whose gravity reading is the truth (section 2).
- **Vision's horizon, when it answers (52%):** median error 3.27°, 34% within 2°, 22 off by more
  than 5°.
- **GeoCalib, every photo:** median 1.11°, 72% within 2°, 18 off by more than 5°.
- **GeoCalib, uncertainty at most 3° (61% of photos):** median 0.71°, 93% within 2°, none off by
  more than 5°. Its uncertainty and its real error correlate (rank 0.6).
- **Direction:** right on 34 of the 39 photos tilted 2° or more.
- **Licences:** code Apache-2.0, weights CC-BY-4.0.

**Conversion to Core ML, each checked against the reference:**
- **FocalNet at full precision:** identical to its ONNX model on all 500 GAICD photos (largest
  score difference 1e-5, the same top candidate on every photo). Half precision changed the top
  candidate on 3.6%.
- **GeoCalib's network:**
  - Core ML cannot size its upsampling from a flexible input, so it is converted per shape:
    short side 320, long side 320/416/480/544/640, both ways up, merged into one multi-function
    package sharing the weights.
  - The fields match PyTorch to 3.5e-6.
  - Its NMF block draws random starting bases on every forward pass; fixed to one seeded tensor,
    accuracy is unchanged (61% coverage, 0.71° median).
  - Half precision changed nothing measurable (0.69°) and fits GitHub's 100 MB file limit
    (58 MB of weights).
- **The Swift port of GeoCalib's solver:** against GeoCalib's own solver on the same fields for
  all 114 photos, roll differs by a median 0.0006° (largest 0.057°), with the same step count and
  the same confident-or-not decision on every photo.
- **End to end in Swift:**
  - Level: the same decision as the reference on 112 of 114, the same accuracy.
  - Crop: the same decision on 294 of 300; identical crops on all 44 both crop. The 6 others are
    borderline photos where Core Graphics and PIL resize slightly differently.
- **Compute units:**
  - On the GPU, eight concurrent predictions (as parallel tests run) deadlocked inside MPSGraph,
    every thread parked on its lock.
  - The Neural Engine refuses a function name on a multi-function model.
  - The CPU gives the same results at about the same speed: ~0.1 s a crop, ~0.35 s a level.
- **Loading:** Core ML specializes a model on its first load and caches the result per app.
  - FocalNet: 229 ms cold, 8 ms warm.
  - GeoCalib: all nine shape functions cost 15 s cold and 525 MB of cache. One function costs
    about 1.8 s and 58 MB cold, and 7 ms warm. So Otos loads a function only when a photo of
    that shape is read.

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
- FocalNet: https://huggingface.co/appwrite/focalnet · https://github.com/appwrite/focalnet
- FrameLite: https://huggingface.co/zlab-sjtu/FrameLite · https://github.com/JianzeLi-114/FrameLite
- GeoCalib: https://github.com/cvg/GeoCalib (Veicht, Sarlin, Lindenberger, Pollefeys, ECCV 2024)
- FCDB: https://github.com/yiling-chen/flickr-cropping-dataset
