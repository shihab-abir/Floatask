# Changelog

All notable changes to Floatask are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-11-04

First public release.

### Added
- Always-on-top floating panel with a draggable, resizable window that remembers its position.
- Collapses to a small floating pill that shows progress or the running timer.
- Task list with checkboxes, nested subtasks, groups (`##` headings), due dates, priorities, tags
  and notes.
- Progress bar and a "next" task hint. Completed tasks stay greyed out for the day, then move to a
  monthly archive.
- Focus timer with ±5-minute adjustment, pause/resume/finish/reset, and a task selector that asks
  before switching mid-session.
- Focus history by day and by task, with totals for today and this week, plus a completed-tasks
  view.
- Obsidian-native storage (`Tasks.md`, `Sessions.md`, `Settings.md`, `Archive/`). Changes made in
  Obsidian are picked up live.
- Atomic writes, validation before every write, rolling backups, and a cross-process lock shared by
  the app and the CLI.
- Crash and restart recovery: the timer is stored as timestamps. Sessions that finish while the app
  is closed are recorded on the next launch.
- `floatask` command: open, hide, quit, list, add, done/undo, rm, focus, pause/resume/stop,
  status, history, ask, config, version.
- Optional AI assistant. It runs on Apple Intelligence's on-device model by default, with Claude
  available via an API key stored in the Keychain. Every change it proposes is validated and
  confirmed by you before it's saved.
- Native notifications and an optional sound when a session ends.
- Light/dark/system theme, opacity setting, keyboard shortcuts and VoiceOver labels.
- One-line installer and uninstaller. GitHub Actions CI and automated releases.

[Unreleased]: https://github.com/shihab-abir/Floatask/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/shihab-abir/Floatask/releases/tag/v0.1.0
