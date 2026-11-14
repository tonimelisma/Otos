# Memories and highlights in consumer photo and video apps

Date: 2026-11-07. A survey for a possible Otos feature that resurfaces media for the
user, in the spirit of Instagram Stories or Apple Photos Memories. Four parallel
passes read official help pages, vendor blogs and engineering posts, source code
(Immich, Ente, Nextcloud Memories, read through `gh api`) and Apple developer
documentation; press and forums fill gaps and are marked. No code or behavior
changed in this pass, and nothing here is a decision.

Vendors document controls well and selection algorithms poorly. Where a selection
claim has no primary source it says so.

## The concepts

Every product surveyed combines three independent choices: **what a memory is**
(the unit), **how it is shown** (the presentation), and **where it reaches the user**
(the surface). They are listed here as a menu; the per-app evidence follows.

### Units (what a memory groups)

| Unit | Rule as shipped | Who | Needs faces? |
| --- | --- | --- | --- |
| **On this day** | Same calendar date in earlier years, one card per year | Facebook, Timehop, Day One, Immich, Mylio, Amazon "This Day", OneDrive, Windows Photos, Snapchat Flashbacks | No |
| **On this day, windowed** | Anniversary ± 3 days, fallback to the month (LibrePhotos); ± N days configurable (Nextcloud); same week (Dropbox Flashback, defunct) | LibrePhotos, Nextcloud | No |
| **Trip** | Time away from a detected home: Ente clusters at 25 km, 2–30 days, ≥ 20 photos, gaps ≤ 15 days, home = 0.6 km clusters active ≥ 45 days | Apple, Google, Ente, Huawei | No (GPS + time) |
| **Recent days / event** | A day or event with enough significant shots | Apple Recent Days, Apple Months (≤ 5 events a month, spread across it) | No |
| **Best of month / season / year** | A period, curated by quality | Google Best of Month, Recap; Facebook Recaps; Windows seasonal recaps; Snap Recap; Spotify Wrapped as the format reference | No |
| **Place** | Photos at one place across years | Apple (Places key photos), PhotoPrism Moments ("Germany 2020") | No |
| **Theme / pattern** | Scene-classified sets (pets, food, sunsets), or ≥ 3 visually similar photos ("little patterns") | Google, Apple, PhotoPrism labels, Ente CLIP | No (scene ML) |
| **Holiday / recurring event** | Calendar holidays of the home region; annual rituals | Apple ("Show Holiday Events"), Google, Ente "Rituals" | No |
| **Person / pet / birthday** | Faces or pets; Immich shows birthdays from 3 days before | Apple, Google, Immich, Ente | Yes |
| **Prompted** | The user types a description and the app assembles a movie | Apple Memory Maker, Samsung "Describe a story", Google Ask Photos / highlight prompts | Mostly no |
| **Daily one-second** | One clip a day, stitched into a timeline movie | 1 Second Everyday | No (user picks) |

### Presentations

1. **Tap-through story player.** One progress segment per item, a tap goes forward
   or back, holding pauses, a swipe or Esc exits; stills hold for a fixed time,
   videos play for their own length. Instagram Stories originated it; Google Photos,
   Immich (web and mobile) and Ente use it for memories. Immich's web viewer adds
   ←/→, A/D and Esc, mute, play/pause, an "Up next" preview, and a grid of the
   memory below the player. Immich makes the still duration a user preference.
2. **Autoplay movie.** A rendered vignette with crossfades, Ken Burns on stills, a
   title card, a look (filter) and a soundtrack. Apple Memories and Memory Mixes,
   Samsung Stories, OneDrive slideshows, Windows Photos Moments, Snap Recap, Google
   highlight videos. Usually exportable as a video file.
3. **Cinematic still.** A depth-estimated 3D parallax camera move over one photo
   (Google Cinematic photos), or frames interpolated between two near-identical
   shots (Google Cinematic moments).
4. **Collage or card.** A key photo plus title ("3 years ago", "Best of August
   2013"); Google's "X years ago" cards cut the photo into the shape of the number.
5. **Passive ambient.** Screensaver or frame: Apple TV Memories screensaver, Nest Hub
   ambient mode, Echo Show "Daily Memories", Aura and Nixplay frames, Lock Screen
   Photo Shuffle. Curation here is mostly about what *not* to show.
6. **Year-in-review cards.** Spotify Wrapped style: vertical cards, a few seconds of
   animation each, ending on a still sized to share, with statistics (Google Recap
   counts top people and selfies).

### Surfaces

- A **strip or carousel above the main grid**: Google Photos, Immich, Nextcloud
  Memories, Ente. The most discoverable placement; Instagram's archive-buried
  Memories went largely unused (TechCrunch 2019).
- A **sidebar row or tab**: Apple Photos on Mac (Memories in the sidebar), iOS 26
  Collections, Samsung Stories tab, Facebook Memories page.
- **Notifications and email**: universal, and the single most complained-about part
  (Timehop nudges, OneDrive emails that survive opt-out, repeated Apple and Google
  notifications).
- **Widgets, lock screen, TV and frames**: Apple, Google, Immich and Ente widgets;
  Apple TV; smart displays.

## Curation heuristics with primary sources

From Apple's Photos Tech Brief (September 2019), pages 4–10, the most detailed
vendor description found:

- Signals computed on device: more than 1,000 scene classes; more than 20
  composition attributes (lighting, subject sharpness, colour, timing, symmetry,
  framing); quality (sharpness, colourfulness, camera motion, exposure); face
  capture quality; audio classes such as laughter and applause.
- **Semantic dedupe**: similar photos from one day are grouped by scene description
  across angles and times, and the one with the best composition, quality and
  relevance represents them.
- **Clutter hidden**: screenshots, screen recordings, blurry or badly framed shots,
  whiteboards, receipts, documents, tickets, credit cards.
- **Hero rules**: relevance (frequent people, new places), representation (an event
  with many shots matters), composition, liveliness (a mix of Live Photos, video and
  stills), user activity (edited, shared or favourited items rank higher).
- **Liveliness**: never more than one Live Photo or video playing at once.
- **Saliency crops**: previews crop where an eye-tracking-trained model predicts
  people will look.
- Memories key photos also use differentially private "iconic scene" popularity
  (Apple Machine Learning Research).

Other primary sources:

- **Minimum and diversity gate** (Huawei Gallery): no highlight when there are too
  few photos (an older page says 10), shooting times are too close, or photos are
  too similar. Highlights are built only while charging, on Wi-Fi, screen off.
- **Ente On This Day** (`rust/crates/photos/src/memories/on_this_day.rs`): at least
  5 photos across at least 2 years, at most 20, at least ~360 days old, a 10-minute
  minimum gap between picks, near-duplicates dropped at CLIP similarity ≥ 0.80. The
  timeline is bucketed so dense periods do not dominate. Recomputed every 3 days.
- **Immich On This Day** (`server/src/repositories/asset.repository.ts`,
  `getByDayOfYear`): exact month-day match, one memory per prior year, at most 20
  assets by date descending, excluding archived, hidden, locked and trashed assets;
  no quality, screenshot or duplicate filter.
- **LibrePhotos**: excludes screenshots, documents and non-primary stack members;
  covers prefer a favourite from that day, never a video.
- **Google Nest ambient and Aura frames**: drop blurry, badly exposed, low
  resolution, near-duplicate and (Aura) eyes-closed photos.
- **Lightroom Assisted Culling** (the only Adobe curation; no memories in any
  Lightroom): picks on subject and eye focus and open eyes; rejects exposure
  problems, misfires, documents and receipts.

Unverified editing lore with no vendor source: "video clips of 2–4 s", "open on the
strongest image", specific movie length targets.

## Apple platform building blocks on macOS 27

Checked against developer.apple.com:

- `CalculateImageAestheticsScoresRequest` / `VNCalculateImageAestheticsScoresRequest`
  (macOS 15+): `overallScore` and `isUtility` ("not necessarily of poor image quality,
  but may not have memorable or exciting content"), which maps directly onto Apple's
  clutter rule.
- `VNGenerateAttentionBasedSaliencyImageRequest` (macOS 10.15+): an attention heat
  map for Ken Burns framing and crops.
- `VNDetectFaceCaptureQualityRequest`: a 0–1 face capture score for comparing shots
  of the same subject, usable to pick a best frame without face identity.
- `VNFeaturePrintObservation.computeDistance`: image similarity for dedupe (Otos
  already clusters near-duplicates, ADR 0042).
- `AVVideoComposition.Configuration` (macOS 26+; `AVMutableVideoComposition` is
  deprecated in 26.0), plus `AVVideoCompositionCoreAnimationTool` or a custom
  `AVVideoCompositing` for crossfades, Ken Burns and titles in an exported movie.
- PhotoKit exposes no Memories: `PHAssetCollectionType` is only `album`,
  `smartAlbum` and `moment`, and no subtype names memories. This is inferred from
  the complete enum lists. It does not matter to a folder library.
- No public Apple API for beat detection or licensed music was found.

## Sensitivity: the lesson every product learned the hard way

- In 2014 Facebook's Year in Review framed a user's daughter, who had died that year,
  in confetti under "here's what your year looked like!". Eric Meyer called it
  "inadvertent algorithmic cruelty" and proposed never pre-filling a celebratory
  frame without the user opting in. Facebook apologised; date and people filters
  followed in October 2015.
- Meta's 2016 engineering post: exes and blocked people filtered automatically,
  dismissed memories never return, blocklists of people and dates apply to every
  surface, and the emotional value of a memory changes over time.
- Pinter et al. (CSCW 2019): people filters miss the "social periphery" of an ex's
  family and friends. Grief and gender-based-violence studies report retraumatizing
  resurfacing.
- Google built hide-people, hide-dates (single day or range), remove-photo and
  remove-memory controls explicitly for breakups and losses, with GLAAD and
  transgender users.
- Apple keeps a hidden, non-overridable list of sensitive locations (initially 12
  Holocaust sites) excluded from Memories, criticised as opaque "memory management".
- Complaints that recur in Apple, Google, Immich and OneDrive feedback: repetitive or
  overlapping memories, notification spam, painful resurfacing that is hard to undo
  (Apple's undo is reset-everything-then-re-hide), late imports missing from a
  snapshot (Immich #19596).

Without face recognition, the effective controls are date and date-range hiding,
per-item removal, per-memory removal, "fewer like this", and a full off switch; Pinter
et al. suggest date controls matter more than people controls anyway.

## Per-product notes

- **Apple Photos.** iOS 18 merged everything into one page with a daily carousel;
  iOS 26 reverted to Library and Collections tabs, with Memories, Trips, People &
  Pets and Featured content inside Collections. Mac keeps Memories in the sidebar.
  Memories are autoplay movies with Memory Mixes (song + look), short/medium/long
  length, and editable title, items and music. Memory Maker (Apple Intelligence,
  iOS 18.1+) builds a chaptered movie from a typed prompt. Controls: Feature Less
  (memory, person, date, place), Feature Fewer Memories Like This, Don't Feature a
  person, Show Holiday Events, Reset Suggested Memories. Analysis is on device.
- **Google Photos.** A carousel above the grid; swipe between memories, tap through
  items, background music mutable per memory or globally. Types are settable as
  time-based, themed and shared-with-you. December Recap with statistics, editable
  since 2025. Creations (collages, animations, cinematic photos, highlight videos
  synced to the beat) live in a Create tab. Computed in Google's cloud.
- **Samsung Gallery.** A Stories tab, auto-created (toggle "Auto create stories") or
  from a prompt; music themes, filters, save as video. Complaints: music changes on
  its own, the next story autoplays.
- **Instagram.** Stories (24 h, up to 60 s continuous video since 2022), private
  Archive, Highlights (named permanent story collections with a cover), "On This Day"
  resharing, Instants (2026, close friends, private archive with "Create recap").
- **Facebook.** On This Day (2015), Memories page (2018) with friendversaries and
  recaps; ML ranking on past shares and dismissals, years ago and content type;
  memories cannot be switched off, only their notifications.
- **Snapchat.** Flashbacks from saved Snaps one year ago to the day, never from
  My Eyes Only; year-end Recap (December 2025). The September 2025 storage paywall on
  Memories drew a backlash.
- **BeReal.** A private calendar of past BeReals; a 2022 Recap video with no music,
  made to be reposted elsewhere.
- **Timehop, Day One, 1 Second Everyday, Apple Journal.** Exact-date resurfacing with
  hide-memory and mute-year controls (Timehop); On This Day per entry, with "last
  week / last month" windows declined (Day One); one clip per day stitched into a
  movie (1SE); on-device journaling suggestions the user chooses from (Journal).
- **Immich.** Server-side nightly snapshot for today ± 3 days, generated once per
  day; types `on_this_day` and `birthday` (v3.3.0, 2026-10-07); unsaved memories
  deleted after 30 days. `GET /memories?for=<date>` with `isSaved`, `seenAt`,
  `showAt` and `hideAt`. A memory lane strip above the timeline, a story viewer, and
  iOS and Android widgets. Controls: save, remove memory, remove photo, disable,
  still duration.
- **Ente.** Computed on device (it is end-to-end encrypted): people, trips, CLIP
  themes, time, filler and on-this-day memories; music; share a memory as a link
  (April 2026). Without its ML switched on only time, trip and filler memories run.
- **Nextcloud Memories, LibrePhotos, PhotoPrism, Mylio.** Live-queried On This Day
  (Nextcloud, LibrePhotos, Mylio's By Day filter, all uncurated beyond exclusions);
  PhotoPrism Moments by place and year or by label. Synology Photos, QNAP QuMagie
  and Lychee have none.
- **OneDrive and Windows Photos.** On this day emails and push with music
  slideshows; Windows Photos (October 2026) adds named Moments for OneDrive photos,
  seasonal recaps, and On this day across local, OneDrive and iCloud.
- **Video auto-editors.** GoPro Quik (HiLight tags, beat-synced), DJI LightCut
  (maintenance ended September 2026), Insta360 FlashCut (refuses clips under 3 s),
  CapCut AutoCut (beat, speech or prompt), iMovie Magic Movie and Storyboards
  (created on iPhone and iPad only, importable on Mac), Clipchamp auto compose. All
  start from a set the user picked, assemble to a template with beat sync, and allow
  reorder, delete and music or style swaps afterwards. Apple Clips was pulled
  2025-10-10; Premiere Rush ends 2026-09-30.

## What this means against Otos's principles

Facts about Otos that constrain any design, stated so a later plan does not have to
rediscover them. None of this is a decision.

- **Signals Otos already has without faces**: capture instant, GPS places (ADR 0040),
  near-duplicate clusters (ADR 0042), Live Photos as one item (ADR 0041), edit
  recipes (ADR 0036), video, and read-only Immich accounts (ADR 0046). That covers
  on-this-day, windowed anniversaries, trips relative to home, recent events, best of
  a period, places and best-of-burst picking — the units every product ships
  without faces.
- **The filesystem is the truth and overlay has one lifecycle** (ADR 0008). Immich's
  snapshot model is exactly what its users complain about (late imports never
  appear). A projection recomputed from the catalog, like Nextcloud and LibrePhotos
  do, keeps a memory consistent with the files; anything stored per memory (a
  dismissal, a hidden date range) would be overlay with the ordinary lifecycle.
- **No ratings, labels or albums** (owner, 2026-10-31). Two common features cross
  that line and are out of scope as stated: Instagram-style Highlights and
  "save/favourite a memory" (Immich `isSaved`) are user albums by another name, and
  Apple and Google rank favourited items higher; Otos's counterpart is the Liked choice, which
  On This Day already ranks first.
- **No audio-specific playback.** Every movie-style memory ships a music soundtrack.
  A soundtrack is audio-specific playback, so a movie-style memory in Otos would
  play a video's own sound only, or the principle would have to change first.
- **Byte reads never accidentally materialize.** Quality scoring (aesthetics,
  saliency, face quality) reads pixels; it would run through enrichment and the
  materialization coordinator like any other byte consumer, and a memory could only
  rank on scores already computed.
- **The Immich memories API** is a ready source for Immich-backed items
  (`GET /memories`), but its selection is date-only with no quality filter.
- **Notifications** are the top complaint everywhere; a desktop app has no reason to
  push them.

## Sources

Primary vendor and code sources:

- Apple Photos Tech Brief, Sept 2019: https://apple.com/ph/ios/photos/pdf/Photos_Tech_Brief_Sept_2019.pdf
- Apple Machine Learning Research, iconic scenes: https://machinelearning.apple.com/research/scenes-differential-privacy
- Apple Support, Memories on Mac: https://support.apple.com/guide/photos/pht165ab8150/mac and https://support.apple.com/guide/mac-help/mchl35c53342
- Apple Newsroom, iOS 18 Photos: https://www.apple.com/newsroom/2024/06/ios-18-makes-iphone-more-personal-capable-and-intelligent-than-ever/
- Apple Newsroom, iMovie Storyboards and Magic Movie: https://www.apple.com/newsroom/2022/04/apple-introduces-new-version-of-imovie-featuring-storyboards-and-magic-movie
- Apple Newsroom, Journal: https://www.apple.com/newsroom/2023/12/apple-launches-journal-app-a-new-app-for-reflecting-on-everyday-moments/
- Apple tvOS guide, Memories screensaver: https://support.apple.com/guide/tv/atvb4928b087/tvos
- Vision aesthetics: https://developer.apple.com/documentation/vision/calculateimageaestheticsscoresrequest
- Vision saliency: https://developer.apple.com/documentation/vision/vngenerateattentionbasedsaliencyimagerequest
- Vision face capture quality: https://developer.apple.com/documentation/vision/vndetectfacecapturequalityrequest
- Vision feature prints: https://developer.apple.com/documentation/vision/vnfeatureprintobservation
- AVVideoComposition.Configuration: https://developer.apple.com/documentation/avfoundation/avvideocomposition/configuration
- PhotoKit collection types: https://developer.apple.com/documentation/photos/phassetcollectiontype and https://developer.apple.com/documentation/photos/phassetcollectionsubtype
- Google Photos Memories help: https://support.google.com/photos/answer/9454489
- Google blog, memories controls (2021): https://blog.google/products/photos/new-memories-features-look-back/
- Google blog, 2025 Recap: https://blog.google/products/photos/google-photos-2025-recap/
- Google Nest ambient curation: https://support.google.com/googlenest/answer/9136992
- Samsung Stories: https://www.samsung.com/us/support/answer/ANS10004859/
- Huawei Gallery Highlights: https://consumer.huawei.com/en/support/content/en-us15994472
- Meta Engineering, On This Day (2016): https://engineering.fb.com/ai-research/engineering-for-nostalgia-building-a-personalized-on-this-day-experience/
- Meta, On This Day launch (2015): https://about.fb.com/news/2015/03/introducing-on-this-day-a-new-way-to-look-back-at-photos-and-memories-on-facebook/
- Instagram Highlights and Archive: https://about.instagram.com/blog/announcements/introducing-stories-highlights-and-stories-archive
- Instagram Instants: https://about.instagram.com/blog/announcements/introducing-instants-for-sharing-in-the-moment
- Snap Recap 2025: https://newsroom.snap.com/snapchat-recap-2025?lang=en-US
- Immich memory service, repository, DTOs and controller: https://github.com/immich-app/immich/blob/main/server/src/services/memory.service.ts, https://github.com/immich-app/immich/blob/main/server/src/repositories/asset.repository.ts, https://github.com/immich-app/immich/blob/main/server/src/dtos/memory.dto.ts, https://github.com/immich-app/immich/blob/main/server/src/controllers/memory.controller.ts
- Immich snapshot design discussion: https://github.com/immich-app/immich/issues/19596
- Immich v3.3.0 birthday memories: https://immich.app/blog/v3.3.0-release
- Ente memories: https://github.com/ente-io/ente/blob/main/rust/crates/photos/src/memories/on_this_day.rs and https://github.com/ente-io/ente/blob/main/rust/crates/photos/src/memories/trips/mod.rs
- Nextcloud Memories On This Day: https://github.com/pulsejet/memories/blob/master/src/services/dav/onthisday.ts
- LibrePhotos memories: https://docs.librephotos.com/docs/user-guide/memories
- PhotoPrism Moments: https://docs.photoprism.app/user-guide/organize/moments/
- Mylio On This Day: https://inspire.mylio.com/on-this-day-rediscover-memories-with-mylio-photos/
- OneDrive memories: https://support.microsoft.com/en-us/onedrive/how-to-turn-off-onedrive-memories
- Windows Photos (October 2026): https://blogs.windows.com/windowsexperience/2026/10/15/meet-the-new-photos-app-on-windows-11/
- Lightroom Assisted Culling: https://helpx.adobe.com/lightroom/desktop/organize-photos/assisted-culling.html
- Timehop notifications: https://help.timehop.com/article/751-how-to-manage-timehop-notifications
- Day One On This Day: https://dayoneapp.com/guides/tips-and-tutorials/on-this-day/
- 1 Second Everyday: https://help.1se.co/en/articles/966670-what-is-1-second-everyday
- Insta360 FlashCut: https://onlinemanual.insta360.com/oner/en-us/editing/flashcut
- CapCut AutoCut: https://www.capcut.com/help/auto-cut-in-capcut
- Clipchamp auto compose: https://support.microsoft.com/clipchamp/how-to-use-video-auto-composition

Research and press:

- Eric Meyer, "Inadvertent Algorithmic Cruelty" (2014): http://meyerweb.com/eric/thoughts/2014/12/24/inadvertent-algorithmic-cruelty/
- Pinter et al., CSCW 2019: https://doi.org/10.1145/3359172
- The Conversation on Apple's sensitive locations: https://theconversation.com/apples-2022-decision-to-exclude-holocaust-sites-from-its-memories-feature-raised-red-flags-about-memory-management-230158
- TechCrunch, Instagram Create mode and On This Day (2019): https://techcrunch.com/2019/10/08/instagram-create-mode/
- TechCrunch, Facebook memory filters (2015): https://techcrunch.com/2015/10/13/facebook-now-helps-you-get-rid-of-memories
- 9to5Google, Memories tab became Moments: https://9to5google.com/2024/11/28/google-photos-memories-moments
- AppleInsider, iOS 26 Photos tabs: https://appleinsider.com/articles/25/06/12/photos-in-ios-26-brings-back-tabs-and-generates-spatial-photos
- MacRumors, Clips discontinued: https://www.macrumors.com/2025/10/11/apples-clips-app-discontinued/
- PetaPixel, Instagram 60-second stories: https://petapixel.com/2022/09/26/instagram-users-can-now-post-60-second-uninterrupted-stories
