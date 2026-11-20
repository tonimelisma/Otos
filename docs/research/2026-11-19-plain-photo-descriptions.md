# Plain photo descriptions (2026-11-19)

## Question

The owner, looking at the Info pane: "jesus, these photo descriptions are something else! what
is the correct approach in terms of evals here? can Apple Intelligence do better?", and then:
"just an extremely simple, matter of fact description of the image", "how do we hill climb".

Revision 4 asked the on-device model for "two or three lively, playful sentences … what makes it
fun to look at". It wrote, among others, "a superhero car ready for action", "numbers and letters
dancing across the screen … secret message" for a bank-transfer screenshot, "mischievous vines"
for a string of lights, a fork read as "a cigarette", the owner's own age, and ages of its own
for unnamed children ("Baby, 4"). The eval of ADR 0053 flagged none of it: it scored invented
names, ages when no age was given, and memory remarks, and never looked at the picture.

## Method

`script/description-eval.sh` on the installed catalog, opened read-only, 60 stills: six from
each of two halves of five groups (screenshots, photos with four or more lines of read text,
photos naming no one, everyone named, some named), chosen by a stable hash of the path. Each
revision is scored two ways:

- **Text checks** (`PhotoDescriptionScore`): invented name, any stated age, a given name left
  out, memory remark, wording that is not plain, more than one sentence, the photo's text copied.
  `clean` counts answers with no flag.
- **Grounded**: the agent looked at each sampled preview once and wrote reference facts (main
  subject, setting, people, likely misreads); each answer is graded true when every claim it
  makes is visible and its main subject is right. The answers and references name the owner's
  family and stay out of the repository.

One change per candidate, compared on both halves; a candidate is kept only when the held-out
half does not get worse.

## Results [measured]

| Revision | Change | Clean (text) | Grounded | Stated age | Given name missed |
|---|---|---|---|---|---|
| 4 | "two or three lively, playful sentences" | 2 / 60 | ~35 / 60 | 4 | 1 |
| 5 | one plain matter-of-fact sentence, never an age, no copied text, greedy sampling | 49 / 60 | 44 / 60 | 0 | 2 |
| 5b | + "never list people one by one: say a group of people" | 32 / 60 | — | 0 | 23 |
| 5c | 5 with unnamed people "called only what they clearly are" (shipped) | 50 / 59 | ~47 / 59 | 0 | 2 |

- Revision 5's misses clustered on unnamed people: the instruction listed the words to use
  ("a child, a boy, a girl, a woman, a man or someone"), and adult women became "a boy" three
  times; a party of six became a list of ten. 5c fixed three of those without a regression.
- 5b is the ADR 0053 lesson again: the model writes what its instructions mention. "A group of
  people" appeared for a pastry, a sequoia and a stone carving, and named people were dropped.
  Rejected.
- 5c's one unwritten answer was a busy model (`failed=1`), not a refusal.
- These counts were scored before `copiedText` also counted a copied code of letters and digits
  (a licence plate); a later run counts those too.
- Left after 5c, and not an instruction's to fix: single misreads by the small on-device model
  (a store pasta dish read as "spicy ahi poke", a bottle as "a coin", dozens of candles as
  "two"), and unnamed adults still miscounted in two photos.

## Conclusion

- Ship 5c as revision 5 (`PhotoDescriptionPrompt.revision = 5`); every stored description is
  written again in the background.
- The next rungs, one run each: the preview size the model sees (1,024 px now), and whether the
  scene labels Vision is confident of help or mislead ("wood processed" appears in answers).
