# Face Fixtures: Sources

Real portraits for the face tests (ADR 0047). Every one is a work of the United States
federal government, in the public domain, downloaded from Wikimedia Commons on 2026-11-10.
They were scaled to 1,000 px on the long side and their metadata was removed.

Two photos show one person twelve years apart and the third shows someone else, so a test
can check that the real detector and embedding model put the same person nearer than a
different one.

| File | Subject | Source | Licence |
| --- | --- | --- | --- |
| `williams-2006.jpg` | Sunita Williams, NASA portrait | [File:Sunita Williams.jpg](https://commons.wikimedia.org/wiki/File:Sunita_Williams.jpg), NASA | Public domain |
| `williams-2018.jpg` | Sunita Williams, NASA portrait, 2018 | [File:Sunita Williams in 2018.jpg](https://commons.wikimedia.org/wiki/File:Sunita_Williams_in_2018.jpg), NASA | Public domain |
| `obama-2013.jpg` | Michelle Obama, official portrait, 2013 | [File:Michelle Obama 2013 official portrait.jpg](https://commons.wikimedia.org/wiki/File:Michelle_Obama_2013_official_portrait.jpg), White House, Chuck Kennedy | Public domain |

Never add a photo of a private person here: the labelled set the face rules were measured
on lives outside the repository (`docs/research/2026-11-07-face-recognition-models.md`).
