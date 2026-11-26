# ADR 0053: Photo descriptions and On This Day titles, written by Apple's on-device model

- Status: Accepted
- Date: 2026-11-14

## Context

The owner asked what foundation models could do with Otos's photos
(`docs/research/2026-11-14-foundation-models-for-media.md`) and chose two uses (2026-11-14):
an English description of every photo, shown at the top of the Info pane, and titles for On
This Day's stories. Their directions:

- The model is told who is in the photo: each face's person's name and age, so it knows which
  name is which face.
- When any fact a description was written from changes, the description is simply written
  again: about two seconds a photo is nothing.
- People will read the descriptions; they should be fun. They are not edited.
- No audio, for now.
- Apple's Private Cloud Compute is acceptable.

macOS 27's Foundation Models framework takes an image in a prompt
(`Attachment(CGImage)`) on the on-device model, returns a typed value through guided
generation (`@Generable`), and classifies a guardrail or refusal by typed errors. Measured on
the owner's Mac: about 2.4 s a photo warm, 16–23 s for a cold process; English output; with
names and positions given, the model named the right person at the right face on the owner's
photos ("Jamie holds Tyler…", "Taylor holds Tyler…").

Private Cloud Compute (`PrivateCloudComputeLanguageModel`) has a larger model and context, no
cost to the developer under 2 million downloads, a **daily per-user quota counted against the
user's iCloud account** (higher with iCloud+), needs an internet connection, and is applied
for on the developer website. An unsigned probe got `ModelManagerError 1046`.

## MECE Decision Scope

This ADR owns: what a description is written from, when it is written again, how it is stored
and shown in the Info pane, and how On This Day's titles are written and shown. It references
but does not own: the stored preview (ADR 0035); faces and people (ADR 0047); the text and
scene labels read for search (ADR 0048); place names (ADR 0051); the Info pane (ADR 0050);
On This Day (ADR 0049); the owner-state rules (ADR 0032, ADR 0033).

## Decision

### What the model is told

`PhotoDescriptionPrompt` builds the prompt once, as a value a test can read. Beside the still's
**stored preview**, downscaled to 1,024 px (never the original, so nothing is downloaded), the
model is told:

- when it was taken (the capture clock's day and part of day) and where (the map cell's town
  and country, ADR 0051);
- each named face's position in the picture (thirds across and down), left to right, with its
  person's name and age on that day — whole years, months under two, "about" from a birth year
  alone — then how many more people are not named. A face given to no one, to an unnamed person
  or to a hidden one is not named. Faces are stored on the upright photo and carried onto the
  preview through its edit (`EditGeometry`); a face the crop leaves out is not told;
- **instructions made for the photo:** the model writes what its instructions mention. With
  one set of instructions that spoke of names and ages, photos with no named face came back
  with invented names ("Jasper", "Aunt Per", "Toby, 7, and Claire, 4"), invented ages ("a
  5-year-old and a 7-year-old") and placeholder people ("A, B, and C" beside a box of fruit
  snacks). So a photo naming no one gets instructions that never mention names or ages (six of
  six clean on the owner's photos); a photo whose faces are all named asks for each by name and
  no other; and only a photo with unnamed faces too adds that everyone else stays unnamed (no
  invented name in five runs). Sent where no one was unnamed, that last rule made the model drop
  given names and add people who were not there (revision 3);
- the text Vision is certain of and its confident scene labels.

Every photo's instructions ask for **one short, plain, matter-of-fact sentence** that says what
the photo shows: its main subject, what is happening and the setting, only what is clearly
visible, with no opinions, jokes, feelings, guesses or exclamation marks. A screenshot or a
document is said to be one, with what it is about, and its text and numbers are not copied.
No age is ever written; ages stay in the facts, where they tell a baby from an adult. The owner
asked for "an extremely simple, matter of fact description of the image" (2026-11-19) after
revision 4, which asked for "two or three lively, playful sentences", wrote "a superhero car
ready for action", "numbers and letters dancing across the screen" for a bank-transfer
screenshot, a fork read as "a cigarette", the owner's own age, and ages of its own for
unnamed children. Unnamed people are called only what they clearly are: an instruction that
listed the words to use ("a child, a boy, a girl, a woman, a man") made adult women "a boy".
The model samples greedily (`GenerationOptions(sampling: .greedy)`): the
same photo and facts give the same sentence, and no sampled embellishment. English only: the
system model
does not write Finnish, and search reads English (ADR 0048).

### When a description is written

A still is described once what the model is told is settled for its preview — its faces read
from that preview, its text read and its scene labels read (`describableStill`). The row
(`photo_description`, v58) stores the description and a **source**: SQL over the catalog that
names the preview, the faces' stamp, each face's person with name, birthday and hidden flag,
the place names, the capture time and `PhotoDescriptionPrompt.revision`. A still whose row
does not name it as it is now is owed a new description. So a rename, a face given to someone,
a birthday, a hidden person, a new place name, a new preview or a new prompt each write it
again, and no writer of those facts knows descriptions exist. A write lands only while the
source still matches, so a fact changed while the model wrote is described again.

`text` is NULL when the model declined (its guardrails or a refusal): a verdict on those facts,
shown as `No Description`, not asked again until they change. A failed request writes nothing.

### Who writes them

`PhotoDescriptionWriter`, one actor, one loop (ADR 0032 rule 3) woken by a Store change of a
kind its walk reads — faces and people, place names and locations, capture time, images, and
the search embedding and text reading a still waits for (`.searchContent`, which the Store
announces with every search write); a row only added is not one — derived from its own SQL
(`CatalogOwnerInputs`), and by its retry wake; newest capture first, one request at a time,
sixteen to a page. A change that names its rows (a text reading or an embedding written, a
still's faces read) owes those stills alone, read by their keys
(`PhotoDescriptionStorage.keyedCandidateSQL`) ahead of the walk's next page: a still's
description is written from its own rows and from people and place cells, whose writes name
no photo, so a named change makes no other still owed. Restarting the walk for each of them
re-read the described stills at the top on every page, 1.1 to 3.4 s a page on the owner's
library (`docs/research/2026-11-16-idle-disk-read-attribution.md`). A change that names no
rows, and a wake, owe one newest-first walk (`CandidateWalk`) that a newer one restarts from
the top, read from indexes (v65): a page of sixteen read 4.9k pages on the owner-shaped
catalog, against 17 s for the whole-set query it replaced on the owner's. A failed preview, or a request
that failed over its photo, is passed over for 15 minutes. Whom a failed request is about is
read from the framework's typed errors (`PhotoDescriber.Failure`): only a case that names the
request — its context too large, its answer undecodable, its time run out — is the photo's; a
rate limit or a concurrent request is a busy model; everything else is the model's — Apple
Intelligence off, not eligible, not ready, a capability every request needs, or a failure in
its service that no public case names. An unavailable model stops the drain for 15 minutes and
a busy one for a minute (`time: backoff`: nothing reports when it would answer). On the owner's
Mac on 2026-11-20 every request failed with a `LanguageModelError` of no public case carrying a
`ModelManagerError` 1026, which the system relayed from an asset lock it could not open ("Too
many open files", `MobileAssetError.AutoAsset` 6583) while Otos held 67 descriptors; read as a
failure of each photo, it made 13,177 requests in three hours, about three a second, one per
owed still. The fault is macOS's: on 2026-11-26 a standalone program that only calls
`LanguageModelSession` failed the same way at a 256 and a 10240 open-file limit, and so did
the system's own `textunderstandingd`
(`docs/research/2026-11-26-copy-paste-and-cloud-originals.md`), so Otos leaves its open-file
limit alone. A failure's log line names its error chain by domain and code (`causes=`). The model call is injected
(`PhotoDescribing`), the live one `PhotoDescriber.live` on `SystemLanguageModel.default`.

**While Otos is in front too, and at memory-pressure warning** (ADR 0057 decision 8; ADR 0055
decision 8). The owner, 2026-11-18: "Descriptions should run when the app is foreground ed. OS
will swap running apps". Each request first waits for the background room only at critical
memory pressure, a serious or critical thermal state, or Low Power Mode, and the walk goes on
in the step that opens it. The model's service held 411 MB at rest and 857–925 MB while
describing on the owner's Mac; macOS compresses and swaps it with the other apps.

**On-device, not Private Cloud Compute.** The owner accepted PCC, but its daily quota is the
user's and is counted per request: describing a library of ~19,000 photos would spend days of
it and then stop. The on-device model is unlimited, offline and free.

### The Info pane

A still's Info pane opens with **Description** (owner, 2026-11-14): the text, selectable, over
`Written by Apple Intelligence` (the HIG asks that generated content be identified). `No
Description` when declined; while owed, `Not Written Yet`, or why none can be written here
(`Turn on Apple Intelligence in System Settings to describe photos.`, `This Mac can’t describe
photos.`). A movie has no Description section. The pane re-reads it whenever the writer
announces a write, on the same loop that re-reads In This Photo (`startReadingsRefresh`).

**No overlay on the photo.** Photos for Mac shows a caption only in its Info window; the HIG's
materials guidance has text over a photo dim it or sit on glass, both of which cover the
picture under review (DES-060A). The description stays in the inspector.

**Not editable** (owner): no Edit, Retry or Revert control is offered.

### On This Day titles

`AnniversaryTitleWriter` titles each anniversary the scope shows from the descriptions of up
to eight of its photos, in play order, with "N years ago": a text-only request of about a
second, asking for at most six words. The window hands it the anniversaries shown (newest
wins) and assigns the titles it publishes; it writes again when those descriptions change, and
an anniversary with none described has no title. Titles are kept in memory: a launch writes the
few shown again. The card shows the title on its own line under the cover, the line held empty
until one arrives (DES-053); the story bar shows it after `N years ago`; VoiceOver reads it
first.

### The eval

A unit test checks what the model is told; only the model shows what it writes. `script/description-eval.sh`
runs the app's own facts reader, prompt, face placement and model call (`PhotoDescriptionEvalTests`)
on a fixed sample of the owner's stills, read from the installed catalog opened read-only, in
five groups chosen by a stable hash of their path so every run describes the same photos:
screenshots, photos with much text (four or more lines read), photos that name no one, photos
whose faces are all named, and photos with named and unnamed faces. The hash also splits each
group in halves: a prompt is tuned on `tune` and kept only when `holdout` does not get worse.

Each answer is scored twice:

- **By its text** (`PhotoDescriptionScore`, itself tested on answers the model gave): a
  personal name the facts and the photo's text did not give, or letters standing in for
  people; any stated age; a given name left out; a closing remark about memories; wording that
  is not plain (an exclamation, a word that says how the photo should feel); more than one
  sentence; the photo's own text copied.
- **Against its picture:** whether every claim is visible, the main subject is right, and the
  sentence is plain. A script cannot see the picture, so the agent grades each answer by
  looking at the preview its row names, against reference facts it wrote once per sampled
  photo. The answers and the references name the owner's family and never enter the
  repository; the counts are recorded per revision in
  `docs/research/2026-11-19-plain-photo-descriptions.md`.

It asserts no budget, like the face accuracy run (ADR 0047): a change to the prompt, its
revision, the facts or the model is run through it before it ships, one change at a time. It
never runs in `script/check.sh`: the photos never enter the repository, and the model's answers
can change with the system model.

## Alternatives Considered

- **Visual descriptions with face slots, names filled in when read.** No re-description on a
  rename, but the owner set re-description as the rule, and a sentence written with the names
  in reads better than one patched afterwards.
- **A run of failures across different stills read as the model failing.** Rejected: the
  framework's typed errors say whom a failure is about, so counting failures would guess at a
  fact the error states, and would hold the whole drain for a run of stills whose requests each
  failed over their own photo.
- **Private Cloud Compute for descriptions.** Rejected for the quota (above); it stays an
  option for a few requests, such as titles, if the on-device model's quality proves short.
- **A third-party captioner (LFM2.5-VL-450M).** Faster on the CPU, but a download, an ADR of its
  own and no better English; the system model costs nothing to ship.
- **Persisted titles.** Their lifecycle is the day's, not an item's; a handful a launch is
  cheaper than a table.

## Consequences

- A first pass over the owner's library takes hours in the background; each change to a person
  describes that person's photos again.
- macOS updates change the model; descriptions already written stay until a fact changes.
- Descriptions are English whatever the Mac's language.

## Living Documentation Impact

`docs/requirements.md` ENR-032, APP-077, APP-078 and APP-041; `docs/design/info-pane.md`,
`docs/design/on-this-day.md`, DES-088 and DES-112; `docs/architecture.md`;
`docs/research/2026-11-14-foundation-models-for-media.md` §7.
