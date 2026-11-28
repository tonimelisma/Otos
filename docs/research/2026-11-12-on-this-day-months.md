# On This Day: the months fallback and how the scope is matched

- Date: 2026-11-12
- Relies on it: ADR 0049 §4, APP-069

## Question

On This Day should show photos from months ago when nothing newer is
available. What does the reference library show today, and how should the scope's SQL
match a day in earlier months?

## The reference library (read-only, installed app's catalog)

`sqlite3 -readonly` over `~/Library/Application Support/net.melisma.Otos/Catalog/catalog.sqlite`
on 2026-11-12: 19,502 items, one from June 2024 and the rest April–November 2026. Items on
the 12th: 199 (October), 254 (September), 193 (August), 67 (July) and 17 today. No earlier
year holds 12 November, so On This Day showed `Nothing on This Day` over 713 items taken on
the 12th of earlier months.

## Limits of an `OR` of day ranges

The first build matched one half-open `best_capture_local` range per earlier year; the
fallback would add one per earlier month from the earliest dated capture. With the system
SQLite (3.54.0):

| Ranges `OR`ed left to right | Result |
| --- | --- |
| 900 | runs |
| 1,100 | `Expression tree is too large (maximum depth 1000)` |
| 2,712, as a balanced tree | runs (depth ≈ 12) |

A balanced tree avoids the depth limit, but two bound arguments per range still meet
SQLite's 32,766-argument limit at about 1,360 years of months, which one item with a bogus
early date (year 1, say) reaches. One scan dated 1904 already gives 1,464 month ranges.

## Cost of a `strftime` predicate instead

`best_capture_local` is the clock's reading counted on a UTC calendar, so
`strftime('%d', best_capture_local, 'unixepoch')` is the day that clock showed, with no
zone applied. Synthetic table of 500,000 rows (one root, uniform dates 2000–2026, index on
`(x DESC, root, path)`), warm cache:

| Query | Time |
| --- | --- |
| months: `x < start of month AND strftime('%d') = '12'`, count | 106 ms |
| years: `x < start of year AND strftime('%m-%d') = '11-12'`, count | 118 ms |
| years, `EXISTS` (stops at the first row) | 0.7 ms |
| months, ordered by the index, row 16,000 | 100 ms |
| years as 26 `OR`ed ranges, count (the index answers) | 6 ms |
| years as 26 ranges, `EXISTS` | 0.1 ms |
| the reference catalog, months `strftime` count (713 rows of 19,502) | 21 ms |

## Conclusion

The `strftime` predicate is linear in the scope's rows and about 20× slower than ranges on
a 500,000-item library, but it has no size that grows with the library's span, no floor
query, and no failure mode; on the reference library it costs 21 ms off the main actor.
Otos uses it for years and months alike (`AnniversaryMatch`). Benchmark cases
`projection.windowState.onThisDay.years` and `.months` watch the cost; ranges come back
only if a measurement shows the predicate is the bottleneck.
