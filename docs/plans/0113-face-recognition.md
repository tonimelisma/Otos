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
- **Model (2026-11-09):** AdaFace IR-101, chosen by the owner from the final four-model
  comparison in the research note (ADR 0047).
- **People surfaces (2026-11-09/10)**, recorded in `docs/design/people.md`:
  - one `People` sidebar row;
  - the list ordered by photo count;
  - the newest confirmed face as the cover;
  - the review newest year first;
  - unsure faces in their own list (`Unsure`), apart from decided suggestions;
  - unnamed groups only when seen on two or more days, with `Ignore`;
  - `Remove Person`, and splits named later;
  - removing a name (`Not Sam`) apart from removing a face (`Not a Face`).
- **No XMP (2026-11-10):** Otos never reads or writes face regions in files' XMP.
- **Approved defaults (2026-11-10):** everything listed to the owner in chat was approved,
  except: dragging one person onto another asks `Are these the same person?` first; adults
  are compared across all years; a birthday may be a year alone.
- **Immich (2026-11-09):** Immich photos get faces. Measured 2026-11-10 (research note §7),
  they are read from the stored Immich preview, with no original download.

## Increments

Each increment lands on `main` with its own DoD.

1. **Docs:** the research note, ADR 0047 (Proposed) and this plan. *(done, #589)*
2. **The model and the analyser, not yet wired in.** *(done, #593)*
   - **The model:** `AdaFaceIR101.mlpackage` (int8, 66 MB) in `Otos/Resources`, with the MIT
     text, the AdaFace citation and the conversion statement in `Otos/Resources/Licenses`.
     Converted by the research folder's `tools/convert.py` and `tools/quantize.py`.
   - **`FaceAnalyzer`:**
     - Vision landmarks and quality at revision 3, the revision measured, with quality paired
       to its face by `uuid`;
     - the admission rules: quality ≥ 0.3, box height × alignment scale between 50 and 150;
     - the five-point alignment;
     - the opaque crop;
     - the embedding.
     It runs off the main actor, on the CPU.
   - **Tests:** synthetic. They cover the alignment, the admission band, the opaque crop at
     the photo's edge, the bundled model's determinism, and a photo without a face.
   - **Real faces:** checked outside the repository by the parity run on run 1's photos. A
     real-face test in the repository waits on a face photo the owner approves as a fixture
     (`OtosTests/Fixtures/Media/README.md` rules).
   - **Benchmark:** a case for one face's analysis (ADR 0043).
3. **Storage and the enrichment lane.** *(this PR)*
   - **Migration v18:** the `face` table, cascading on the asset path, the faces stamp, and the
     library claim's index pair. The `person` table comes with grouping, its first reader.
   - **The claim:** `EnrichmentClaim` replaces the every-product flag, so only a fixed library
     owes faces.
   - **Staleness:** a face product with its own `(size, mtime)` stamp and model revision
     (ADR 0009).
   - **Analysis:** `MediaEnricher` reads faces from the same read as the rendering.
   - **Requirements:** rows for analysis, staleness, cascade on move and delete, and purge.
   - **Logs:** `op=face.analyse` with the counts admitted and rejected, and the reasons.
4. **Grouping, no UI.** *(done, #604; the projection moves to increment 6, its first consumer)*
   - **Policy:** `FacePeoplePolicy` (pure):
     - a time window around each face's capture date;
     - best-person-beats-second acceptance;
     - the same-photo and before-birthday exclusions;
     - chained suggestions across years.
   - **Stored acts:** the `person` table (name optional, birthday), the face's confirmed
     person, rejections as (face, person) exclusions, `Not a Face`, and ignored groups
     (ADR 0047).
   - **Unnamed groups and unsure faces:** grouping among unconfirmed faces (two or more
     days), and the faces whose best two people are within the margin.
   - **Carry-over:** a new reading of a photo moves the user's acts to the face each overlaps.
   - **Measured** on the owner's labels with the shipped model (research note §8): threshold
     0.434, margin 0.08, unnamed groups linked at 0.65.
5. **Design spec:** `docs/design/people.md` *(done, #603; the owner's answers folded in, the
   whole spec awaiting the owner's review)*. It covers:
   - the People sidebar entry;
   - a person's scope;
   - the review of suggestions grouped by year, with accept, merge and split;
   - naming;
   - the birthday.

   The `DES-*` rules come first; the owner reviews it before any UI code.
6. **People UI:** built to that spec (approved 2026-11-10). Every action is one owner
   intent on `CatalogWindowViewModel`, the same for menus, keys and buttons.
   - **Spec status:** `docs/design/people.md` holds the approved decisions; the owner does
     not read specs, so any new decision is put to him in chat.
   - **Projection:** `PeopleProjection`, an actor with its own loop, like
     `DuplicatesProjection`: it runs `FacePeoplePolicy` off every actor and publishes
     suggestions, and is never awaited by a window pass. It gets the store's people-change
     signal.

7. **Faces for Immich accounts,** read from the stored Immich preview (ADR 0047) by
   `PreviewFaceReader`, stamped with the preview's source stamp (ENR-026). *(done, #605;
   grouping scaled to 10,000 faces in #606)*
## Verification across increments

- **Ground truth:** the research folder's `tools/score.py` and the owner's labels
  (`run2/labels.json`).
- **Accuracy check:** `script/face-accuracy.sh` runs the shipped grouping on the labelled set
  (`run2/accuracy-set.json`, research note §9), whenever the model, analysis or grouping
  rules change.
- **Increment 2:** the shipped analyser reproduces the study's embeddings on run 1's photos
  (cosine ≥ 0.9984 for every face both kept).
- **Increment 4:** reports grouping precision and coverage on the same labels.
