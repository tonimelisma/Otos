# Plan 0113: Face recognition and People

Opened 2026-11-09. Decisions: ADR 0047. Measurements:
`docs/research/2026-11-07-face-recognition-models.md`. The research folder
(`~/Development/Otos-face-research`) keeps the converted models, the tools, and the owner's
labelled faces outside the repository. It is never committed.

## Owner decisions

- **Licences (2026-11-07):** Otos is non-commercial; non-commercial model licences are
  acceptable.
- **Downloads (2026-11-07):** downloading dataless originals for face analysis is approved.
- **Model size (2026-11-07):** about 250 MB is acceptable for great results. The chosen model
  is 66 MB.
- **The hard case (2026-11-07):** the owner's children across years, and siblings at the same
  age.
- **Labels (2026-11-09):** the owner labelled the bake-off faces and gave the children's
  birthdays. These labels are the ground truth that later increments re-measure against.

## Open owner decisions

- Whether export writes MWG face regions with names into exported copies. Until decided,
  export writes no face regions.

## Increments

Each increment lands on `main` with its own DoD.

1. **Docs:** the research note, ADR 0047 (Proposed) and this plan. *(this PR)*
2. **MediaMetadata: face regions.** A reader for XMP MWG regions (`mwg-rs:Regions`): each
   region's name, type and normalised area, with `AppliedToDimensions` and the file's
   orientation resolved by the library, so Otos receives display-space boxes. Released, then
   taken by Otos with a version bump. The library owns the format rules (ADR 0039).
3. **The model and the analyser, not yet wired in:**
   - **The model:** `AdaFaceIR101.mlpackage` (int8, 66 MB) in `Otos/Resources`, with the MIT
     text, the AdaFace citation and the conversion statement in `Otos/Resources/Licenses`.
     Converted by the research folder's `tools/convert.py` and `tools/quantize.py`; the
     package's embeddings are checked against the research run's int8 embeddings for the same
     crops.
   - **`FaceAnalyzer`:**
     - Vision landmarks and quality;
     - the admission rules: quality ≥ 0.3, box height × alignment scale between 50 and 150;
     - the five-point alignment;
     - the opaque crop;
     - the embedding.
     It runs off the main actor, on the CPU.
   - **Tests:** on openly licensed face photos, never the owner's. A face near the edge gives
     an opaque crop, a scene-spread detection is rejected, and the same face in two photos
     scores above the threshold.
   - **Benchmark:** a case for one face's analysis (ADR 0043).
4. **Storage and the enrichment lane:**
   - **Migration:** the `face` and `person` tables, with `face` cascading on the asset path.
   - **Staleness:** a face product with its own `(size, mtime)` stamp and model revision
     (ADR 0009).
   - **Analysis:** `MediaEnricher` analyses faces from the read that renders the photo.
   - **Embedded regions:** MediaMetadata's regions are stored as named faces.
   - **Requirements:** rows for analysis, staleness, cascade on move and delete, and purge.
   - **Logs:** `op=face.analyse` with the counts admitted and rejected, and the reasons.
5. **Grouping, no UI:**
   - **Policy:** `FacePeoplePolicy` (pure):
     - a time window around each face's capture date;
     - best-person-beats-second acceptance;
     - the same-photo and before-birthday exclusions;
     - chained suggestions across years.
   - **Projection:** `PeopleProjection`, an actor with its own loop, like
     `DuplicatesProjection`. It publishes suggestions and is never awaited by a window pass.
   - **Re-measuring:** the threshold and margin are measured again on the owner's labels,
     using the app's own embeddings.
6. **Design spec:** `docs/design/people.md`. It covers:
   - the People sidebar entry;
   - a person's scope;
   - the review of suggestions grouped by year, with accept, merge and split;
   - naming;
   - the birthday.

   The `DES-*` rules come first; the owner reviews it before any UI code.
7. **People UI:** built to that spec. Every action is one owner intent on
   `CatalogWindowViewModel`, the same for menus, keys and buttons.

## Verification across increments

- **Ground truth:** the research folder's `tools/score.py` and the owner's labels
  (`run2/labels.json`).
- **Increment 3:** re-runs the bake-off with the shipped package. The children's
  wrong-child count must stay 0.
- **Increment 5:** reports grouping precision and coverage on the same labels.
