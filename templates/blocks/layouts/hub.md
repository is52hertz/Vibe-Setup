<LAYOUT id="hub">
## Repository Layout: Hub

This repository is a hub: it plans and coordinates the independent git repositories nested inside it. It holds documents, not product code.

### Boundaries
- **Documents only**: product direction, cross-repository contracts, task records, and shared notes live under `docs/`. No product code or build files here.
- **Sub-repositories are independent**: each nested repository has its own git history and its own `AGENTS.md`, and is listed in this repository's `.gitignore`. Never add one as a submodule or gitlink. A sub-repository must build and make sense without any file from this hub; the hub may reference sub-repository paths, never the other way round.
- **Where a document belongs**: a fact about one repository stays in that repository (`notice.md`, `docs/`). A fact spanning several repositories, or about the project as a whole, lives here.
- **Confidentiality**: this hub may record decisions that are not public (pricing, strategy). Never copy them into a sub-repository, whose history may be published.
- The rules in Development Rules apply to the documents here as they would to code: scope discipline, minimal changes, verify before committing. For a document change, verification means every repository path it cites exists and a moved document leaves no stale reference behind.

### Shared Docs
- Start at `docs/README.md`, which indexes `docs/` and says how each part is edited. A new session reads `docs/handoff.md`, then `docs/next.md`.
- Tasks for every repository live in `docs/tasks/<repository>/`, one Markdown file per task, following `docs/tasks/README.md`. Status, acceptance, and decisions are written only in the task file.
- Write each decision as `YYYY-MM-DD [user|self|实验] <decision>, <one line of why>`. An agent's proposal stays marked 「建议（未确认）」 until the user confirms it.
- A decision marked 「实现前须复核」 is settled for now but expected to be revisited: before implementing it, ask the user and argue the choice again. Only the user adds or removes the marker.
- Private agent memory is not a substitute: anything another agent or session needs goes into `docs/`.

### Planning and Dispatch
- Planning happens here; development happens in the sub-repository. Work on a sub-repository's code is done by a session, subagent, or external executor whose working directory is that sub-repository's root.
- A dispatch names the sub-repository and the task file path (`docs/tasks/<repository>/<task>.md`). The executor first reads the sub-repository's `AGENTS.md` and `notice.md` and follows them; for work inside that repository they take precedence over this file.
- A subagent started from this hub does not load the sub-repository's instructions until it touches a file there, so the dispatch prompt must tell it to read them first. An external executor (e.g. Codex) must be started with the sub-repository as its working directory, or it reads this hub's `AGENTS.md` instead.
- Git operations for dispatched work run inside that sub-repository only (`git -C <repository>`), and never touch a sibling. A hub session does not commit inside a sub-repository unless the user asks.
- When the work comes back, update the task file, `docs/next.md`, and `docs/handoff.md` here in the same round.
</LAYOUT>
