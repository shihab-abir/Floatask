# Contributing

Thanks for helping improve Taskflow! Bug reports and small, focused pull requests are very welcome.

## Project layout

```text
Sources/
├── TaskflowCore/      shared logic, no UI. Used by both the app and the CLI
│   ├── Models.swift           tasks, focus sessions, settings
│   ├── TasksDocument.swift    Tasks.md / archive parser + writer (lossless round-trip)
│   ├── SessionsDocument.swift Sessions.md parser + writer
│   ├── TaskService.swift      the single application core: every change goes through here
│   ├── SafeFile.swift         atomic writes, backups, cross-process lock, errors, log
│   ├── Settings.swift         Settings.md + local config (window frames, vault path)
│   ├── Dates.swift            date helpers + deterministic natural-language dates
│   └── AI/                    provider-agnostic assistant (Apple on-device, Claude API)
├── TaskflowApp/       AppKit floating panels + SwiftUI views (UI only, no business logic)
└── TaskflowCLI/       the `taskflow` command
Tests/                 core test suite (plain Swift runner)
Resources/             Info.plist template, app icon
scripts/               build, test, package, icon generation
docs/FORMAT.md         the on-disk Markdown format (schema_version 1)
```

The rule of thumb: **the GUI and the CLI never write files themselves.** They call `TaskService`,
which reads the file fresh, applies the change, validates it, backs it up and writes atomically.

## Build and test

You need macOS 26+ on Apple silicon and the Command Line Tools (`xcode-select --install`). Full
Xcode works too.

```bash
scripts/test.sh              # run the core tests
scripts/build.sh --debug     # fast build → build/Taskflow.app
./install.sh --from-source   # build + install to ~/Applications and link the CLI
```

### Why plain `swiftc` scripts instead of Xcode or SwiftPM?

So that anyone can build Taskflow with only the free Command Line Tools. Two consequences:
- The macOS 26 SDK declares SwiftUI's `@State` as a macro, and its plugin ships only with Xcode.
  Views therefore use `@ViewState`, an alias for the same property wrapper (see
  `Sources/TaskflowApp/Theme.swift`). Please keep using it.
- Foundation Models' `@Generable` macro isn't available either, so the assistant asks the model for
  JSON as text and validates it in `AIPlanner`.

### Reviewing UI changes without screenshots

The running app accepts two development commands over a distributed notification
(`io.github.shihab-abir.taskflow.command`):
- `route:<tasks|history|assistant|settings|picker>` switches screen.
- `snapshot` renders the panel and the pill to PNGs in
  `~/Library/Application Support/Taskflow/snapshots/`.

## Style

- Match the surrounding code: small types, comments that explain *why*, no business logic in views.
- Keep the UI calm: one accent colour (sage), amber only while a focus session runs, quiet metadata.
- Add or update tests in `Tests/` for anything in `TaskflowCore`.
- Any change to the file format must stay readable by older versions, or bump `schema_version` and
  document the migration in `docs/FORMAT.md`.

## Releasing (maintainers)

1. Update `VERSION` and add a `## [x.y.z]` section to `CHANGELOG.md`.
2. Commit, then tag and push:
   ```bash
   git tag vX.Y.Z && git push origin main vX.Y.Z
   ```
3. The **Release** workflow tests and packages the app, then publishes
   `Taskflow-X.Y.Z-macos-arm64.zip` with its checksum. `install.sh` always picks up the latest
   release.

Builds are ad-hoc signed. Once a Developer ID is available, add signing and notarization
(`codesign --options runtime`, `xcrun notarytool`) to `scripts/package.sh` and the release workflow.
