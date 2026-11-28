# SwiftFormat's rule time limit on a loaded runner (2026-11-25)

## What failed

The `SwiftFormat And SwiftLint` job on `ubuntu-24.04` (CI for tonimelisma/Otos#4, 303e2143)
failed with `error: docComments rule timed out in OtosKit/Stores/CatalogSchema.swift`,
exit 70. The file was unchanged, and the same job had passed on every run before it that day.

## How SwiftFormat limits a rule (0.62.1 source)

- `applyRules` (`Sources/SwiftFormat.swift:626`) runs each rule on a serial queue and waits
  `options.timeout + tokens / 1000` seconds of wall-clock time for it. Past that it throws
  `"<rule> rule timed out"`. `timeout` defaults to 1 and is not an option the CLI or
  `.swiftformat` can set (`Options.swift:1242` drops it from the option list).
- The CLI formats every file at once unless `--verbose` is given
  (`CommandLine.swift:1131`, `concurrent: !verbose`).

## Measured (cloud VM, 4 cores, uncached)

- CatalogSchema.swift alone, every rule: 5.3 s. Its longest comment block is 30 lines.
- The tree, concurrent: 91 s. One file at a time (`--verbose`): 191 s. Four cores bought
  2.1×: the files contend for the cores, and a rule's wall-clock wait includes the other
  files' work.

## Finding

The rule was not slow. Under the CLI's concurrency on a shared runner, a rule waited behind
the other files' rules past its wall-clock limit. The limit measures the machine, not the
rule.

## Change

`script/lint-tools.sh swiftformat-lint <path>` lints one file at a time and drops the
per-file progress lines. `script/lint.sh` (the Ubuntu job) and `script/check.sh`'s fast gate
both use it. On the test Mac SwiftFormat's cache keeps a lint to the files that changed;
on a fresh runner the lint costs about 100 s more.
