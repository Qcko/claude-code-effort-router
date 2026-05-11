# Session log

## 2026-05-11 — Analyzer-driven hook tuning + repo↔global sync

**Goal:** Review the weekly Windows-scheduled `analyze-routing.ps1` run, pick adjustments, and bring the repo's `hooks/route-hint.ps1` back in sync with the deployed user-global copy.

**Landed:**
- `hooks/route-hint.ps1` (repo, canonical) — overwritten to match the evolved global copy: kill-switch env var (`EFFORT_ROUTER_DISABLED`), `$execute` trigger phrases, `strongFired`/`executeFired` flags, gated trivial penalties, tighter length thresholds (≥150 instead of ≥200), broader file-ref regex (alphanumeric extensions), gated intent classifier with `$intentHints` block, and `project`/`intent` fields in the log entry.
- New behaviors added this session and present in **both** the repo file and `%USERPROFILE%\.claude\hooks\route-hint.ps1`:
  - Skip `<task-notification>` payloads before scoring or logging.
  - `+1` bonus when `refactor` matches (on top of the strong-list `+3`), so bare "refactor X" prompts clear the `think hard` boundary (≥4).
- `scripts/analyze-routing.ps1` — flagged-entries section now deduplicates by `preview` and shows a `hits` count + `last_ts`, so a prompt run N times no longer drowns out distinct misses. **Moved in-repo this session** (was previously only in `%USERPROFILE%\.claude\scripts\`).
- `scripts/run-analyzer.ps1` — thin wrapper for scheduled-task use, also moved in-repo.
- `README.md` — new "Analyzer (optional)" section + layout block updated.
- Two commits on `claude/sleepy-grothendieck-8bb29c`, pushed to origin (`0b25878`, `b37fb1c`).

**State:**
- Repo `hooks/route-hint.ps1` and deployed global hook are byte-identical aside from the header doc comment (repo says "canonical source", global says "user-global copy, edit canonical and re-deploy").
- Latest analyzer run (after dedup): 46 raw flags → 24 distinct prompts. Tier averages remain healthy: none 5.4k · think 13.5k · think hard 22.6k · ultrathink 33.5k.
- Real distinct under-served patterns still visible: "Refactor route-hint.ps1..." (48k @ think — should be cleared by the `refactor +1` bonus now), short conversational follow-ups at `think` producing 5–30k (fundamental keyword-scoring limit, not fixable here).

**Open threads:**
- **Threshold #2 (deferred):** raise the analyzer's `think hard` under-served threshold from 15k → ~30k. Current value flags healthy outputs (avg 22k, max 48k) as misses. Not applied yet — wanted a week of new data first with the refactor-bump + dedup in place.
- **1–100 rescale (deferred):** if more granularity is needed later, multiply all weights and thresholds in `hooks/route-hint.ps1` by 10 and tune at the units digit. Mechanical change, no structural impact.
- The Windows Scheduled Task that runs the analyzer (`C:\Users\komec\.claude\scripts\run-analyzer.ps1` weekly) is enabled and producing logs at `%USERPROFILE%\.claude\hooks\routing-analysis-YYYY-MM-DD.log`.

**Next:**
- After ~1 week of fresh routing data with the refactor bump in effect, re-run the analyzer and decide whether to apply threshold #2 and/or the 1–100 rescale.
- If "Refactor X" prompts still show up under-served despite the bump, the next move is to also boost length-bonus weight for `strongFired` prompts, not to keep stacking keyword bonuses.
