# YAGARTO Mac 0.6.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver environment onboarding, a safe multi-source workspace with recent projects, real QEMU CI, and an unsigned zero-cost GitHub Release path for 0.6.0.

**Architecture:** Preserve the existing core build/debug protocols. Extend AppSupport with project-session, recent-project, and environment-checking models, then bind them to focused SwiftUI components. Keep workflow logic reproducible in scripts and guard the YAML and version contract with tests.

**Tech Stack:** Swift 6.3, SwiftUI/AppKit, XCTest/XCUITest, POSIX shell, GitHub Actions, GitHub CLI.

---

### Task 1: Version and release contract

- [x] Add failing tests for 0.6.0 version consistency and release workflow/script requirements.
- [x] Observe the expected failures.
- [x] Make App, CLI, project settings, plist, About panel, and build script version handling consistent.
- [x] Add deterministic release packaging and the least-privilege tag workflow.
- [x] Run focused tests and local package verification.

### Task 2: Multi-source project session

- [x] Add failing DocumentService tests for ordered sources, lazy loading, independent dirty buffers, save-all, and partial failure.
- [x] Introduce source-buffer/project-session models while preserving single-source API compatibility.
- [x] Add source selection, per-file breakpoint/selection state, save-all, cross-file diagnostic navigation, and all-source debug breakpoints to AppViewModel.
- [x] Add the accessible source sidebar and multi-file UI tests.
- [x] Run DocumentService, AppViewModel, accessibility, and UI-focused tests.

### Task 3: Recent projects

- [x] Add failing tests for canonical deduplication, recency order, ten-item bound, stale removal, and clear.
- [x] Add an injectable local recent-project store and connect successful open/create operations.
- [x] Add recent project entries to the empty state and File menu without auto-opening.
- [x] Run focused model and UI tests.

### Task 4: Environment onboarding

- [x] Add failing tests for exact/compatible/unavailable classification, asynchronous checking, persistence, and first-success milestones.
- [x] Add EnvironmentChecking and onboarding state without changing DoctorReport.
- [x] Add the accessible first-run sheet, copy-only install guidance, recheck action, Help command, and milestone checklist.
- [x] Extend deterministic UI fixtures for missing/ready environment paths.
- [x] Run focused unit, accessibility, and XCUITest source checks.

### Task 5: Real QEMU CI and documentation

- [x] Add failing contract tests for a main-only, read-only QEMU workflow that cannot silently skip required tools.
- [x] Add the workflow and strict smoke wrapper using existing real E2E tests.
- [x] Rewrite install/update docs around the prebuilt ZIP path while preserving source-build and exact-simulator instructions.
- [x] Run guide/workflow contract tests.

### Task 6: Full verification

- [x] Run strict Debug and Release Swift tests.
- [x] Run the app/XCUITest harness, recording any explicit environment skip rather than claiming a pass.
- [x] Build and audit the Release app.
- [x] Produce and unpack the local release ZIP, verify SHA-256, executable permission, version, architecture, and resources.
- [x] Review the diff for secrets, workflow permission expansion, unrelated changes, and remaining placeholders.
