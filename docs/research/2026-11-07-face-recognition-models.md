# Face recognition: which embedding model tells the owner's children apart

Date: 2026-11-07 to 2026-11-09. Question: which face-embedding model, at which precision, should
Otos use so that one child is recognised across years while siblings at the same age stay apart?
And what must detection and alignment reject before a face reaches the model?

**Answer:** AdaFace IR-101 (WebFace12M), with 8-bit weights, on the CPU. On the owner's labelled
faces it was the only candidate that never mistook one child for a sibling, and it found every
child face the grouping had missed. Decision: ADR 0047.

The research material lives in `~/Development/Otos-face-research`, outside the repository on
purpose. It is about 2 GB of models plus crops of the owner's family, and is never committed.
This note keeps the method and the numbers. The tools named below are in that folder's `tools/`.

## 1. Pipeline measured

- **Detection, landmarks and quality:** Apple Vision (`VNDetectFaceLandmarksRequest`,
  `VNDetectFaceCaptureQualityRequest`), on the full-resolution original. No public Apple API
  returns a face embedding.
- **Alignment:** a least-squares similarity transform from five Vision points to the standard
  ArcFace 112 × 112 template. The points are the two eye centres, the lowest nose-crest point,
  and the two outer-lip corners.
- **Embedding:** one of four converted Core ML models. Each takes the 112 × 112 RGB crop, with
  the normalisation x / 127.5 − 1 folded into the image input, and returns a unit-length 512-d
  `embedding`. Similarity is the cosine.

| Model | Training data | Licence | fp32 MB | fp16 MB | int8 MB |
| --- | --- | --- | --- | --- | --- |
| ArcFace R50 (InsightFace `buffalo_l` `w600k_r50`) | WebFace600K | InsightFace models: non-commercial research only | 175 | 87 | 44 |
| ArcFace R100 (InsightFace `antelopev2` `glintr100`) | Glint360K | InsightFace models: non-commercial research only | 261 | 131 | 66 |
| AdaFace IR-50 (CVLFace) | WebFace4M | code MIT; weights follow the training dataset's licence | 175 | 87 | 44 |
| AdaFace IR-101 (CVLFace) | WebFace12M | code MIT; weights follow the training dataset's licence | 261 | 131 | 66 |

**Licences:**
- **Sources:** InsightFace's model zoo says its models are "available for non-commercial
  research purposes only". The CVLFace and AdaFace repositories are MIT, a licence that covers
  only "the Software". The AdaFace IR-101 model card says to "follow the license of the training
  dataset", and to cite the AdaFace paper (Kim et al., CVPR 2022, arXiv 2204.00964).
- **Unread:** WebFace260M's own terms page (face-benchmark.org) could not be read on 2026-11-09,
  because its TLS certificate does not match the host name.
- **Owner decision (2026-11-07):** Otos is non-commercial, so non-commercial licences are
  acceptable.

## 2. Conversion

- **Sources:** ArcFace was converted from ONNX through `onnx2torch`, and AdaFace from its PyTorch
  weights, both with coremltools 9.0 (`tools/convert.py`).
- **fp32 check:** on 32 synthetic inputs, every fp32 conversion matched its reference exactly
  (ONNX Runtime for ArcFace, PyTorch for AdaFace).
- **int8:** the int8 variants are the fp32 packages with linear symmetric per-channel 8-bit
  weights (`coremltools.optimize.coreml.linear_quantize_weights`, `tools/quantize.py`).

Milliseconds per face on an M1 Pro, with the worst pairwise-similarity error against the
reference in parentheses (synthetic input, idle machine):

| Model | fp32 CPU | fp16 CPU | fp16 CPU + Neural Engine |
| --- | --- | --- | --- |
| ArcFace R50 | 19.5 | 10.5 (0.007) | 4.3 (0.022) |
| ArcFace R100 | 29.9 | 16.2 (0.014) | 4.7 (0.038) |
| AdaFace IR-50 | 22.1 | 13.9 (0.010) | 3.9 (0.002) |
| AdaFace IR-101 | 44.9 | 26.1 (0.044) | 4.7 (0.003) |

Half precision errs differently on each engine: AdaFace is ten times worse on the CPU than on the
Neural Engine, and ArcFace is the reverse. Section 6 checks which of these errors change a real
decision.

**AdaFace IR-101 alone, CPU only, measured in Swift** (`MLModel`, 100 predictions after one
warm-up, 2026-11-09, on a machine running other work, load average 16–25):

| Weights | Compile and load | ms per face |
| --- | --- | --- |
| int8 | 0.6 s | 33 |
| fp16 | 1.0 s | 20 |
| fp32 | 1.8 s | 34 |

## 3. Detection on the owner's photos

**Run 1** (142 local 2026 photos, 222 faces):
- Faces are large: median 602 px tall at full resolution, p10 309 px.
- Shrinking to a 1024 or 2048 px long edge lost no detections.
- About 1.5 s per photo, mostly full-resolution decode.

**Run 2**, the bake-off set:
- **Photos:** 400 a year drawn at random from each of 2012–2026, from the owner's archive
  `Camera Roll` on the home server. That came to 5,810 JPEG, HEIC and DNG photos (some years
  hold fewer), read at full resolution, with eight photos in parallel, in 25 minutes.
- **Faces:** Vision found 4,449. 3,293 have capture quality ≥ 0.3, the admission rule used
  throughout this study. Their median height is 502 px.
- **Capture dates:**
  - 3,893 from EXIF;
  - 331 from a `YYYY-MM-DD` folder name;
  - 225 from a year folder only, dated 1 July.

**Broken alignments:** 59 of the 3,293 faces had landmarks spread across the scene instead of
one face. Their alignment shrinks the whole photo into the crop (a table of diners, a framed
picture), and those crops score up to 0.88–0.94 against each other. The check that separates them
is the face box height in pixels times the alignment scale, which for a real face is about the
template's face height:

| box height × scale | faces |
| --- | --- |
| < 50 | 59, all broken crops or whole scenes |
| 50–150 | 3,232; real faces, except at 50–60, where real profile faces mix with broken crops (p5 75, median 93, p99 108) |
| > 150 | 2: a shoe and a painting |

**Rule:** accept a face only when this product is between 50 and 150. That rejects 61 of 3,293
detections (1.9%).

**The crop must be opaque.** When a face sits near the photo's edge, the rotated 112 px crop
reaches past the image, and those pixels come out transparent. Core ML's CGImage input and a
plain flatten-to-RGB read such a crop differently:
- **Opaque crops:** on 300 run-2 crops, the same fp32 model gave cosine 1.0000 for every one of
  the 260 opaque crops.
- **Transparent edges:** the 40 crops with transparent pixels went as low as 0.922.

The build fills the area outside the photo with one defined colour, so Core ML always receives
an opaque crop.

## 4. Ground truth: the owner's labels

Labelling 3,293 faces one by one is too slow, so they were first grouped (`tools/cluster.py`):
- **Similarity:** the mean cosine of all four fp32 models, so the grouping favours no
  candidate.
- **Method:** average linkage, cut at 0.45.
- **Constraint:** two faces in one photo are never grouped together.
- **Result:** 848 groups.

The owner then labelled on a local page (`tools/review_server.py`) in three passes:

1. **Naming:** named 93 groups. The same name on two groups merges them.
2. **Mixed groups:** in the named groups, marked faces that were not the named person as left
   out. Birthdays went in for the three children, Sam, Ian and Tyler. They are kept with the
   labels in the research folder, not here.
3. **The kids round:**
   - **Why:** labels made by naming model-built groups only contain faces the models already
     found alike. A child's face no grouping caught stays unnamed, and those are exactly the
     hard cases.
   - **What was shown:** all 391 unnamed faces from the children's lifetimes, most child-like
     first, each offering only the children already born on its date.
   - **Result:** the owner named 42: 28 Sam, 12 Ian, 2 Tyler. All 42 were among the first
     54 shown; there were no child faces after that.

Final labels: 2,196 faces of 33 people. The children:

| Child | Faces |
| --- | --- |
| Sam | 487 |
| Ian | 225 |
| Tyler | 32 |

## 5. Results

`tools/score.py`; pairs are always between two different photos. Each model's threshold is its
fp32 similarity at which 0.1% of all 2.1 million different-person pairs are wrongly accepted:
AdaFace IR-101 0.434, IR-50 0.472, ArcFace R100 0.470, ArcFace R50 0.434.

**One child across years.** For the children's pairs, the share accepted as the same person at
that threshold, by the gap between the two capture dates (fp32):

| Model | < 1 y | ~1 y | ~3 y | ~5 y | 6 y + |
| --- | --- | --- | --- | --- | --- |
| AdaFace IR-101 | **0.73** | **0.62** | 0.31 | 0.13 | 0.05 |
| AdaFace IR-50 | 0.57 | 0.44 | 0.16 | 0.05 | 0.01 |
| ArcFace R100 | 0.70 | 0.59 | **0.34** | **0.17** | **0.06** |
| ArcFace R50 | 0.68 | 0.56 | 0.27 | 0.12 | 0.05 |

Pair counts: 27,786 / 42,015 / 22,289 / 6,081 / 1,608. Every model loses a child beyond about two
years. A face pair three or more years apart is mostly below threshold, whichever model it is.
This is why matching compares a new face mainly with the person's faces from the nearest one to
two years.

**Siblings at the same age.** For each gap g: the probability that a child's own face g years
apart scores higher than a sibling's face at the same age (45,047 sibling pairs whose ages at
capture are within a year). 1.0 means the model always prefers the child years apart over the
sibling; 0.5 is a coin toss.

| Model | < 1 y | ~1 y | ~3 y | ~5 y | 6 y + | siblings above threshold |
| --- | --- | --- | --- | --- | --- | --- |
| AdaFace IR-101 | **0.94** | **0.91** | **0.78** | **0.69** | **0.59** | 4.1% |
| AdaFace IR-50 | 0.88 | 0.83 | 0.65 | 0.57 | 0.47 | 3.9% |
| ArcFace R100 | 0.92 | 0.88 | 0.75 | 0.68 | 0.57 | 3.0% |
| ArcFace R50 | 0.93 | 0.89 | 0.76 | 0.66 | 0.56 | 3.9% |

About 3–4% of same-age sibling pairs clear every model's threshold. A single-pair threshold
cannot keep siblings apart; the decision has to compare people.

**The decision Otos makes.** Each labelled face is matched against every other labelled face
taken on another day within ± 2 years. Rules:
- **Person score:** the best single-face similarity.
- **Acceptance:** a match is accepted only when the best person reaches the threshold and beats
  the second-best by 0.05.
- **Why other days:** a face from the same day is often a near-copy of the same moment, and
  makes matching trivially easy.

| Model | All 2,185 faces: first choice right / accepted | The children's 744 faces: first choice right / accepted / accepted wrong / wrong first choice a sibling | The 42 hard faces: first choice right / accepted / accepted wrong |
| --- | --- | --- | --- |
| AdaFace IR-101 | 99.82% / 99.31% | **100% / 99.87% / 0 / 0 of 0** | **42 / 42 / 0** |
| AdaFace IR-50 | 99.63% / 97.94% | 99.73% / 97.31% / 0 / 2 of 2 | 41 / 32 / 0 |
| ArcFace R100 | 99.77% / 99.13% | 99.60% / 98.66% / 1 / 3 of 3 | 40 / 35 / 1 |
| ArcFace R50 | 99.63% / 98.99% | 99.87% / 99.06% / 0 / 1 of 1 | 42 / 37 / 0 |

Reading:
- **AdaFace IR-101** is the only model that never mistook one child for another. Every wrong
  first choice the other three made on a child was a sibling.
- **On the hard faces,** the ones no grouping had put with the right child, IR-101 named all 42
  correctly and confidently. The next best accepted 37.
- **ArcFace R100** keeps slightly more pairs three or more years apart above its threshold. It
  accepted one wrong child, and it trails IR-101 on every sibling column.
- **Caveat:** the hard-face set is small (42 faces) and comes from one family's photos.

## 6. Precision: does fp16 or int8 change a decision?

Every variant was compared with fp32 of the same model, fed the same crops by the same reader;
see the opaque-crop finding in section 3. Over the 2,196 labelled faces (2.4 million pairs):

| Model | fp16, Neural Engine: pair flips / decisions changed | fp16, CPU | int8, CPU |
| --- | --- | --- | --- |
| AdaFace IR-101 | 180 / 0 | 1,460 / 0 | 1,646 / 1 |
| AdaFace IR-50 | 134 / 0 | 1,512 / 3 | 1,792 / 2 |
| ArcFace R100 | 1,247 / 3 | 1,065 / 0 | 1,361 / 3 |
| ArcFace R50 | 1,215 / 1 | 1,294 / 1 | 1,720 / 0 |

A pair flip is a pair that lands on the other side of the fp32 threshold. A decision is one face
whose accepted person changed.

For AdaFace IR-101:
- **Decisions:** int8 changed one decision of 2,196. That was an adult's face which fp32
  accepted and int8 left unassigned; it is not a wrong match. Nothing changed on the children's
  744 faces or the 42 hard faces. The children's and hard-face results in section 5 are identical at fp32,
  fp16 and int8.
- **Size:** 66 MB, under GitHub's 100 MB per-file limit. fp16 is 131 MB and fp32 261 MB.

## 7. Conclusions

1. **Model:** AdaFace IR-101 (WebFace12M).
2. **Precision and engine:** int8 weights, on the CPU.
   - **Fidelity:** no decision on a child's face changed.
   - **Size:** 66 MB, under GitHub's file limit.
   - **Engine:** the CPU, as for every Otos model (ADR 0045). 33 ms a face is small next to
     decoding the original.
3. **Before the model:**
   - Vision quality ≥ 0.3;
   - the alignment check, box height × scale between 50 and 150;
   - an opaque crop.
4. **Matching:**
   - **Compare:** confirmed faces, mainly within about two years of the new face.
   - **Accept:** only when the best person beats the second.
   - **Starting values:** threshold 0.434 (FAR 10⁻³ on these labels) and margin 0.05, to be
     re-measured when grouping is built.
   - **Years apart:** a gap of three or more years needs chaining through the years between,
     confirmed by the user.
