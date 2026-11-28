# On This Day picks: screenshots, documents and the size of a day

Date: 2026-11-13. Plan 0115 increment 5, ADR 0049. Questions: can Otos tell a screenshot or a
document from a photo with facts it already holds, and how many photos does an anniversary
hold, for choosing a cap?

## Screenshots and documents

Search already reads every thumbnail with Vision's scene classification (ADR 0048) and stores
the labels that pass Vision's own confidence (`search_embedding.confident_labels`). The
taxonomy has `screenshot`, `document`, `receipt`, `printed_page` and `whiteboard`. No new
classifier, model or platform call is needed.

On the installed catalog (read-only), 35,750 items carry labels: every still in the fixed
libraries, and 17,493 of the Immich account's, whose reading is under way.

| Confident label | Items | Without camera make | From Apple | From Sony or Nikon | PNG |
| --- | --- | --- | --- | --- | --- |
| `screenshot` | 553 | 549 | 4 | 0 | 411 |
| `document` | 848 | 806 | 37 | 0 | 493 |
| `receipt` | 31 | 27 | 4 | 0 | 0 |

A confident `screenshot` is almost never a camera's file: 549 of 553 carry no camera make,
and none comes from the reference library's Sony or Nikon. A confident `document` is the same at 806 of
848, its Apple-made ones being phone photos of paper. The confident labels are a usable
screenshot and document classification. The loose labels are not: `printed_page` and
`whiteboard` never pass the confidence gate, and loose `document` covers 3,271 items.

On This Day leaves out photos whose confident labels include `screenshot` or `document`. A
photo search has not read yet has no labels, and stays: an unknown is not a screenshot.

## How many photos a day holds

Over the 4,803 days in the catalog that hold a dated photo or video (before stacks collapse a
RAW and its JPEG):

| | Items |
| --- | --- |
| Median day | 10 |
| 75th percentile | 28 |
| 90th percentile | 80 |
| 99th percentile | 396 |
| Largest | 2,405 |

Share of days a cap would leave untouched: 56.3 % at 12, 72.9 % at 25, 84.5 % at 50.

On 13 November the anniversaries hold 3 (2016) to 42 (2017) items. A cap is a product choice
made from these numbers. The choice was 25 (2026-11-12).
