<LAYOUT id="member">
### Task Files
- A task may arrive as a Markdown file outside this repository; the user or the dispatching session gives you its path. Read it before starting and keep to its stated scope.
- Treat that file as read-only. Its status, acceptance checkboxes, and decision records are maintained outside this repository; never edit or commit it.
- An item marked 「实现前须复核」 is a decision the user expects to revisit. Do not build it as written: ask the user first and argue the choice again from scratch.
- In the End-of-Session Summary, report each acceptance item with its result, plus any decision made this round, so the task file can be updated.
- Put what a task teaches you where it belongs: long-term engineering conventions go in `docs/<area>.md`, environment facts and gotchas go in `notice.md`, and tradeoffs that hold only for this task stay in the task file.
- This repository stands on its own: nothing in it may depend on, or refer to, files outside it.
</LAYOUT>
