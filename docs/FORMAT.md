# Floatask vault format (schema_version 1)

Floatask stores everything in a `Task Manager/` folder inside your Obsidian vault. The files are
plain Markdown: you can read and edit them in Obsidian, and Floatask picks up the changes within
about a second.

```
<vault>/Task Manager/
├── Tasks.md          open tasks + tasks completed today
├── Sessions.md       focus-session log (managed by Floatask)
├── Settings.md       preferences (frontmatter)
├── Archive/
│   └── YYYY-MM.md    completed tasks, moved here the day after completion
└── .backups/         rotating copies taken before rewrites (hidden from Obsidian)
```

## Tasks.md

```markdown
---
schema_version: 1
type: task_manager_tasks
---

# Tasks

- [ ] Finish landing page · due 2026-10-02 · high #design <!-- id:t_20260929_ab12 created:2026-09-29T10:10:00+06:00 -->
	Notes are indented plain lines under a task.
	- [ ] Desktop layout <!-- id:t_20260929_cd34 created:2026-09-29T10:12:00+06:00 -->
	- [x] Hero section <!-- id:t_20260929_ef56 created:… done:2026-09-29T11:00:00+06:00 -->

## Acme

- [ ] Prepare brochure <!-- id:t_20260929_gh78 created:… -->
```

- **Task** = a `- [ ]` / `- [x]` checkbox line. Only `x`/`X` counts as done.
- **Subtasks** = checkbox lines indented under a task (tab or spaces). Checking a parent checks its
  subtasks. Checking the last open subtask checks the parent. Reopening a subtask reopens the parent.
- **Groups** = `##` headings. A `#` heading is just a title.
- **Metadata** follows the title, separated by ` · `:
  - `due YYYY-MM-DD`
  - `high` / `medium` / `low` (priority)
  - `#tags`
- **Hidden fields** go in the trailing HTML comment, which Obsidian doesn't render:
  - `id` is stable and never reused.
  - `created` and `done` are ISO-8601 timestamps.
  - `order` is a top-level task's position in the **Up next** list (1 = first). Tasks without one
    come after the ordered tasks, in file order. Subtasks always stay with their parent.
  - Values are percent-encoded (spaces become `%20`).
- **Tasks you type in Obsidian** don't need an id. Floatask adds one the next time it saves the file.
  If you tick a box in Obsidian, Floatask adds the `done:` time about 3 seconds later.
- **Everything else in the file** is kept exactly as written: paragraphs, other lists, blank lines.
  Lines Floatask doesn't change are written back byte-for-byte.

## Archive/YYYY-MM.md

Same line format, grouped under `## YYYY-MM-DD` (completion day). The original group is kept in
the comment as `group:Name`. A task tree is archived once it and all its subtasks were completed
before today. Focus history is never deleted.

## Sessions.md

```markdown
## 2026-09-29

- session_id: fs_20260929_153000
  task_id: t_20260929_ab12
  task: "Finish landing page"
  started_at: 2026-09-29T15:30:00+06:00
  ended_at: 2026-09-29T15:55:04+06:00
  planned_minutes: 25
  actual_seconds: 1500
  status: completed
```

| status        | meaning |
|---------------|---------|
| `running`     | timer active. Remaining time = `planned − (now − started_at − paused_seconds)` |
| `paused`      | paused since `paused_at` |
| `completed`   | timer reached zero (also detected on next launch if the app was closed) |
| `ended_early` | stopped with **Finish** before zero |
| `interrupted` | reset, or abandoned (paused for more than 8 hours) |

The timer is stored as timestamps, never as a counter. That's why it survives quitting, force
quits, crashes and restarts. Sessions shorter than one minute are discarded. The file is rewritten
in a fixed order after every change: newest day first, one `- session_id:` item per session.

## Settings.md

Flat `key: value` frontmatter. It covers `default_focus_minutes`, `timer_step_minutes`, `sound`,
`notifications`, `completing_task_stops_focus`, `theme` (system/light/dark), `opacity`,
`ai_enabled`, `ai_provider` (apple/anthropic), `ai_model` and `ai_confirm_destructive`. API keys are
**never** stored here. They live in the macOS Keychain (service `io.github.shihab-abir.floatask`).

## Outside the vault (disposable)

- `~/Library/Application Support/Floatask/config.json`: vault path, window positions, collapsed
  state, last-selected focus task.
- `~/Library/Logs/Floatask.log`: error log.

## Safety

Every write follows the same steps: take a lock (shared by the app and the CLI), re-read the file
fresh, apply the change, re-parse and validate the result, make a rotating backup (at most one
every 5 minutes, 30 kept), write a temp file, then do an atomic rename. External edits are never
overwritten blindly, because each change is applied to the file as it is on disk at that moment.
