# Claude Code Effort Router

A `UserPromptSubmit` hook for [Claude Code](https://claude.com/claude-code) that auto-tunes the **thinking budget** per turn. Trivial prompts run cheap, complex ones get escalated to `think hard` or `ultrathink`, and research-heavy prompts get a nudge to spawn a Task subagent. The driver model stays the same for the whole session — only effort changes per turn.

## Background: why a hook, not an MCP server

This repo started as an MCP server that tried to swap Claude Code's model based on task complexity. That approach doesn't work — an MCP tool can only return strings to Claude, not reconfigure the host. The driver model is fixed at session launch and can only be changed by `/model` or relaunching with `--model`.

What *does* work is modulating the per-turn thinking budget via Claude Code's documented trigger words (`think`, `think hard`, `ultrathink`). A `UserPromptSubmit` hook can inject one of those into the additional context for the current turn, escalating effort only when the prompt warrants it. That's what this repo now is.

## How it works

1. You launch Claude Code with Opus as the driver: `claude --model claude-opus-4-7`.
2. On every prompt, Claude Code runs [hooks/route-hint.ps1](hooks/route-hint.ps1).
3. The script scores the prompt (keywords + length + file refs) and prints a short context block — empty for trivial prompts, or a thinking-trigger word + reasoning hint for harder ones.
4. Claude reads that hint as additional context for the current turn only and adjusts its thinking accordingly.
5. Each decision is appended to `hooks/routing-log.jsonl` (gitignored) so you can tune the keyword sets later.

### Tier mapping

| Score | Tier         | Effect                                                                  |
|------:|--------------|-------------------------------------------------------------------------|
|  < 1  | (none)       | Hook stays silent. No extra thinking budget.                            |
|  1–3  | `think`      | Light thinking budget for the current turn.                             |
|  4–6  | `think hard` | Larger thinking budget.                                                  |
|  ≥ 7  | `ultrathink` | Maximum thinking budget. If the prompt is also research-heavy, the hook adds a one-line note recommending a Task subagent. |

Score inputs (all heuristic, tunable in the script):

- **Strong keywords** (+3): architecture, redesign, refactor, debug, investigate, root cause, race condition, deadlock, performance, optimize, security, vulnerability, comprehensive, thoroughly, system-wide, audit, across the codebase, why does, design, strategy, analyze, plan, …
- **Medium keywords** (+1): implement, build, create, add, write, generate, fix, update, modify, change, integrate, migrate
- **Trivial keywords** (-2): rename, format, show me, list, what does, what is, print, display, add a comment, tell me
- **Subagent hints** (+2 and flag): research, audit, find all, every file, all references, search the codebase, …
- **Length bonus**: ≥1500 chars +3, ≥500 +2, ≥200 +1, <60 -2
- **File refs**: ≥3 references +2, ≥1 +1

## Repository layout

```
hooks/
└── route-hint.ps1          # Scoring + hint-emitting script (UserPromptSubmit hook)

model-summary/              # Reference docs — used to seed the keyword lists, not loaded at runtime
├── README.md
├── routing-guide.md        # Decision tree for picking a tier
├── models-config.json      # Catalog of current Claude model IDs and characteristics
├── claude-haiku.md
├── claude-sonnet.md
└── claude-opus.md

.claude/
└── settings.json           # Wires route-hint.ps1 as a UserPromptSubmit hook (project-scoped)
```

## Setup

Prerequisite: Windows PowerShell 5.1 or later (preinstalled on Windows 10/11).

```
git clone https://github.com/Qcko/claude-code-effort-router.git
cd claude-code-effort-router
claude --model claude-opus-4-7
```

Claude Code picks up [.claude/settings.json](.claude/settings.json) on session start and runs the hook on every prompt. There is no build step.

To verify it's working, submit a non-trivial prompt and check `hooks/routing-log.jsonl` — you should see a JSONL entry per submitted prompt with the score and tier the hook chose.

## Tuning

The keyword sets and score thresholds are at the top of [hooks/route-hint.ps1](hooks/route-hint.ps1). After running with the hook for a while:

1. Open `hooks/routing-log.jsonl` and look for entries where the tier feels wrong (trivial work scored as `ultrathink`, or hard work scored `none`).
2. Adjust keyword lists or score thresholds in `route-hint.ps1`.
3. Changes take effect on the next prompt — no restart needed.

## Limits & caveats

- **Driver model is fixed at launch.** This hook only modulates *effort* per turn. To swap models you still need `/model` or to relaunch Claude Code.
- **Trigger words arrive as hook-injected context**, not as part of your literal user message. The hook also prints an explicit prose hint (`[auto-router] complexity score N -> applying thinking budget: ultrathink`) so Claude reasons accordingly even if the keyword detector only scans user text.
- **Subagent suggestions are nudges, not enforcement.** Claude decides whether to actually call the Task tool. In practice this is reliable when the suggestion clearly applies, but not 100%.
- **Hook latency:** roughly 150–300 ms per prompt for PowerShell startup. Acceptable but real.
- **Privacy:** the routing log records a 80-character preview of each prompt. The full file is gitignored. Delete it any time.

## Updating model IDs

When new Claude versions ship, update [model-summary/models-config.json](model-summary/models-config.json). The hook itself doesn't load this file — it's reference material — but keeping it current makes the per-model markdown profiles useful when you ask Claude "which model should I use for X?"

## License

[Add your license here]
