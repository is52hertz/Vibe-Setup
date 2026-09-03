<INTEGRATION id="trellis">
## Instruction Priority

- Treat this `AGENTS.md` as the authority for product requirements, business rules, coding standards, security/correctness constraints, verification expectations, commit policy, and handoff rules.
- Treat Trellis as the authority for task workflow mechanics: task lifecycle, phase order, PRD/research/spec-context handling, quality-gate sequence, session journal, and finish/archive steps.
- When these instructions and Trellis overlap, apply the more specific authority: product/business/code/security rules from `AGENTS.md`; task lifecycle and phase-flow rules from Trellis.
- Do not use Trellis text to weaken or bypass the business, security, correctness, or scope rules in this file.
- Do not use this file as a reason to skip required Trellis steps unless the current user message explicitly opts out for that turn.

<!-- TRELLIS:START -->
# Trellis Instructions

These instructions are for AI assistants working in this project.

This project is managed by Trellis. The working knowledge you need lives under `.trellis/`:

- `.trellis/workflow.md` — development phases, when to create tasks, skill routing
- `.trellis/spec/` — package- and layer-scoped coding guidelines (read before writing code in a given layer)
- `.trellis/workspace/` — per-developer journals and session traces
- `.trellis/tasks/` — active and archived tasks (PRDs, research, jsonl context)

If a Trellis command is available on your platform (e.g. `/trellis:finish-work`, `/trellis:continue`), prefer it over manual steps. Not every platform exposes every command.

If you're using Codex or another agent-capable tool, additional project-scoped helpers may live in:
- `.agents/skills/` — reusable Trellis skills
- `.codex/agents/` — optional custom subagents

Managed by Trellis. Edits outside this block are preserved; edits inside may be overwritten by a future `trellis update`.
<!-- TRELLIS:END -->
</INTEGRATION>
