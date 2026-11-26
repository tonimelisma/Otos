# Agent instruction files (CLAUDE.md / AGENTS.md): current guidance and an audit of Otos's

Date: 2026-11-26. Sources fetched that day. [A] marks Anthropic's own docs or blog; [3P] a
third party.

## Question

`AGENTS.md` (which `CLAUDE.md` links to) had grown to 728 lines and 48,834 characters. What
do current sources say about the size, structure and wording of such a file, what belongs
in it rather than in skills, path-scoped rules, hooks or the docs it points at, and how
should one rule set serve both a cloud session and a session on the owner's Mac?

## Findings

### Size

- [A] Target under 200 lines per file: "Longer files consume more context and reduce
  adherence." `@path` imports organize a file but do not reduce its cost. Claude Code warns
  in `/status` past the recommended length. https://code.claude.com/docs/en/memory
- [A] "Every line in it takes a little of Claude's attention on every task." Keep what
  Claude cannot infer from the code: exact commands, where the code misleads, decisions not
  in the repo, anything corrected twice. Describing architecture and file layout is listed
  as something to stop doing, since Claude reads the repo itself.
  https://code.claude.com/docs/en/best-practices
- [A] Context is an attention budget; every token spends it. Prefer the "right altitude"
  and a few canonical examples to a list of edge cases.
  https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- [A] "Keep CLAUDE.md under 200 lines, give it an owner, and review changes to it like
  code." https://claude.com/blog/steering-claude-code-skills-hooks-rules-subagents-and-more
- [3P] IFScale: frontier models reach about 68% accuracy at 500 simultaneous instructions,
  and favour earlier ones. https://arxiv.org/abs/2507.11538
- [3P] Repository overviews in context files do not help task success and raise cost by
  more than 20%; files help where a project departs from common practice.
  https://arxiv.org/abs/2602.11988

### What moves out

- [A] A multi-step procedure, or guidance that applies to part of the tree, belongs in a
  skill (only its name and description load until it is used) or in a path-scoped rule
  (`.claude/rules/*.md` with `paths:` globs, loaded when a matching file is touched).
  https://code.claude.com/docs/en/memory, https://code.claude.com/docs/en/skills
- [A] "If something has to happen every time, make it a hook, a deny rule, or a managed
  setting. CLAUDE.md is for guidelines." A line that keeps needing emphasis belongs in a
  hook. Hooks cost no context unless they print. https://code.claude.com/docs/en/best-practices
- [3P] Never send a model to do a linter's job; point at `file:line` rather than pasting
  code that goes stale. https://www.humanlayer.dev/blog/writing-a-good-claude-md

### Wording

- [A] Current models follow a plainly worded line; "piling on emphasis mostly makes Claude
  over-apply the rule", and "keep going, don't be lazy" lines cause over-work.
  https://code.claude.com/docs/en/best-practices
- [A] Since Opus 4.5, models are more responsive to the system prompt: soften aggressive
  language, give the reason, say what to do rather than what not to do.
  https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices
- [A] Newer models treat an instruction containing "never" as absolute; cautions pile up in
  instruction files. "Delete cautions whose reason no longer holds, and rewrite absolute
  rules with their scope and reason." Name the steps that need no approval.
  https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5-2
- [A] With contradictory instructions "Claude may pick one arbitrarily".
  https://code.claude.com/docs/en/memory

### Cloud and local from one rule set

- [A] A cloud session loads the repository's `CLAUDE.md`, `.claude/rules/`, skills, agents
  and commands, and its `.claude/settings.json` hooks only when it has one repository. It
  never loads `~/.claude/CLAUDE.md` or user settings.
  https://code.claude.com/docs/en/cloud-environments
- [A] A setup script provisions the VM (cached as a snapshot); a SessionStart hook does
  project setup that should run everywhere, and must be idempotent. `CLAUDE_CODE_REMOTE` is
  `true` in a cloud session and unset locally. SessionStart output is added to context, so
  environment-specific notes can be printed only where they apply.
  https://code.claude.com/docs/en/hooks
- [A] A setup script on a personal environment can write `~/.claude/CLAUDE.md`, which is how
  personal preferences reach a cloud session without living in the project file.
  https://code.claude.com/docs/en/cloud-environments

## Audit of AGENTS.md as of 960d000

Measured: 728 lines, 48,834 characters, 65 lines containing "never", 47 bold spans,
eight dated owner quotes and "Done on" entries.

1. **Size.** 3.6× the recommended length. Large parts restate what has a home already:
   the catalog ownership split (`docs/architecture.md`, ADR 0004), migration cost rules
   (ADR 0002), the check heartbeat and hang diagnosis (ADR 0044, ADR 0023), the weekly
   performance verdicts (ADR 0043), Sparkle release mechanics (ADR 0059), and rules
   enforced by lints and guards (`time-guard.sh`, `error_becomes_value`,
   `unordered_main_actor_hop`, `guard-*.sh`).
2. **History in instructions.** "Owner setup" is a changelog ("Done on 2026-11-25", "Done
   on 2026-11-26"), and owner quotes with dates are scattered through rules. The reasons
   they carry belong in the ADR each rule points at.
3. **Contradictions.**
   - The copied standing rule "Live tests may write to Taylor's real apps" against Otos's
     "The owner's production data is read, never changed".
   - "Never ask whether to do it" against "Restate non-trivial captured requirements to the
     user for confirmation before relying on them".
   - "Branch with a conventional prefix" against the cloud harness, which names the branch.
   - "A session never builds, installs or develops on the owner's Mac" against the
     Definition Of Done's look, the weekly performance run and the toolchain section, which
     all assume a session on the Mac.
4. **Mac-only material in the always-loaded file.** Worktrees, the SSH deploy-key fallback,
   `script/logs.sh`, `script/profile.sh`, the production-data procedures and the weekly run
   load in every cloud session, where none of them can run.
5. **Over-emphatic absolutes.** "Engineering effort is free. Never take a shortcut", "no
   follow-up deferred to save work" and 65 "never" lines are the pattern the current
   guidance says causes over-application and over-work. The substance (blank-slate design,
   no shims, the smallest correct design) survives a plainer wording with its reason.
6. **Personal rules in a public project file.** "Taylor's Standing Rules" are copied in
   because a cloud session never reads `~/.claude/CLAUDE.md`; a personal environment's setup
   script can write that file instead.

## Conclusion

Rebuild `AGENTS.md` as a core of about 200 lines holding only what applies to every task in
every environment: what Otos is, the invariants with their reasons and ADR pointers, the one
check command, the PR and merge path, and where each kind of document lives. Move
path-specific guidance into `.claude/rules/` (Swift and concurrency, persistence, UI and
design review, scripts), procedures into skills (reading and watching CI, supervising a
check, the DoD report, a session on the Mac), and environment-specific notes into the
SessionStart hook's output. Resolve the contradictions above explicitly, and give each
remaining absolute its scope and reason.
