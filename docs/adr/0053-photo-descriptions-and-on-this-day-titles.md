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

Every photo's instructions ask for two or three lively, playful sentences for the family to
enjoy, nothing invented, and no closing remark about memories (the first version closed nearly
every description with one). English only: the system model
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
sixteen to a page. Each wake is a request answered by one newest-first walk (`CandidateWalk`)
that a newer request restarts from the top, read from indexes (v65): a page of sixteen read
4.9k pages on the owner-shaped catalog, against 17 s for the whole-set query it replaced on
the owner's. A failed preview or request is
passed over for 15 minutes; an unavailable model (Apple Intelligence off, not eligible, not
ready) stops the drain for 15 minutes and a busy one (rate-limited in the background) for a
minute (`time: backoff`: nothing reports when it would answer). The model call is injected
(`PhotoDescribing`), the live one `PhotoDescriber.live` on `SystemLanguageModel.default`.

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

A unit test checks what the model is told; only the model shows what it writes, and its first
answers on the owner's library invented names. `script/description-eval.sh` runs the app's own
facts reader, prompt, face placement and model call (`PhotoDescriptionEvalTests`) on a fixed
sample of the owner's stills, read from the installed catalog opened read-only: twelve that name
no one, twelve whose faces are all named, twelve with named and unnamed faces, chosen by a
stable hash of their path so every run describes the same photos. Each answer is scored
(`PhotoDescriptionScore`, itself tested on answers the model gave): a personal name Natural
Language finds that the facts and the photo's text did not give, or letters standing in for
people; an age the facts did not give; a given name left out; a closing remark about memories.
It asserts no budget, like the face accuracy run (ADR 0047): a change to the prompt, its
revision or the model is run through it before it ships, and the counts are recorded in the
research note. It never runs in `script/check.sh`: the photos and the names in them never enter
the repository, and the model's answers vary from run to run.

## Alternatives Considered

- **Visual descriptions with face slots, names filled in when read.** No re-description on a
  rename, but the owner set re-description as the rule, and a sentence written with the names
  in reads better than one patched afterwards.
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
