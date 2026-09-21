# Source Encoding Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import UTF-8, GBK/GB18030, Windows-1252, and ISO-8859-1 assembly sources safely while storing every project copy as UTF-8.

**Architecture:** Add one lossless, allowlisted source-text decoder to `YagartoCore`, then route both project creation imports and project-navigator copies through it. Preserve all existing file-safety and transaction boundaries, and report every legacy-to-UTF-8 conversion to the UI.

**Tech Stack:** Swift 6, Foundation/CoreFoundation encoding APIs, SwiftPM, XCTest, SwiftUI/AppKit.

---

### Task 1: Add the shared source text decoder

**Files:**
- Create: `Sources/YagartoCore/SourceTextDecoder.swift`
- Create: `Tests/YagartoCoreTests/SourceTextDecoderTests.swift`

- [ ] **Step 1: Write failing decoder tests**

Add tests that construct real Windows-1252 and GB18030 byte sequences, expect Unicode text plus UTF-8 output, and expect binary/control inputs to throw:

```swift
func testDecodesWesternAndChineseLegacyTextLosslessly() throws {
    let western = try XCTUnwrap("@ résultat\n.global start\nstart: b start\n".data(using: .windowsCP1252))
    let chinese = try XCTUnwrap("@ 中文注释\n.global start\nstart: b start\n".data(using: .gb18030))
    XCTAssertEqual(try SourceTextDecoder().decode(western).encoding, .windowsCP1252)
    XCTAssertEqual(try SourceTextDecoder().decode(chinese).encoding, .gb18030)
}

func testRejectsBinaryAndDisallowedControls() {
    XCTAssertThrowsError(try SourceTextDecoder().decode(Data([0x00, 0x41])))
    XCTAssertThrowsError(try SourceTextDecoder().decode(Data([0xFF, 0xFE])))
}
```

- [ ] **Step 2: Run the decoder tests and verify RED**

Run:

```bash
swift test -c debug --filter SourceTextDecoderTests
```

Expected: compilation fails because `SourceTextDecoder` and its result types do not exist.

- [ ] **Step 3: Implement the minimal decoder**

Create public, `Sendable` value types for `.utf8`, `.gb18030`, `.windowsCP1252`, and `.isoLatin1`. Decode strict UTF-8 first; otherwise use `NSString.stringEncoding(for:encodingOptions:convertedString:usedLossyConversion:)`, require `usedLossyConversion == false`, accept only the allowlist, validate text controls, and return `Data(text.utf8)`.

```swift
public struct DecodedSourceText: Equatable, Sendable {
    public let text: String
    public let utf8Data: Data
    public let encoding: SourceTextEncoding
}

public struct SourceTextDecoder: Sendable {
    public func decode(_ data: Data) throws -> DecodedSourceText
}
```

- [ ] **Step 4: Run the decoder tests and verify GREEN**

Run the command from Step 2. Expected: all `SourceTextDecoderTests` pass with no warnings.

### Task 2: Convert legacy files during project creation imports

**Files:**
- Modify: `Sources/YagartoCore/ProjectCreator.swift`
- Modify: `Tests/YagartoCoreTests/ProjectCreatorTests.swift`

- [ ] **Step 1: Write failing ProjectCreator integration tests**

Add one Windows-1252 source and one GB18030 source. Assert that each project is created, its source decodes strictly as UTF-8, entry detection succeeds, the original is removed only after successful publication, and the report contains `project.encoding_converted` for both files.

- [ ] **Step 2: Run the integration tests and verify RED**

Run:

```bash
swift test -c debug --filter 'ProjectCreatorTests/testImportConverts'
```

Expected: imports are skipped as `project.invalid_utf8`.

- [ ] **Step 3: Route ProjectCreator through SourceTextDecoder**

Replace the direct UTF-8 guard with `SourceTextDecoder().decode(snapshot.data)`, detect the entry from `decoded.text`, and stage `decoded.utf8Data`. Change the private `ImportResult` to hold `[ProjectImportIssue]` so conversion and original-retention warnings can coexist.

```swift
let decoded = try decodeSource(snapshot.data)
let entry = try detectedEntry(in: decoded.text, sourceURL: source, profile: profile)
let created = try stageAndPublish(sourceData: decoded.utf8Data, ...)
```

- [ ] **Step 4: Run ProjectCreator tests and verify GREEN**

Run:

```bash
swift test -c debug --filter ProjectCreatorTests
```

Expected: existing UTF-8 byte-preservation tests and new conversion tests all pass.

### Task 3: Convert legacy files added through the project navigator

**Files:**
- Modify: `Sources/YagartoAppSupport/ProjectSourceManager.swift`
- Modify: `Sources/YagartoMacApp/WorkbenchView.swift`
- Modify: `Tests/YagartoAppSupportTests/ProjectSourceManagerTests.swift`
- Modify: `Tests/YagartoAppSupportTests/AppViewModelMultiSourceTests.swift`

- [ ] **Step 1: Write failing source-manager tests**

Create external Windows-1252 and GB18030 `.s` files, call `copySources`, and assert: external bytes are unchanged, project copies are strict UTF-8, loaded buffers contain the expected Unicode comments, and `convertedRelativePaths` lists both destinations.

- [ ] **Step 2: Run source-manager tests and verify RED**

Run:

```bash
swift test -c debug --filter 'ProjectSourceManagerTests/testCopySourcesConverts'
```

Expected: `invalidUTF8` is thrown or `convertedRelativePaths` is missing.

- [ ] **Step 3: Implement conversion reporting**

Add `convertedRelativePaths: [String] = []` to `ProjectSourceMutationResult`. Prepare each source from `SourceTextDecoder`, write `decoded.utf8Data`, load `decoded.text`, and record non-UTF-8 destinations. Extend the “已添加源码” message with a second section headed “已转换为 UTF-8”.

- [ ] **Step 4: Run manager and ViewModel tests and verify GREEN**

Run:

```bash
swift test -c debug --filter 'ProjectSourceManagerTests|AppViewModelMultiSourceTests'
```

Expected: all selected tests pass and existing mock initializers remain source-compatible through the default field value.

### Task 4: Document behavior and verify the change

**Files:**
- Modify: `docs/zh-CN/swiftui-app.md`

- [ ] **Step 1: Document accepted encodings and conversion semantics**

State that external UTF-8, GBK/GB18030, Windows-1252, and ISO-8859-1 assembly files are converted into UTF-8 project copies, while unsafe links, oversized inputs, and binary/control data remain rejected.

- [ ] **Step 2: Run focused strict tests**

```bash
swift test -c debug -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors \
  --filter 'SourceTextDecoderTests|ProjectCreatorTests|ProjectSourceManagerTests|AppViewModelMultiSourceTests|ReleaseContractTests'
```

Expected: selected suites pass with zero failures.

- [ ] **Step 3: Validate the reported desktop sample without modifying it**

Run a focused import against a temporary copy of `/Users/macbookair/Desktop/td52a.s`; verify the created source is UTF-8, contains `résultat`, and the original desktop file hash is unchanged.

- [ ] **Step 4: Run final proportional verification**

Run one strict Debug suite and one Release app build/fake audit. Do not run XCUITest for this encoding-only change.

- [ ] **Step 5: Commit the implementation**

```bash
git add Sources Tests docs/zh-CN/swiftui-app.md
git commit -m "fix: import legacy encoded assembly sources"
```
