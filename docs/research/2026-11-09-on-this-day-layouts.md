# On This Day as a full content pane: layouts

Date: 2026-11-09. This is research for plan 0114 (closed; see ADR 0049), done after the owner placed On This Day
as a sidebar scope whose whole content pane is the collection of years. It asks what a
browsable collection of stories looks like when it is the main UI rather than a strip
above another grid.

Sources:
- Immich's web source on GitHub `main`.
- The owner's own Immich v3.3.0, from screenshots dated 2026-11-09.
- Vendor help pages and press, cited inline.

The Immich public demo (`demo.immich.app`) shows no memories today: its only memory is
dated 2025-01-25 and is visible only on that day, so the live page renders empty. It
gave no visual evidence.

## Immich

Two surfaces share one `MemoryCard` (`web/src/lib/components/memories/MemoryCard.svelte`).

**The card.**
- Aspect ratio: `aspect-3/4` on small widths, `md:aspect-4/3`, then `xl:aspect-video`
  (16:9) at desktop widths.
- Corners are `rounded-xl`. The key photo is the memory's first asset, `object-cover`.
- A bottom gradient, `from-black/40`, runs to clear.
- The title is white `text-lg` at the bottom left, "N years ago" from `memoryLaneTitle`
  in `web/src/lib/utils.ts`.
- One On This Day memory per year (`memory.data.year`).
- The owner's instance shows exactly this: three landscape cards, `1 year ago`,
  `2 years ago` and `3 years ago`, above the `Today` section of the timeline, with a
  chevron to scroll.

**The memories page** (PR #28675, August 2025,
https://github.com/immich-app/immich/pull/28675; `web/src/routes/(user)/memories/+page.svelte`).
- The same cards in a responsive grid, `grid-cols-1 md:grid-cols-2 xl:grid-cols-3
  2xl:grid-cols-4 gap-4`.
- "Upcoming" and "Current" headers, a total count, and a favourites filter.
- It is a grid of landscape cards, not circles.

**The viewer** (`MemoryViewer.svelte`, and the owner's screenshot).
- Top row: Close and the title (`1 year ago`) at the leading edge. Then Play/Pause, a
  segment bar (one dash per asset) and the position `1/20`, then mute.
- The stage is a rounded black panel. The date and place sit at its top left in white
  (`November 9, 2025`, `Walnut Creek United States`), with a heart and a menu at its top
  right.
- A Next chevron, plus an `UP NEXT · 2 years ago` peek of the next memory at 25% opacity
  at the trailing edge.
- A chevron below the stage scrolls to a grid of the memory's assets.
- Photo duration is a user preference; a video runs for its own length.

## Others

- **Apple Photos (macOS 26/27).**
  - Memories is under Collections in the sidebar. Its cards show a key photo, a title and
    a date. You play a memory, use Space and the arrow keys, and switch it to a grid
    (https://support.apple.com/guide/photos/watch-memories-pht96259d626/mac).
  - The card's geometry is unverified.
- **Google Photos.**
  - Memories is a carousel of image cards above the grid, with text at the bottom left
    (https://support.google.com/photos/answer/9454489).
  - Its full-page view was folded into Collections as Moments
    (https://9to5google.com/2025/01/13/google-photos-redesign-moments-memories/).
- **Instagram.**
  - Circles are a strip only: the Stories tray and Highlights on a profile. The circle is
    an avatar, and its ring marks unseen content
    (https://about.instagram.com/blog/announcements/introducing-instagram-stories).
  - No surveyed product uses circles as a full-page grid. A circle centre-crops a scene
    photo.
- **Ente.**
  - A strip of portrait cards: `kMemoryCardAspectRatio = 29/42`, radius 18, with a bottom
    gradient title (`mobile/apps/photos/lib/ui/home/memories/`).
  - Its full view is full-screen paging, not a grid.
- **Facebook Memories.** A vertical feed by year
  (https://techcrunch.com/2018/06/11/facebook-launches-memories-a-new-home-for-reminiscing/amp).
- **Snapchat.** One Flashback story at the top of Memories, above the regular grid.
- **Day One.** On This Day lists matching entries in the normal entry list
  (https://dayoneapp.com/guides/tips-and-tutorials/on-this-day/).
- **Timehop.** v4.0 (December 2016) replaced its by-year feed with a tap-through story.
  It drew more than 7,000 one-star reviews over cropped photos and lost scannability
  (https://www.theverge.com/2017/1/4/14168208/timehop-redesign-protest-one-star-reviews).

No source gives how many years a typical library has on a given date. One to fifteen is
an assumption.

## Candidates and conclusion

| Layout | Evidence | Verdict |
| --- | --- | --- |
| Wrapping grid of circles | None as a full page. Circles are avatars in strips, crop scene photos, and leave a few-year pane mostly empty. | Rejected |
| Grid of landscape key-photo cards, `N years ago` over a bottom gradient | Immich's memories page and strip cards; Apple's memory cards in spirit | **Chosen by the owner** |
| By-year vertical feed | Facebook; old Timehop | Scannable, but shows content inline, competing with play-to-watch |
| Hero for the newest year plus smaller cards | No exact precedent | Arbitrary hierarchy |
| Centred carousel of portrait cards | Immich's viewer peeks; Google and Ente strips | A navigation idiom inside a player, not a browse surface |

The owner chose the photo-card grid on 2026-11-09 from four options: photo cards, story
balls, a by-year feed, and a hero plus smaller cards. ADR 0049 and `docs/design/on-this-day.md` record the
card geometry Otos adopted.
