<#
  skill-effort.psd1 -- mechanical-skill effort overrides for route-hint.ps1.

  Each entry maps a skill to a thinking tier and the distinctive phrases that
  signal it. route-hint.ps1 applies these as an OVERRIDE-DOWN only: when one of
  the phrases leads the prompt (within the first ~60 chars) and the prompt
  carries no competing work signal, the tier is capped to the listed value.
  It never escalates. The guard set (no strong/subagent/medium keyword, no
  numeric pick, not a question-back or negation) lives in the hook.

  Tiers are seeded empirically from scripts/harvest-skill-effort.ps1
  (2026-06-15 harvest, 30d): each skill below ran with low and low-variance
  output -- end-session median 264 over 113 calls, the comfyui/ollama/glados
  lifecycle skills all <2k median -- so 'none' is the right floor. The harvest's
  occasional high tails (tear-down-then-do-more bundles) are filtered by the
  hook's guards, not by tier.

  AUTO-REGISTER RULE (global): when a new skill or MCP tool is created in any
  repo, add a provisional row here, tier seeded from its expected output, and
  let the weekly analyzer confirm. Mechanical/lifecycle skills -> 'none';
  heavy ones (security-review, code-review ultra) belong in a separate
  anchor-UP table, not here.

  Phrases are matched lowercased as leading substrings. Keep them distinctive
  enough not to collide with real-work prompts.
#>
@{
  'end-session'     = @{ tier = 'none'; phrases = @('end session', 'end the session') }
  'restart-claude'  = @{ tier = 'none'; phrases = @('restart claude', 'hrcc', 'reload claude') }

  'comfyui-stop'    = @{ tier = 'none'; phrases = @('stop comfyui', 'comfyui stop', 'comfyui-stop', 'stop comfy', 'tear down comfyui', 'tear down comfy') }
  'comfyui-start'   = @{ tier = 'none'; phrases = @('start comfyui', 'comfyui-start', 'start comfy', 'fire up comfy', 'launch comfyui') }
  'comfyui-restart' = @{ tier = 'none'; phrases = @('restart comfyui', 'comfyui-restart', 'restart comfy', 'reload comfyui', 'bounce comfy') }
  'comfyui-status'  = @{ tier = 'none'; phrases = @('comfyui status', 'comfyui-status', 'is comfyui', 'is comfy running', 'is comfy up') }

  'ollama-start'    = @{ tier = 'none'; phrases = @('start ollama', 'ollama-start', 'launch ollama', 'fire up ollama') }
  'ollama-stop'     = @{ tier = 'none'; phrases = @('stop ollama', 'ollama-stop', 'tear down ollama', 'quit ollama') }
  'ollama-restart'  = @{ tier = 'none'; phrases = @('restart ollama', 'ollama-restart', 'reload ollama', 'bounce ollama') }
  'ollama-status'   = @{ tier = 'none'; phrases = @('ollama status', 'ollama-status', 'is ollama running', 'is ollama up') }

  'glados-stop'     = @{ tier = 'none'; phrases = @('stop glados', 'glados-stop', 'tear down glados', 'kill glados', 'shut down glados') }
  'glados-start'    = @{ tier = 'none'; phrases = @('start glados', 'glados-start', 'launch glados', 'bring glados up') }
  'glados-restart'  = @{ tier = 'none'; phrases = @('restart glados', 'glados-restart', 'reload glados', 'bounce glados') }

  'acc-swap'        = @{ tier = 'none'; phrases = @('/acc-swap', 'acc-swap', 'swap account', 'switch account', 'swap to primary', 'swap to reserve') }

  # PROVISIONAL (added 2026-08-11 alongside the skill; no harvest data yet).
  # Commit + fast-forward main + push, mid-session. Mechanical: whatever thinking
  # it needs goes into the commit message, and that message is about work already
  # reasoned about upstream. It is 'end-session' (median 264 over 113 calls) minus
  # the SESSION.md write, so 'none' is if anything generous. Phrases are kept
  # tight - 'cffp' is distinctive, and the spelled-out forms lead a prompt only
  # when they ARE the whole request; 'commit this and then <more work>' is caught
  # by the hook's competing-work guard rather than by leaving the phrase out.
  'cffp'            = @{ tier = 'none'; phrases = @('cffp', '/cffp', 'commit ff push', 'commit fast-forward push', 'commit and push to main') }

  # PROVISIONAL (added 2026-08-14 alongside the skill; no harvest data yet).
  # Wind down in-flight work and yield. Mechanical by construction: the skill
  # forbids new work, and its whole output is a short done/in-flight/next report.
  # Strictly less than 'end-session' (median 264), which also commits, pushes and
  # writes SESSION.md, so 'none'.
  # Bare 'stop' is deliberately EXCLUDED - it leads 'stop ollama', 'stop comfy'
  # and 'stop glados' (own rows above) and plenty of real-work prompts. Every
  # phrase here is either punctuated ('/stop') or qualified ('soft stop', 'stop
  # cleanly'), so it cannot swallow a lifecycle skill's prompt.
  'soft-stop'       = @{ tier = 'none'; phrases = @('/stop', 'soft stop', 'soft-stop', 'stop cleanly', 'wind down', 'wait a bit', 'hold on') }
}
