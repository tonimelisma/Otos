# Otos Documentation

This directory is the canonical documentation home for Otos. Root markdown is
limited to project entry points such as `README.md` and `AGENTS.md`.

When docs conflict with code, inspect the code before changing behavior. When
living docs conflict with each other, fix the documentation conflict in the same
increment as the behavior change.

## Current Authoritative Contracts

| Document | Owns | Update when |
| --- | --- | --- |
| [AGENTS.md](../AGENTS.md) | Agent workflow, non-negotiable principles, CI/PR rules, and Definition of Done. | Development workflow, gate policy, or repo-wide engineering rules change. |
| [requirements.md](requirements.md) | Implemented current requirements, active process requirements, current-increment changes, retired requirements, acceptance examples, and verification evidence. | Any non-micro behavior change, bug fix, feature, refactor, regression guard, or workflow change changes current requirements. |
| [process/development-workflow.md](process/development-workflow.md) | Work classification, Definition of Ready, worktree discipline, retirement proof, and landing expectations. | Increment workflow or PR readiness rules change. |
| [process/code-smells.md](process/code-smells.md) | Swift/macOS code-smell review guidance and DoD reporting expectations. | Review heuristics, Swift/macOS smell categories, or source references change. |
| [process/testing.md](process/testing.md) | AI-aware macOS testing strategy and verification layers. | Test strategy, test commands, or acceptance evidence expectations change. |
| [process/performance.md](process/performance.md) | Jank detection and performance evidence using the repo's OSLog/signpost and Instruments tooling. | Instrumentation categories, profile scripts, or performance budgets change. |
| [process/apple-docs.md](process/apple-docs.md) | Apple documentation grounding workflow and citation expectations. | The Apple documentation helper or citation policy changes. |

## Planning Documents

Planning documents can contain future ideas, wild concepts, abandoned options,
candidate requirements, and research notes. They are not proof that behavior
exists, they are not commitments, and they must not guide agent work unless the
user explicitly asks to use them for the current task.

| Document | Owns | Update when |
| --- | --- | --- |
| [product/roadmap.md](product/roadmap.md) | Non-authoritative idea and planning notes that may include concepts never meant to be implemented. | The user explicitly asks to record, revise, or use roadmap/planning material. |

## Templates

| Template | Purpose |
| --- | --- |
| [templates/spec-template.md](templates/spec-template.md) | Decision-complete implementation specs. |
| [templates/adr-template.md](templates/adr-template.md) | Architecture decision records. |

## Deferred Docs

Architecture, accessibility, and onboarding docs are deferred until the app has
enough real product and code structure for those documents to be useful. Do not
create placeholders that merely restate `AGENTS.md`.
