# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Pole (also referred to as SpacePolish) is a native macOS 13+ menu-bar app that rewrites text in the focused input field of any app:

- Double-tap **left Option** → polish; double-tap **right Option** → translate (中→EN, other→简体中文); press **both Options together** → contextual expand.
- Selection-only when a selection exists, otherwise the whole field; the result is written back in place.
- Backend is the DeepSeek API (`deepseek-v4-flash`, thinking disabled). The API key lives only in the macOS Keychain (service `com.spacepolish.mac`, account `deepseek-api-key`).

The codebase is Swift 5.9, SwiftPM, no external package dependencies — AppKit, ApplicationServices (Accessibility), Vision (OCR), Security/CryptoKit only.

## Commands

```bash
# Build + package a dev .app (writes git commit/dirty state into Info.plist)
./Scripts/build-app.sh          # → dist/Pole.app

# Tests: full XCTest suite if Xcode is installed, otherwise compiles an
# equivalent standalone regression binary from the same assertions
./Scripts/run-checks.sh
swift test                       # when full Xcode is available
swift test --filter PoleRegressionTests   # the single regression test class

# Real-model quality regression (uses the API key from Keychain; hits the network)
./Scripts/run-quality-evaluation.sh 40          # 40 polish samples
./Scripts/run-quality-evaluation.sh --expand 22 # 22 expansion samples

# Live performance tracing during a polish run
log stream --level info --predicate 'subsystem == "com.spacepolish.mac" AND category == "rewrite-performance"'
```

Release builds (`./Scripts/build-release.sh`) require a Developer ID cert and notarytool profile; do not run casually.

Note: the test target lives in `Checks/` (not `Tests/`), wired up in `Package.swift`. `Tests/SpacePolishTests` is a leftover skeleton.

## Architecture

Four SwiftPM targets: `PoleCore` (`Sources/Pole/`, ~all logic) → `PolePlatform` (entry/single-instance) → `Pole` executable (3-line main). `Checks/` holds both the XCTest target and the `PoleQualityEvaluation` executable.

`docs/runtime-logic.md` is a detailed, line-referenced walkthrough of the whole runtime — read it before making behavioral changes. (Caveat: it predates the Qwen→DeepSeek switch; where it says `QwenClient`/dashscope/`qwen-api-key`, read `DeepSeekClient`/api.deepseek.com/`deepseek-api-key`.)

### Trigger-to-writeback pipeline

`AppCoordinator` (the central orchestrator) chains: trigger → capture → resolve conversation → model request → local audit → writeback.

1. **Trigger** — `DoubleOptionMonitor` uses a `CGEvent` tap (observe-only) for double-tap/chord detection. Terminals (Terminal, iTerm2, Warp, etc.) are blacklisted up front so multi-line results are never pasted as commands. No new trigger is accepted while one is processing.
2. **Capture** — `AccessibilityTextIOService` runs all AX/keyboard I/O on a serial queue. Prefers the AX text API; falls back to synthesized Cmd+A/Cmd+C with a `ClipboardTransaction` (snapshots the clipboard, restores it only if untouched). Secure/password fields are never read. Length limits: 4,000 chars full text / 12,000 selection, enforced before any API call.
3. **Request lifecycle** — `RewriteCoordinator` gives each request a UUID and an AXObserver-based target monitor. If the user edits the text, switches app/window/focus, or pauses while waiting, the request is cancelled and **late results are never written back**. Before writing, the current text must equal the captured text.
4. **Model** — `DeepSeekClient` sends system prompt (assembled per action) + raw text, plain-text response, tiered timeouts (20/30/45s, shorter on retry). `RewriteResultPolicy` strips model-appended explanations ("优化说明" etc.) locally.
5. **Audit + single retry** — polish/expand only (translate is single-shot by design: no persona/context may leak into faithful translation). `RewritePipeline` runs five local guards in parallel — FactGuard (protected tokens/negation/unsupported additions), VoiceGuard (register drift), AlignmentGuard (unjustified rewrite/expansion via char-multiset ratios), QualityGuard, and ExpansionGuard — enforcing a length budget. On failure the issue list is appended to the prompt for **one** corrective retry; if still failing, the app reports honestly or keeps the original rather than writing a bad result.
6. **Writeback** — AX value write preferred; keyboard paste fallback for custom editors (WeChat etc.). A 1.35s caret-recovery window re-checks the cursor at six checkpoints and repairs apps that reset the caret, stopping immediately if the user moved it deliberately.

### Communication intelligence (polish/expand only)

For messaging apps, `ConversationContextService` identifies the chat via AX window title or local Vision OCR (never leaves the machine), then determines the counterpart via: existing profile → optional user-approved local chat-history helper (`ExternalConversationHelper`, protocol v1, read-only self-declared, SHA-256 re-verified) → kinship/title keyword inference → generic tone. All derived data (relationship profiles, voice metrics, opt-in rewrite history) is AES-GCM encrypted on disk with the key in Keychain. Only anonymized style summaries ever reach the model.

## Working agreements (from project conventions)

- No backward-compatibility layers: remove obsolete code paths outright (e.g. `QwenClient.swift` was deleted when switching to DeepSeek — don't leave aliases or migrations).
- Prefer the simplest implementation that fully meets current requirements; no speculative abstraction or config knobs.
- The user's docs and much of the UI/log text are in Chinese; match that when editing user-facing strings.

## Key files

- `Sources/Pole/AppCoordinator.swift` — central orchestration (trigger, capture, conversation, request, audit, writeback, menu)
- `Sources/Pole/TextEditing.swift` — AX/keyboard capture & writeback, selection resolution, caret recovery, length policy
- `Sources/Pole/DeepSeekClient.swift` — DeepSeek API client, timeouts, key validation, result cleanup
- `Sources/Pole/RewriteGuards.swift` + `RewritePipeline.swift` — the local safety/quality guard pipeline
- `Sources/Pole/PromptPolicy.swift` — per-action prompts and length budgets
- `Sources/Pole/CommunicationIntelligence.swift` — relationship/voice profiles, encrypted store, feedback learning
- `docs/runtime-logic.md` — exhaustive runtime walkthrough (pre-DeepSeek naming, otherwise current)
