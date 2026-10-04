# 0105 — RAW library ownership transferred

Status: superseded here; implementation remains unfinished in its independent
repository. This file is an ownership pointer, not an executable Otos work plan.

The RAW development library owns its API, development configuration, trained looks,
SDR/HDR rendering, training data contracts, evaluation, tests and releases in
[raw-development](https://github.com/tonimelisma/raw-development).

Its current execution plan is
[Plan 0001](https://github.com/tonimelisma/raw-development/blob/main/docs/plans/0001-sony-vivid-neural-development.md),
and its capability roadmap is
[the library roadmap](https://github.com/tonimelisma/raw-development/blob/main/docs/roadmap.md).
Local checkout: /Users/example/Development/RAWDevelopment.

Otos is a future consumer at arm's length through the library's public interface.
The library must build/test/run without Otos, its installed app, catalog, logger,
source checkout or verification scripts. No app integration is implemented here.

Existing standalone research code and private corpus remain preserved in Otos
until explicitly extracted/copied with dependency and original-integrity checks.
Their presence is historical; it does not make Otos the library's owner. No source
or private media was moved by this documentation transfer. The prior complete plan
is retained in Git history; new library work follows the independent repository.
