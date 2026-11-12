# Text and scene labels in the Info pane

Run 2026-11-12 on the owner's library (19,221 photos, 10,065 stills with a stored 2,560 px
preview), macOS 27.0.1 (26A434), while other checks loaded the Mac (load average 20–100). The
judged material is the keyword-search research set (`docs/research/2026-11-09-keyword-search.md`
§9), kept outside the repository with the owner's photos.

Question: can the Info pane show what search recognised in a photo — its scene labels and its
text — and what does each need to be shown rather than only searched?

## 1. Text: the fast level cannot be shown

Search read text at Vision's fast level (`VNRecognizeTextRequest`, 2,560 px preview, lines from
0.3 confidence). Re-read on 300 random previews that held text:

- The fast level reports two confidences only: 0.5 (696 lines) and 0.3 (350 lines).
- The 0.3 lines are almost all texture read as text (`s¥llttt41-,`, `oOo?¢Q`).
- The 0.5 lines are mixed: real menu lines ("Truffle Parmesan Fries") next to `*•9>•'•` and
  `I, ':Ii, I',¥ I, :,`.

No cut on the fast level's confidence separates them. Of 5,322 previews it read as holding
text, most hold none: the stored readings shown as they are would look broken.

## 2. Text: the accurate level, on the CPU

The keyword-search research found the accurate level failing for every image after a process's
first (`e5rt` error 13) on macOS 27.0. On 27.0.1 it does not fail.

| Reading | Previews | Errors |
| --- | --- | --- |
| accurate, default device | 60 in one process | 0 |
| accurate, CPU (`setComputeDevice(.cpu, for: .main)`) | 300, then all 10,065 | 0 |

It reports 1.0 for the lines it is sure of (21,758 lines over the library), 0.5 (1,963) and 0.3
(1,052). Lines at 1.0 read cleanly: "BONELESS SKINLESS", "Points de fixation de la boucle
Molle", the Finnish "Lunta, lunta! hihkui Hiiru." The noise sits at 0.5 and 0.3.

Time per 2,560 px preview, 30 previews, under load:

| Level and device | First | Median | 90th percentile |
| --- | --- | --- | --- |
| accurate, default device | 33.3 s | 137 ms | 32.0 s |
| accurate, CPU | 309 ms | 153 ms | 370 ms |
| fast, default device | 243 ms | 85 ms | 282 ms |

The default device stalls for half a minute at a time while other work runs, as every Otos model
did before ADR 0045 pinned them to the CPU. The whole library read on the CPU in 30 minutes
(0.18 s a preview).

**Search, scored on the 60 judged word queries** (`judge/rel_ocr`: a photo is relevant when the
word is visibly written in it; `.seen` lists the photos judged). A reading matches a word as
`SearchTextReading.matches` does.

| Reading | Relevant photos matched | Judged misreadings matched | Precision on judged | Matches nobody judged |
| --- | --- | --- | --- | --- |
| fast, lines from 0.3 (before) | 212 / 222 | 84 | 0.716 | 98 |
| accurate, lines from 0.3 | 213 / 222 | 59 | 0.783 | 182 |
| accurate, lines from 0.5 | 213 / 222 | 59 | 0.783 | 182 |
| accurate, lines at 1.0 | 211 / 222 | 59 | 0.781 | 177 |

The judged pool came from the fast reader's matches and SigLIP's top 10, so a match the accurate
level alone made was never judged. 30 of the 177 sampled at random were all real text holding
the word: an insurance card, "BRIDGE CLOSED AHEAD", "salad, house pickles & mayo", a parking
receipt's "PAYMENT AMOUNT". The accurate level finds what the fast level found, reads a quarter
fewer misreadings, and finds about 180 more real matches.

**Decision:** read at the accurate level on the CPU; keep every line from 0.3 with its
confidence; search matches them all, the Info pane shows the lines at 1.0.

### Reading the original instead of the preview

Of 3,000 random library photos, 2,993 originals are dataless cloud placeholders and 7 are local,
so reading text from originals would download nearly the whole library, and could not be
measured without downloading a sample. The preview's 1.0 lines already read the menus, signs and
screenshots cleanly; the preview stays the source. (Embeddings: SigLIP resizes to 256 px, and the
thumbnail scored as the preview did, keyword-search research §7. Faces read the original, ADR
0047.)

## 3. Scene labels: Vision's high-precision test

Search's label gate keeps every label from 0.05 confidence: about 18 a photo, with echoes such as
a horse at 0.08 beside a wagon. Apple's recommended high-precision filter,
`hasMinimumRecall(0.01, forPrecision: 0.9)`, judges each label against its own precision-recall
curve. On 300 thumbnails it kept a median of 5 labels a photo (90th percentile 10, 20 with none):
`grass land outdoor people adult structure`, `machine wheel rim tire`,
`recreation sport sports_equipment trampoline structure fence people child`,
`plant tree sequoia outdoor`. They are right, and a parent comes with its child at the same
confidence (`sky`, `blue_sky`).

**Decision:** store the labels that pass, most confident first, beside the gate's loose reading;
the Info pane shows them.

## 4. Naming the labels in the Mac's language

Vision's identifiers are English and come with no localized names.

**Translated while browsing:** 20 labels through `TranslationSession` took 11–34 s per language
under load, and 5 more 2.5–5.7 s. That is too slow for a pane that follows the selection, and a
Mac without the language's pack cannot translate at all. The names are made once and shipped.

**As a caption:** a bare word is translated without context. Bare, "pool" became Norwegian
"pytt" (puddle) and Korean "water" "물을 싣다" (to load water); as "Photo: pool" they read
right, as search's queries do (keyword-search research §9).

**Still wrong sometimes:** all 1,303 names into Finnish as captions, 889 s. Of 30 sampled at an
even spacing, several were wrong: pear "omena" (apple), dill "ruohosipuli" (chives), seahorse
"merikilpikonna" (sea turtle), lychee "lyhytomena", foosball "jalkapallo" (football), sledding
"lumilautailu" (snowboarding). A wrong name is a wrong fact, so each name needs a check.

**Checked by SigLIP reading the translation:** whether the multilingual text tower ranks the
right label first for the Finnish name. It kept 605 of 1,303 and rejected the wrong ones above,
but also right ones for the commonest labels: "ihmiset" (people) ranked 326th and "aikuinen"
(adult) 87th. Rejected.

**Checked by reading back:** each translation is translated back into English as a caption, and
kept only when the English names the same label by search's own test
(`SearchLabelVocabulary`, cosine 0.95). On the cases above it keeps "vaatteet" (read back
"clothes", which names clothing) and "baseball-lippis" ("baseball cap"), and rejects "omena"
("apple" names apple, not pear) and "merikilpikonna". A rejected name reads in English.

**Finnish, the first language made** (1,900 s for 1,303 names, forward and back): 885 kept,
418 left to English. The read-back rejects real errors — cigar "savukkeet" (cigarettes), harp
"harppuuni" (harpoon), joystick "ohjauspyörä" (steering wheel), wedding cake "häätarjotin" — and
some right names whose reading is a near synonym the 0.95 test does not join (outdoor "ulkona",
read back "outside"; toolbox "työkalupakkaus", "tool kit"); those read in English, which is
never wrong. The commonest labels are kept: ihmiset, aikuinen, lapsi, taivas, sininen taivas,
kasvi, ruoka, vaatteet, asiakirja, kuvakaappaus.

Translation's speed varies with what else asks the system's on-device inference: 0.68 s a name
one direction early on, 3.6 s a call while a backlog from cancelled sessions drained, 0.5 s a
call after. The other languages are made one at a time, the same way (about 1,000 s each once the backlog
cleared), and their columns join the table as each is checked:

| Language | Names kept of 1,303 |
| --- | --- |
| Finnish | 885 |
| Swedish | 1,023 |
| German | 1,025 |
| French | 1,034 |
| Spanish | 1,018 |
| Italian | 1,021 |
| Dutch | 1,064 |
| Danish | 1,021 |
| Norwegian | 1,035 |

Swedish, German, French, Spanish, Italian and Dutch all name pear rightly ("päron", "Birne",
"poire", "pera", "peer"), where Finnish read it as apple and was left to English.
