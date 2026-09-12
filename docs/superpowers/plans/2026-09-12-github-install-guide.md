# GitHub Download and Full Installation Guide Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a copy-and-run Chinese guide that takes an Apple Silicon macOS 26.2+ source-build host from GitHub download through every software dependency, App installation, backend verification, and first ARM project, while distinguishing the App's macOS 15 deployment target.

**Architecture:** Keep the detailed procedure in one focused document, link it from the README and existing quick-start, and retain the existing target-specific documents for deeper troubleshooting. Commands must use current repository scripts and current Homebrew formula names; every installation stage has an immediate verification command.

**Tech Stack:** Markdown, zsh, Homebrew, Swift 6.3, Arm GNU Toolchain, GNU GDB 15.2 simulator, QEMU, OpenOCD.

---

### Task 1: Write the complete installation procedure

**Files:**
- Create: `docs/install-from-github.zh-CN.md`

- [x] **Step 1: Add supported-host checks and system dependency installation**

Document `uname -m`, `sw_vers`, current full Xcode installation, `xcode-select`, Swift 6.3 verification, the official Homebrew installer, Apple Silicon `brew shellenv`, and this full dependency command:

```sh
brew install git arm-none-eabi-gcc arm-none-eabi-gdb qemu open-ocd \
  make gcc@15 gmp mpfr readline texinfo gnu-sed
```

- [x] **Step 2: Add source download, Release build, audit, and App installation**

Use the exact repository URL, `scripts/build-app.sh Release`, `scripts/audit-release-no-fakes.sh`, and `/Applications/YagartoMacApp.app`. Explain the safe Finder/System Settings path for the first launch of the ad-hoc-signed App.

- [x] **Step 3: Add the verified GDB 15.2 simulator build**

Use the repository downloader and the verified GNU archive hash:

```sh
scripts/bootstrap-gdb-sim.sh \
  --prefix "$HOME/.local/share/yagarto-mac/toolchains/gdb-15.2-sim" \
  --sha256 '83350ccd35b5b5a0cba6b334c41294ea968158c573940904f00b92f76345314d'
```

- [x] **Step 4: Add doctor checks and first-use workflows**

Cover App launch, CLI `doctor`, ARM7 project creation/build/debug, Cortex-M4 project creation/run, STM32F4 project creation/build/flash/debug, and explain expected backend names.

- [x] **Step 5: Add updates, uninstall boundaries, and troubleshooting**

Document a clean-worktree update flow, rebuilding/replacing the App, removing only explicitly named installation targets, and remedies for missing PATH tools, Gatekeeper, missing QEMU machines, simulator detection, and absent hardware.

### Task 2: Connect the guide to existing documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/quick-start.zh-CN.md`

- [x] **Step 1: Add the primary README link**

Add “从 GitHub 下载并完整安装” before the existing quick-start link, and point the current unsigned-App note to the new guide.

- [x] **Step 2: Add the quick-start prerequisite link**

At the beginning of the local CLI build section, direct clean-machine users to complete the full installation guide first.

### Task 3: Keep the documented build path compatible and clean

**Files:**
- Modify: `scripts/build-app.sh`
- Modify: `scripts/test-build-app.sh`
- Modify: `.gitignore`

- [x] **Step 1: Reproduce the Xcode resource-bundle validation failure**

Run `scripts/test-build-app.sh` with a healthy Xcode build and confirm it exits 1 after `BUILD SUCCEEDED` because the resource bundle uses the standard `Contents/Resources` layout.

- [x] **Step 2: Accept both valid SwiftPM bundle layouts**

Keep the flat-layout assertion used by the SwiftPM fallback, and also accept the standard macOS bundle resource at `YagartoMac_YagartoCore.bundle/Contents/Resources/arm7tdmi.ld`. Re-run `scripts/test-build-app.sh` and require exit 0.

- [x] **Step 3: Ignore Xcode's generated workspace metadata**

Ignore only the generated `YagartoMacApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` so following the documented Release build does not leave a clean source checkout dirty without hiding future shared workspace metadata; the root `Package.resolved` and exact package version remain authoritative.

### Task 4: Validate and deliver

**Files:**
- Test: `docs/install-from-github.zh-CN.md`
- Test: `README.md`
- Test: `docs/quick-start.zh-CN.md`

- [x] **Step 1: Validate commands and links**

Run `sh -n` against extracted shell blocks that do not contain interactive prose, check all repository-relative Markdown links exist, and confirm each named script supports the documented arguments.

- [x] **Step 2: Re-run the Release build and audit**

Run:

```sh
scripts/build-app.sh Release
scripts/audit-release-no-fakes.sh dist/Release/YagartoMacApp.app
```

Expected: the Release App is produced and the fake-exclusion audit prints `PASS`.

- [x] **Step 3: Check the final diff**

Run `git diff --check` and scan for placeholders, stale package names, unsafe Gatekeeper instructions, and claims that software installation proves hardware execution.

- [x] **Step 4: Commit, fast-forward main, and push**

Commit the documentation, fast-forward `main`, delete the feature branch, and push `main` to `origin` as explicitly requested by the user.
