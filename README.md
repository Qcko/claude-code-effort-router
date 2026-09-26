# Claude Code Effort Router

A `UserPromptSubmit` hook for [Claude Code](https://claude.com/claude-code) that scores every prompt and adds **reasoning-depth guidance** to the turns that need it. Trivial prompts get nothing, harder ones get an explicit instruction to think them through, and research-heavy prompts get a nudge to spawn a Task subagent. The guidance nudges depth *within* the session's effort level; it does not change the effort itself, which only you can set (`/effort`, the model picker, `--effort`).

## Background: why a hook, not an MCP server

This repo started as an MCP server that tried to swap Claude Code's model based on task complexity. That approach doesn't work — an MCP tool can only return strings to Claude, not reconfigure the host. The driver model is fixed at session launch and can only be changed by `/model` or relaunching with `--model`.

The hook then injected Claude Code's thinking trigger words (`think`, `think hard`, `ultrathink`) into each turn's context. **That no longer does what it used to** (verified 26-09-2026 against Claude Code 2.1.281 and its docs). Current models think adaptively and have no thinking budget for a keyword to set. Claude Code now recognises only `ultrathink`, and only when *you* type it. `think` and `think hard` are ordinary words, and a hook-injected `ultrathink` is never detected. Effort (`low` to `max`) is the only real depth control, and a hook cannot set it.

What a hook *can* do is add text to the turn. So since emit version 2 the router emits a plain instruction per tier ("think this through before acting: consider alternatives...") instead of a bare keyword. It works as ordinary steering text, cache-safe because it is appended to the newest turn.

## How it works

1. You launch Claude Code with Opus as the driver: `claude --model opus`. The unversioned alias always resolves to the newest Opus, so this step never goes stale.
2. On every prompt, Claude Code runs [hooks/route-hint.ps1](hooks/route-hint.ps1).
3. The script scores the prompt (keywords + length + file refs), maps the score to a tier, and prints a short context block: a status line, a depth instruction for the upper tiers, and an optional task-shape hint (`[refactor]`, `[debug]`, ...).
4. Claude reads that block as ordinary context for the current turn only. It steers how carefully the model works within the session's effort level.
5. Each decision is appended to `$env:USERPROFILE\.claude\hooks\routing-log.jsonl` (one log across all your projects) so you can tune the keyword sets later.

### Mechanical-skill override

Some prompts invoke skills whose effort is intrinsically tiny no matter how they're phrased — service lifecycle (`start`/`stop`/`restart`/`status`), `end-session`, `restart-claude`. Generic scoring signals (e.g. a leading "lets") were over-serving these. [hooks/skill-effort.psd1](hooks/skill-effort.psd1) is an **override-DOWN allowlist**: when one of a skill's distinctive phrases leads the prompt *and* the prompt carries no competing work signal (no strong/medium keyword, no numeric pick, not a question-back or negation), the tier is capped to the listed value (`none`). It never escalates, so a bundled `lets do 2 and then end session` keeps its real-work score. Each override is tagged in the routing log (`mechanical=<skill>`) so the weekly analyzer can audit it. Tiers are seeded empirically by [scripts/harvest-skill-effort.ps1](scripts/harvest-skill-effort.ps1), which mines transcripts for phrase→invocation→output-token evidence.

### Tier mapping

Tier names are internal labels kept for continuity with the routing log; none of them is emitted as a keyword.

| Score | Tier         | Emitted (emit version 2)                                                 |
|------:|--------------|--------------------------------------------------------------------------|
|  < 1  | (none)       | Nothing.                                                                 |
|  1-3  | `think`      | Status line only. A depth line is withheld until the v2 data shows it pays. |
|  4-6  | `think hard` | `[auto-router: high depth]` - think it through, weigh alternatives and edge cases, verify changed code before calling it done, keep the reply concise. |
|  >= 7 | `ultrathink` | `[auto-router: maximum depth]` - compare approaches before committing, consider failure modes, verify changed code, put the depth into reasoning rather than reply length. |

When the session effort (`CLAUDE_EFFORT`) is already `high`, `xhigh`, `max` or `ultracode`, the depth line is left out: the model already reasons at that depth, and extra "think harder" text is the documented path to overthinking. Task-shape hints are still emitted. An unset effort is treated as low.

For the full keyword lists, score inputs, and the rationale for these specific tiers, see [docs/efforts.md](docs/efforts.md).

## Repository layout

```
hooks/
├── route-hint.ps1          # Scoring + hint-emitting script (UserPromptSubmit hook)
└── skill-effort.psd1       # Override-DOWN allowlist: mechanical skills -> low tier (deploy alongside the hook)

scripts/
├── analyze-routing.ps1     # Join routing-log.jsonl with session transcripts; flag mis-routings
├── harvest-skill-effort.ps1 # Mine transcripts for phrase->invocation->output evidence (seeds skill-effort.psd1)
├── run-analyzer.ps1        # Wrapper that writes analyzer output to a dated log file
└── smoke-route-hint.ps1    # End-to-end smoke test of the hook in a child PowerShell 5.1 (throwaway log)

DESIGN.md                   # Design: prompt -> score -> tier -> emitted text, with the evidence

docs/
└── efforts.md              # Reference: the four tiers, what each emits, and how the hook picks one
```

## Setup

Prerequisite: Windows PowerShell 5.1 or later (preinstalled on Windows 10/11).

The hook is meant to fire in **every Claude Code session**, not just sessions opened in this repo. Install it user-globally:

```powershell
git clone https://github.com/Qcko/claude-code-effort-router.git
cd claude-code-effort-router

# 1. Copy the script (and its override table) to your user-global Claude folder
#    so they survive repo moves. skill-effort.psd1 must sit beside the hook.
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.claude\hooks" | Out-Null
Copy-Item hooks\route-hint.ps1    "$env:USERPROFILE\.claude\hooks\route-hint.ps1"    -Force
Copy-Item hooks\skill-effort.psd1 "$env:USERPROFILE\.claude\hooks\skill-effort.psd1" -Force

# 2. Wire it into your user-global settings.
#    If $env:USERPROFILE\.claude\settings.json already exists, merge the "hooks"
#    block manually instead of overwriting.
@'
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"REPLACE_ME\\.claude\\hooks\\route-hint.ps1\""
          }
        ]
      }
    ]
  }
}
'@ -replace 'REPLACE_ME', ($env:USERPROFILE -replace '\\','\\') | Set-Content "$env:USERPROFILE\.claude\settings.json" -Encoding utf8
```

Now any new Claude Code session, in any project, runs the hook on every prompt. The script logs decisions to `$env:USERPROFILE\.claude\hooks\routing-log.jsonl` (each entry includes the `project` it fired in, so you can see routing behavior across all your repos in one file).

> **First run:** the first time the hook fires in a Claude Code session, Claude Code will prompt you to approve the new `UserPromptSubmit` hook command. Inspect [hooks/route-hint.ps1](hooks/route-hint.ps1) first if you didn't write it yourself — it's about 100 lines of PowerShell with no network calls or filesystem writes outside the log file.

To verify, start any Claude Code session, submit a non-trivial prompt, then run:
```powershell
Get-Content "$env:USERPROFILE\.claude\hooks\routing-log.jsonl" -Tail 1
```

### Updating after a repo change

The user-global copies at `$env:USERPROFILE\.claude\hooks\route-hint.ps1` and `skill-effort.psd1` are the live ones. After pulling new keyword tweaks or override-table rows from this repo, re-run both `Copy-Item` steps to deploy them.

## Tuning

The keyword sets and score thresholds are at the top of [hooks/route-hint.ps1](hooks/route-hint.ps1). After running with the hook for a while:

1. Open `$env:USERPROFILE\.claude\hooks\routing-log.jsonl` and look for entries where the tier feels wrong (trivial work scored as `ultrathink`, or hard work scored `none`).
2. Adjust keyword lists or score thresholds in `$env:USERPROFILE\.claude\hooks\route-hint.ps1` (or the repo copy followed by re-deploy).
3. Changes take effect on the next prompt — no restart needed.

## Analyzer (optional)

[scripts/analyze-routing.ps1](scripts/analyze-routing.ps1) reads `routing-log.jsonl` and joins each decision with the assistant turn that followed (from Claude Code's own session transcripts), flagging cases where the assigned tier probably didn't match the work — `think` prompts that produced 5k+ output, etc. Heuristics only, no LLM calls. Output is grouped by prompt preview so the same prompt run N times collapses to one row with a `hits` count.

Run it ad hoc:
```powershell
powershell -ExecutionPolicy Bypass -File scripts\analyze-routing.ps1 -Days 7
```

[scripts/run-analyzer.ps1](scripts/run-analyzer.ps1) is a thin wrapper that writes the output to `$env:USERPROFILE\.claude\hooks\routing-analysis-YYYY-MM-DD.log`. Wire it into a Windows Scheduled Task if you want a weekly digest without thinking about it.

## Limits & caveats

- **Driver model is fixed at launch.** This hook only modulates *effort* per turn. To swap models you still need `/model` or to relaunch Claude Code.
- **Guidance, not effort.** Hook output is plain context appended to your turn. It nudges depth within the session's effort level and cannot raise that level. The status line (`[auto-router] score N -> tier=ultrathink`) is informational. If you want the real `ultrathink` keyword, type it yourself.
- **Measuring it.** Every log entry records `emitVersion`, `emitted` and `sessionEffort`. The analyzer splits output by all three, so v2 turns are never averaged together with keyword-era (v1) turns.
- **Subagent suggestions are nudges, not enforcement.** Claude decides whether to actually call the Task tool. In practice this is reliable when the suggestion clearly applies, but not 100%.
- **Hook latency:** roughly 150–300 ms per prompt for PowerShell startup. Acceptable but real.
- **Privacy:** the routing log records an 80-character preview of each prompt and the project path it fired in. The file lives in your user-global Claude folder and is never committed. Delete it any time.

## Updating for new Claude versions

When a new Claude model ships, `claude --model opus` picks it up automatically; pass a full model id only if you deliberately want to pin one. The hook is model-agnostic: it emits plain steering text, which any model reads. When Claude Code's keyword or effort handling changes, re-check the "Background" facts above; the tier texts live in one table (`$depthLines`) in the hook.

## License

[Add your license here]
