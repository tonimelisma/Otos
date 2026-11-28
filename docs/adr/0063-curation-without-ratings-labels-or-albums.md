# 0063. Curation without star ratings, color labels or albums

- Status: accepted
- Date: 2026-10-31

## Context and problem

Photo managers offer several curation tools at once: star ratings, color labels, flags and
user albums. Each is a second way to say what a photo is worth or where it belongs, and every
one needs its own filters, menus, sort keys and storage. Otos already curates with Liked, Not
Rated and Disliked (ARC-054) and organizes by the user's own folders.

## Decision drivers

- One user action has one implementation path, and one way to express a judgement.
- The user's folders are the organization (ADR 0008); Otos invents no parallel hierarchy.
- Simplicity is a requirement.

## Considered options

### Liked, Not Rated, Disliked only (chosen)

- Good: one judgement, three states, one filter.
- Bad: users coming from Lightroom lose stars and labels.
- Failure modes: none beyond a missing feature.

### Add star ratings and color labels

- Good: familiar from Lightroom and Photos.
- Bad: two more overlays with their own lifecycles, filters and UI; overlapping meaning.
- Failure modes: inconsistent curation across tools.

### Add user albums or collections

- Good: grouping without moving files.
- Bad: a second hierarchy beside the folders, which Otos would then own.
- Failure modes: albums diverge from the folders they were made from.

## Decision

Otos never builds star ratings, color labels, or user albums or collections. Curation is
Liked, Not Rated and Disliked only. These are not ideas to revisit.

## Consequences

Filters, menus and the catalog schema stay without rating, label or album concepts. A request
for one is answered with this ADR.

## Confirmation

Review rule: a change that adds a rating, label or album concept contradicts this ADR and is
refused or supersedes it in the same PR.

## Retirement proof

A superseding ADR that shows a user need Liked/Disliked and folders cannot meet.

## Reversal plan

A new overlay table and its UI, designed in a superseding ADR; nothing existing has to change.
