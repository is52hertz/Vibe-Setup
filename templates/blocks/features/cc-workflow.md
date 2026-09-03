<FEATURE id="cc-workflow">
---

## Claude Code only — external executor (Codex) co-work

The detailed orchestration workflow lives in **`CC-Cowork-Workflow.md`** (repo root) — not inlined here, to keep every-session context lean.

**Load `CC-Cowork-Workflow.md` when:**

- the user asks to delegate execution or code review to Codex, mentions `/codex:*`, or asks about the external-executor / co-work flow; **or**
- Claude judges a task would benefit from delegating execution or from an independent (author ≠ reviewer) review, and is about to suggest it to the user.

It is Claude-Code-only (depends on the `/codex:*` plugin) — keep it out of `AGENTS.md` and `.trellis/`.
</FEATURE>
