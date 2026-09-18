# YAGARTO Mac 0.6.0 Onboarding, Workspace, CI, and Release Design

## Goal

Ship a zero-cost 0.6.0 release path and shorten the path from downloading the app to completing a first ARM debugging session, while adding safe multi-source editing and real QEMU regression coverage.

## Product behavior

- A dismissible first-run environment sheet reuses `ToolResolver.doctor()`, reports build tools and each profile separately, labels ARM926/QEMU as a compatible rather than exact ARM7TDMI backend, and never installs software.
- The first-success checklist tracks opening the bundled ARM7 example, building, stopping at entry, stepping once, and returning to ready after stop. Dismissal and completion are persisted separately, and the sheet remains available from Help.
- A project session exposes every configured source in order. Source text loads on demand, each loaded source retains its own dirty text, selection, and breakpoints, Save writes all dirty buffers, and Build saves them before invoking the existing core build service.
- Recent projects are canonicalized, deduplicated, capped at ten, shown in the empty state and File menu, never auto-opened, and removed when stale.
- `main` pushes run a real ARM7 QEMU smoke test. `vX.Y.Z` tags on `main` build, audit, zip, checksum, and publish an unsigned GitHub Release using only the built-in token.

## Safety and accessibility

- Existing symlink, hard-link, containment, UTF-8, and per-file size checks apply to every source.
- Cross-file save failures retain unsaved buffers and prevent Build from starting.
- Workflow permissions default to `contents: read`; only the release job receives `contents: write`. No third-party publishing action or long-lived secret is introduced.
- New controls use native SwiftUI roles, stable accessibility identifiers, descriptive labels and hints, text status in addition to color, keyboard-reachable actions, and at least 44 pt action targets.

## Compatibility

- `yagarto.json` remains schema version 1 and CLI command shapes remain unchanged.
- The app and CLI version become 0.6.0; the About panel reads the app bundle dynamically.
- Release artifacts are Apple Silicon only, unsigned and unnotarized. The archive contains the app, not the CLI or ARM toolchains.
