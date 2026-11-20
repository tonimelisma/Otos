# The Info pane's labels and text, graded against the pictures (2026-11-19)

## Question

The owner, after the descriptions were made plain: "investigate all the other stuff. labels, OCR
text etc". The Info pane's In This Photo section shows Vision's confident scene labels as chips
and the text Vision read in the photo (ADR 0048, ADR 0050;
`2026-11-12-text-and-labels-in-the-info-pane.md`). Neither had been graded against the
pictures.

## Method

Read-only, on the installed catalog: 45 stills chosen by a stable hash of their path (20 with
shown text, 20 without, the owner's five examples), each graded by looking at its preview
beside its chips, its shown text and its place. Then each defect found was measured across
the library: 166,171 stored scene readings, 25,899 stills with shown text, and 24 phone
screenshots re-read with Vision for each line's box. The graded material names the owner's
family and stays out of the repository.

## Results [measured]

### Scene labels

- **True.** No chip on the 45 named something absent: Vision's high-precision filter holds.
- **Repeated by their ancestors.** Vision names every ancestor with a label: "Machine, Vehicle,
  Automobile", "Liquid, Water, Water body, Ocean", "Sky, Blue sky", "People, Adult". A beach
  photo showed 16 chips.
- **Missed** where Vision's recall is low: sea lions, a shelf of quinoa boxes and a string of
  lights had none. Not Otos's to fix.

Vision publishes no taxonomy, but its scores hold one: across the 166,171 readings an ancestor is
present at its descendant's confidence or higher in every reading of the descendant
(`script/scene-label-hierarchy.sh`; 549 of 598 shown labels have one, over at least 20
readings each). It reads as a taxonomy: dalmatian ← dog ← canine ← mammal ← animal; semi truck ←
automobile ← vehicle ← machine; croissant ← bread ← baked goods ← food.

It also links a part to its whole: licence plate ← automobile, because Vision never names a
plate without a car. Leaving out every ancestor would show an SUV as "Land, License plate".
The confidences tell the two apart. Over a quarter of the shown readings:

| Ancestor minus descendant | Pairs |
| --- | --- |
| 0.00–0.02 | 119,164 |
| 0.02–0.04 | 9,432 |
| 0.04–0.06 | 7,131 |
| then falling smoothly | to 966 at 0.50+ |

An inherited ancestor scores what its descendant does (vehicle 0.523 and automobile 0.523;
material and textile 0.513), and one seen on its own scores well above (automobile 0.523 beside
licence plate 0.339). **Rule:** a chip is left out when a shown descendant scores within 0.05
of it. On the SUV `machine 0.535, vehicle 0.523, automobile 0.523, outdoor 0.514, land 0.514,
license_plate 0.339` it shows **Automobile, Land, License plate**; on a family photo `people
0.901, adult 0.881, child 0.566, baby 0.454` it shows **Adult, Child, Baby**. Search keeps
every label.

### Text

- **Mostly real.** Of 27 photos whose whole shown text was one or two short lines, sampled by
  hash from 5,030 such stills, about 20 were real text in the picture ("adidas" on a shirt,
  "MAPEX" on a drum, "PREPAY" on a pump), often a partial word ("ABBLE" of Scrabble), and
  about three were misreads ("une", "00"). Hiding short lines would hide real text, so they
  stay.
- **Repeated lines.** 3,792 stills showed a line more than once ("dreamforce" three times, one
  per banner; "Morgan Stanley" three times). Each is shown once; case and diacritics fold as
  search's matching does.
- **A phone screenshot's status bar.** Every phone screenshot's text began with its clock,
  signal and battery ("23:11 1", "25", "SOS", "98"). Read with boxes on 24 screenshots, those
  lines ended within the top 0.031–0.048 of the screen on every device, 640×1136 to 1179×2556,
  and the screen's own content began at 0.047. A cropped screenshot (753×1032) held a real
  title at the very top, so only a picture of a phone's portrait proportions (width/height
  ≤ 0.6) labelled `screenshot` loses lines ending in the top 0.05. That needs each line's box,
  which readings did not keep: revision 3 of the reading keeps the picture's size and each
  line's box, and every preview is read again in the background (0.18 s each on the CPU,
  previews only, nothing downloaded).

## Conclusion

- The Info pane's chips leave out a label that only repeats a more specific one
  (`SceneLabelNames.Hierarchy`, `SceneLabelHierarchy.tsv`).
- The Info pane's text and a description's facts are `SearchTextReading.shown`: certain lines,
  each once, without a phone screenshot's status bar. Search matches every line.
- Descriptions are written again (prompt revision 6), as the text they are told changes.
