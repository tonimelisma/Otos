# ADR 0045: Auto crop and Auto straighten use two converted models

## Status

Accepted, 2026-11-02. Supersedes the Vision horizon and saliency parts of ADR 0036.

## Context

The edit panel's Crop section offers one-click straightening and cropping. The first versions
used Apple's Vision framework: the horizon detector for straightening, and saliency boxes placed
by hand-made rules ("Subject", "Thirds") for cropping. Neither held up when measured
(`docs/research/2026-11-01-auto-straighten-and-crop-suggestions.md`):

- **Vision's horizon** reports confidence 1.0 on every answer. Against calibrated iPhone gravity
  on 114 of the owner's photos, it was off by more than 5° on 22 of the 59 it answered, and
  nothing distinguishes those answers from its good ones.
- **The hand-made crops** were the weakest class in the literature. The rule of thirds alone
  barely predicts aesthetic ratings (Amirshahi et al. 2014), and saliency-only cropping was
  withdrawn by Twitter after bias findings (Yee et al. 2021).

The camera's own gravity reading (MediaMetadata `levelingTurnDegrees`, ADR 0036) is right but
exists only for iPhone back-camera photos.

## Decision

**Auto straighten** (Level ▸ Auto):
- **Sources, in order:**
  - The camera's gravity reading, when the photo has one.
  - Otherwise GeoCalib's roll (Veicht et al., ECCV 2024), but only when its own uncertainty is
    at most 3°.
- **Unavailable** when neither applies.
- **Turns and flips:** the reading levels the upright, unflipped photo, which a quarter turn
  keeps level; each flip reverses it.

**Auto crop** (Suggested ▸ Crop):
- **Model:** Appwrite FocalNet's human-preference crop ranker, choosing by its own rule among ten
  shapes, so the crop takes whatever shape suits the photo.
- **Unavailable** when FocalNet keeps the frame whole (overlap with the whole frame 0.97 or more).
- **Per frame:** it is read for the frame as saved, and re-read when a turn, flip or straighten
  changes that frame.

**When and where they run:**
- **Timing:** both are read when the photo opens in the panel, so a button is available only once
  there is something to apply, and its tooltip says when there is not (DES-038).
- **Lane:** one newest-wins analysis lane owns the reads (`editAnalysisStream`).
- **Engine:** both models run through Core ML on the CPU, owned by one `EditAnalyzer` per window
  that loads them on first use.

**The models ship converted, in the repository:**
- **`FocalNet.mlpackage`**, 18 MB, at full precision:
  - Converted from FocalNet's own PyTorch checkpoint.
  - Identical to its ONNX reference on GAICD's 500 test photos: rank correlation 0.7646, the same
    top crop on all 500.
  - Half precision changed the top crop on 3.6% of photos, so it was not used.
- **`GeoCalib.mlpackage`**, 61 MB, at half precision:
  - The network only, with one function per input shape, since Core ML cannot size its upsampling
    from a flexible shape. The functions share one copy of the weights.
  - The random starting bases of its NMF block are fixed to one seeded tensor, so a photo always
    reads the same.
  - Neither half precision nor the fixed bases changed accuracy on the owner's 114 photos, and
    half precision keeps the weight file under GitHub's 100 MB limit.
- **GeoCalib's solver** is ported to Swift (`PerspectiveFieldSolver`). It matches GeoCalib's own
  solver to a median 0.0006° of roll on all 114 photos, with the same step count on every one and
  the same confident-or-not decision on every one.

**Measured on this Mac (M1 Pro, CPU):**
- **Auto straighten:** 61% of the 114 photos get a GeoCalib reading; of those, 93% are within 2°
  of the gravity reading and none is off by more than 5°. About 0.35 s per photo.
- **Auto crop:** FocalNet crops about 15% of photos (45 of 300). Where it does, Swift and Python
  choose the same crop (44 of 44); the two disagree about cropping at all on 6 of 300, borderline
  photos where resizing differs. About 0.1 s per photo. The owner rated its crops good in a blind
  A/B.

**Licences and attribution:**
- FocalNet: MIT.
- GeoCalib: code Apache-2.0; weights CC-BY-4.0, © 2024 ETH Zurich. Converting the weights is a
  modification under that licence and is stated.
- The licence texts and the attribution ship in the framework (`Otos/Resources/Licenses`).

## Rejected alternatives

- **One Auto that falls back to Vision's horizon:** a fallback that cannot tell its wrong answers
  from its right ones presents a made-up fix as a correction.
- **FrameLite** (Apache-2.0, vision-language model): it had the best benchmark scores
  (FCDB IoU 0.717 against FocalNet's 0.656 and 0.643 uncropped), but it needs about 2 GB of
  weights and 8 s per photo here. The owner ruled that out.
- **GAIC** (MIT): an older ranker whose custom region-pooling operations do not convert to Core
  ML. FocalNet does the same job at 19 MB.
- **ProCrop:** non-commercial, no-derivatives licence, and its code and weights are unreleased.
- **The Human-Centric Cropping model:** it declares no licence at all.
- **Running the models on the GPU or Neural Engine:**
  - On the GPU, eight concurrent predictions deadlocked inside MPSGraph, every thread parked on
    its lock; parallel test runs reach that.
  - The Neural Engine refuses a function name on a multi-function model.
  - The CPU reads the same values at about the same speed and leaves the GPU to the live render.
- **Core AI:** the macOS 27.2 SDK's `CoreAI` module has no public interface yet.
- **Storing the readings in the catalog:** nothing else reads them, and both are cheap to read
  again when the photo is next edited.

## Consequences

- **App size:** the app grows by about 79 MB of models.
- **Repository:** the two packages are binary files; a model change is a new conversion,
  recorded in the research note.
- **Coverage:** Auto straighten covers more photos (gravity, plus confident GeoCalib) and is
  never knowingly wrong; about 40% of photos without gravity get no Auto straighten, which is
  the honest answer.
- **Removed:** the Subject and Thirds suggestions and the Vision horizon.
