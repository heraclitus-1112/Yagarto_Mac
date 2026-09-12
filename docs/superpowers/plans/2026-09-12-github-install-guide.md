# GitHub Download and Full Installation Guide Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a copy-and-run Chinese guide that takes an Apple Silicon macOS 15+ user from GitHub source download through every software dependency, App installation, backend verification, and first ARM project.

**Architecture:** Keep the detailed procedure in one focused document, link it from the README and existing quick-start, and retain the existing target-specific documents for deeper troubleshooting. Commands must use current repository scripts and current Homebrew formula names; every installation stage has an immediate verification command.

**Tech Stack:** Markdown, zsh, Homebrew, Swift 6.3, Arm GNU Toolchain, GNU GDB 15.2 simulator, QEMU, OpenOCD.

---

### Task 1: Write the complete installation procedure

**Files:**
- Create: `docs/install-from-github.zh-CN.md`

- [ ] **Step 1: Add supported-host checks and system dependency installation**

Document `uname -m`, `sw_vers`, `xcode-select --install`, the official Homebrew installer, Apple Silicon `brew shellenv`, and this full dependency command:

```sh
brew install git arm-none-eabi-gcc arm-none-eabi-gdb qemu open-ocd \
  make gcc@15 gmp mpfr readline texinfo gnu-sed
```

- [ ] **Step 2: Add source download, Release build, audit, and App installation**

Use the exact repository URL, `scripts/build-app.sh Release`, `scripts/audit-release-no-fakes.sh`, and `/Applications/YagartoMacApp.app`. Explain the safe Finder/System Settings path for the first launch of the ad-hoc-signed App.

- [ ] **Step 3: Add the verified GDB 15.2 simulator build**

Use the repository downloader and the verified GNU archive hash:

```sh
scripts/bootstrap-gdb-sim.sh \
  --prefix "$HOME/.local/share/yagarto-mac/toolchains/gdb-15.2-sim" \
  --sha256 '83350ccd35b5b5a0cba6b334c41294ea968158c573940904f00b92f76345314d'
```

- [ ] **Step 4: Add doctor checks and first-use workflows**

Cover App launch, CLI `doctor`, ARM7 project creation/build/debug, Cortex-M4 project creation/run, STM32F4 project creation/build/flash/debug, and explain expected backend names.

- [ ] **Step 5: Add updates, uninstall boundaries, and troubleshooting**

Document a clean-worktree update flow, rebuilding/replacing the App, removing only explicitly named installation targets, and remedies for missing PATH tools, Gatekeeper, missing QEMU machines, simulator detection, and absent hardware.

### Task 2: Connect the guide to existing documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/quick-start.zh-CN.md`

- [ ] **Step 1: Add the primary README link**

Add “从 GitHub 下载并完整安装” before the existing quick-start link, and point the current unsigned-App note to the new guide.

- [ ] **Step 2: Add the quick-start prerequisite link**

At the beginning of the local CLI build section, direct clean-machine users to complete the full installation guide first.

### Task 3: Validate and deliver

**Files:**
- Test: `docs/install-from-github.zh-CN.md`
- Test: `README.md`
- Test: `docs/quick-start.zh-CN.md`

- [ ] **Step 1: Validate commands and links**

Run `sh -n` against extracted shell blocks that do not contain interactive prose, check all repository-relative Markdown links exist, and confirm each named script supports the documented arguments.

- [ ] **Step 2: Re-run the Release build and audit**

Run:

```sh
scripts/build-app.sh Release
scripts/audit-release-no-fakes.sh dist/Release/YagartoMacApp.app
```

Expected: the Release App is produced and the fake-exclusion audit prints `PASS`.

- [ ] **Step 3: Check the final diff**

Run `git diff --check` and scan for placeholders, stale package names, unsafe Gatekeeper instructions, and claims that software installation proves hardware execution.

- [ ] **Step 4: Commit, fast-forward main, and push**

Commit the documentation, fast-forward `main`, delete the feature branch, and push `main` to `origin` as explicitly requested by the user.
