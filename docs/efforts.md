# Effort Tiers

This hook escalates Claude's per-turn **thinking budget** by injecting one of Claude Code's documented trigger words into the additional context for the current turn. Lower tiers use less reasoning; higher tiers use more. The driver model is unchanged — only effort moves.

## The four tiers

| Tier         | Trigger word in context | Behavior                                                                                                                                                                                                |
|--------------|-------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| (none)       | *(nothing emitted)*     | Default for the driver model. Minimal/no extended thinking. Used when the prompt scores as trivial.                                                                                                     |
| `think`      | `think`                 | Light thinking budget. The model takes a brief reasoning pass before responding. Suitable for prompts that imply a single coding action with one or two file references.                                |
| `think hard` | `think hard`            | Larger budget. The model reasons through trade-offs before acting. Suitable when the prompt names multiple concerns or moderate scope.                                                                  |
| `ultrathink` | `ultrathink`            | Maximum budget. The model reasons deeply before acting. Used for architecture, debugging, multi-file refactors, and any prompt scored as "complex." Optionally paired with a Task subagent suggestion. |

The trigger words above are the documented Claude Code keywords. They are recognized when present in the model's input for a given turn and increase the thinking-budget cap accordingly. They reset every turn — there is no global "ultrathink mode."

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

## Why these tiers and not "low / medium / high effort"?

Claude Code already exposes effort control through these specific trigger words. The hook stays as close as possible to that documented surface so that:

- Behavior is predictable (the trigger words have defined semantics, not implementation-defined ones).
- Updates to Claude Code's effort handling automatically benefit this hook with no code changes.
- The user can manually type `ultrathink` to force the highest tier and get the same effect the hook would.

## Combining with subagents

For prompts that score `ultrathink` *and* match a subagent-hint keyword (research-heavy, codebase-wide audit, etc.), the hook adds a routing note suggesting Claude spawn a Task subagent with `ultrathink` in its prompt. Subagents run in isolated context, which keeps the driver session focused while letting genuinely separable deep work happen in parallel. Subagents are about *isolation*, not effort — pair them with `ultrathink` when you need both.
