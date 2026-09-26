# Effort Tiers

This hook scores each prompt and maps the score to one of four **tiers**. Since emit version 2 (26-09-2026) a tier decides which **depth guidance** the hook appends to the turn as plain text. It does not set a thinking budget, and it does not change the effort level. Current Claude models think adaptively, effort (`low` to `max`, set by the user) is the only real depth control, and Claude Code recognises only a user-typed `ultrathink` as a keyword. See [../DESIGN.md](../DESIGN.md) for the flow and the evidence.

## The four tiers

The tier names are internal labels kept for continuity with the routing log. None of them is emitted as a keyword.

| Tier         | Emitted text (v2)                  | Used for |
|--------------|------------------------------------|----------|
| (none)       | *(nothing)*                        | Trivial prompts. |
| `think`      | status line only                   | A single coding action with one or two file references. A depth line is withheld until the v2 data shows it is worth the output it would add on the most frequent tier. |
| `think hard` | `[auto-router: high depth] ...`    | Multiple concerns or moderate scope, and multi-work prompts ("fix X first, then Y"). |
| `ultrathink` | `[auto-router: maximum depth] ...` | Architecture, debugging, multi-file refactors, and anything scored as complex. Optionally paired with a Task subagent suggestion. |

The exact texts live in one table, `$depthLines`, in [hooks/route-hint.ps1](../hooks/route-hint.ps1). Each asks for reasoning before acting, verification only when code or files changed, and depth in reasoning rather than in reply length. Each also tells the model to proceed directly if the task proves simpler than it looked. When the session effort (`CLAUDE_EFFORT`) is `high`, `xhigh`, `max` or `ultracode`, no depth line is emitted. Guidance resets every turn.

## How the hook chooses a tier

The hook in [hooks/route-hint.ps1](../hooks/route-hint.ps1) computes a single integer score per prompt and maps it to a tier:

| Score   | Tier         |
|--------:|--------------|
|  < 1    | (none)       |
|  1 – 3  | `think`      |
|  4 – 6  | `think hard` |
|  ≥ 7    | `ultrathink` |

Score inputs (all heuristic; tunable in the script):

- **Strong keywords** (+3 each): architecture, redesign, refactor, debug, investigate, root cause, race condition, deadlock, performance, optimize, security, vulnerability, comprehensive, thoroughly, system-wide, audit, across the codebase, why does, design, strategy, analyze, plan
- **Medium keywords** (+1 each): implement, build, create, add, write, generate, fix, update, modify, change, integrate, migrate
- **Trivial keywords** (-2 each): rename, format, show me, list, what does, what is, print, display, add a comment, tell me
- **Subagent-hint keywords** (+2 each, and flag): research, audit, find all, every file, all references, search the codebase, across the project — these also trigger a one-line note recommending a Task subagent when the tier is `ultrathink`
- **Length signal**: prompts ≥ 1500 chars +3, ≥ 500 +2, ≥ 200 +1, < 60 -2
- **File-reference signal**: ≥ 3 detected refs +2, ≥ 1 +1

Detected file refs are `@mention` patterns and dotted filenames (`foo.ts`, `Bar.cs`).

## Why tiers, and not the effort levels themselves?

The tiers were first built as a mapping onto Claude Code's thinking trigger words, which once set a thinking budget. That mechanism is gone, and a hook cannot set the effort level, so the router cannot choose `low`/`medium`/`high` for a turn. Changing effort mid-session would also cost a prompt-cache rebuild. Text appended to the newest turn is the only lever a hook has, and it is cache-safe. The tiers stay because the scoring and 4+ months of routing-log history are keyed on them.

## Combining with subagents

For prompts that score `ultrathink` *and* match a subagent-hint keyword (research-heavy, codebase-wide audit, etc.), the `[audit]` hint suggests Claude spawn a Task subagent, told explicitly to reason thoroughly. Subagents run in isolated context, which keeps the driver session focused while letting genuinely separable deep work happen in parallel. Subagents are about *isolation*, not depth.
