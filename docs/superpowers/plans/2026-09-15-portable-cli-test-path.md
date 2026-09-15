# Portable CLI Test PATH Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make CLI integration tests locate real ARM tools from their resolved installation directories without assuming Homebrew prefixes.

**Architecture:** Keep the default child-process environment hermetic with `/usr/bin:/bin`. Real-tool tests obtain an explicit PATH from `ToolResolver`; fake-tool and missing-tool tests retain their existing explicit overrides.

**Tech Stack:** Swift 6.3, XCTest, Foundation `Process`, YagartoCore `ToolResolver`.

---

### Task 1: Specify portable test environments

**Files:**
- Modify: `Tests/YagartoCoreTests/CLIIntegrationTests.swift`

- [ ] Add a failing test asserting the default isolated CLI PATH is `/usr/bin:/bin`.
- [ ] Run the targeted test and confirm it fails because Homebrew directories are currently hard-coded.
- [ ] Change the default isolated PATH to `/usr/bin:/bin` and confirm the targeted test passes.
- [ ] Add a failing test that resolves required ARM tools from non-standard directories, including a directory with a space.
- [ ] Implement `realARMBuildEnvironment(resolver:)` to return a deduplicated explicit PATH and preserve `XCTSkip` for missing tools.
- [ ] Update every test that uses real ARM build tools to pass this environment to each CLI invocation.

### Task 2: Verify and deliver

**Files:**
- Test: `Tests/YagartoCoreTests/CLIIntegrationTests.swift`

- [ ] Run all `CLIIntegrationTests`.
- [ ] Run the full debug Swift test suite with strict concurrency and warnings as errors.
- [ ] Run `git diff --check` and inspect the final diff.
- [ ] Commit, fast-forward `main`, delete the feature branch, and push `origin/main` as requested.
