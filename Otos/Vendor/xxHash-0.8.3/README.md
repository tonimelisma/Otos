# xxHash v0.8.3

This directory vendors the upstream `xxhash.c` and `xxhash.h` implementation from
the signed `v0.8.3` release at commit `e626a72`. Otos uses only the streaming
XXH3-128 API and the canonical conversion API through `Support/OtosXXH3.c`.

Upstream source: https://github.com/Cyan4973/xxHash/tree/v0.8.3
Release: https://github.com/Cyan4973/xxHash/releases/tag/v0.8.3

The upstream BSD-2-Clause license is retained in `LICENSE`.
