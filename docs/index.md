# Otos Documentation

This directory is the canonical documentation home for Otos. Root markdown is
limited to project entry points such as `README.md` and `AGENTS.md`.

When docs conflict with code, inspect the code before changing behavior. When
living docs conflict with each other, fix the documentation conflict in the same
increment as the behavior change.

## Living Contracts

| Document | Owns | Update when |
| --- | --- | --- |
| [AGENTS.md](../AGENTS.md) | Agent workflow, non-negotiable principles, CI/PR rules, and Definition of Done. | Development workflow, gate policy, or repo-wide engineering rules change. |
| [requirements.md](requirements.md) | Requirement IDs, acceptance examples, status, and verification evidence. | Any non-micro behavior change, bug fix, feature, or refactor changes observable behavior. |
| [process/development-workflow.md](process/development-workflow.md) | Work classification, Definition of Ready, worktree discipline, retirement proof, and landing expectations. | Increment workflow or PR readiness rules change. |
| [process/code-smells.md](process/code-smells.md) | Swift/macOS code-smell review guidance and DoD reporting expectations. | Review heuristics, Swift/macOS smell categories, or source references change. |
| [process/testing.md](process/testing.md) | AI-aware macOS testing strategy and verification layers. | Test strategy, test commands, or acceptance evidence expectations change. |
| [process/performance.md](process/performance.md) | Jank detection and performance evidence using the repo's OSLog/signpost and Instruments tooling. | Instrumentation categories, profile scripts, or performance budgets change. |
| [process/apple-docs.md](process/apple-docs.md) | Apple documentation grounding workflow and citation expectations. | The Apple documentation helper or citation policy changes. |

## Templates

| Template | Purpose |
| --- | --- |
| [templates/spec-template.md](templates/spec-template.md) | Decision-complete implementation specs. |
| [templates/adr-template.md](templates/adr-template.md) | Architecture decision records. |

## Deferred Docs

Product, architecture, accessibility, and onboarding docs are deferred until the
app has enough real product and code structure for those documents to be useful.
Do not create placeholders that merely restate `AGENTS.md`.
