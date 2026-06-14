# Rascal — Tech Debt Audit & v0.2 Remediation Plan

_Audited on the `v0.2-cleanup` branch so `main`, the `v0.1.3` release, and the Netlify site are untouched._

## TL;DR — the codebase is healthy

A full sweep (87 Swift files, ~23.7k LOC) found **no TODO/FIXME markers, no `as!`/`try!` force-unwraps, no dead code, no deprecated APIs, and zero third-party dependencies**. That's unusually clean. The real debt is **structural** (a few controllers grew into god objects) and **process** (manual releases, one flaky test, test/demo code shipping in the release binary). None of it blocks shipping; all of it is good v0.2 groundwork.

## Already fixed on this branch (Phase 0)

| Fix | File |
|---|---|
| `'token' mutated after capture by sendable closure` warning → holder box | `AppDelegate.swift:192` |
| Unused immutable `dd2` warning | `Tests/TestRunner.swift:3116` |
| Magic `0x2` → named `kSecCodeSignatureAdhoc` constant | `PermissionsManager.swift:91` |

Result: **clean build with 0 warnings, smoketest 550/550 green.**

## Debt inventory (scored)

`Priority = (Impact + Risk) × (6 − Effort)` · Impact/Risk 1–5 · Effort 1 (trivial) – 5 (multi-day)

| # | Item | Category | Impact | Risk | Effort | **Priority** |
|---|---|---|---:|---:|---:|---:|
| 1 | **No CI** — build + tests + DMG run only locally/by hand (this is what nearly shipped a stale, crashing DMG) | Infra | 3 | 4 | 2 | **28** |
| 2 | **Flaky test** — `cross-pane move records undo` asserts before the async move settles | Test | 2 | 2 | 1 | **20** |
| 3 | **Scattered selection state** — selection lives in 3 stores (`fileList`, `iconSelection`, `columnSelection`); `selectedURLs()` switches over them (`PaneController.swift:793`) | Code | 3 | 3 | 3 | **18** |
| 4 | **Test/demo code in the release binary** — `TestRunner.swift` (3365 lines) + `DemoShot.swift` (549) compile into the shipped app; only invoked via env vars | Build | 2 | 2 | 2 | **16** |
| 5 | **Actions ↔ controller coupling** — every `Action.perform` hardcodes `BrowserWindowController` method calls (`Actions.swift:24`) | Arch | 2 | 2 | 2 | **16** |
| 6 | **Notarization** — ad-hoc signing → Gatekeeper "damaged" scare on first launch (top install-killer). Needs $99/yr Apple acct (cost-gated) | Infra | 1 | 3 | 2 | **16** |
| 7 | **Duplicated drawer pattern** — terminal/preview/notes/git-diff each re-implement the same toggle + constraint state (`PaneController.swift:91–157`) | Code | 3 | 2 | 3 | **15** |
| 8 | **Menu-building monolith** — 180-line hand-wired `installMainMenu()` (`AppDelegate.swift:232`) duplicates `ActionRegistry` | Arch | 3 | 2 | 3 | **15** |
| 9 | **`NameCell` inline** — 227-line class buried at the end of `FileListController.swift:1499` | Code | 2 | 1 | 1 | **15** |
| 10 | **No `ARCHITECTURE.md`** — pane/drawer/action wiring is tribal knowledge (matters now that CONTRIBUTING invites PRs) | Docs | 2 | 1 | 1 | **15** |
| 11 | **77 thin `@objc` shims** in `BrowserWindowController` (290–523) that just forward to `activePane` | Arch | 2 | 1 | 2 | **12** |
| 12 | **`ThemeObserving` boilerplate** repeated in ~40 controllers (subscribe + `applyTheme()`) | Code | 2 | 1 | 2 | **12** |
| 13 | **`AppDelegate` mixed concerns** — lifecycle + session persistence + CLI dispatch + menus (685 lines) | Arch | 2 | 2 | 3 | **12** |
| 14 | **`TestRunner.swift` is one 3365-line file** — hard to navigate; split per feature | Test | 2 | 1 | 2 | **12** |
| 15 | **`FileListController` god object** (1726 lines) — table data/delegate + drag-drop + folder-size cache + git badges + QuickLook + clipboard | Arch | 4 | 3 | 5 | **7** |
| 16 | **`PaneController` god object** (1110 lines) — tabs + nav + 4 drawers + view modes + layout (40 constraints) | Arch | 4 | 3 | 5 | **7** |
| 17 | **Deep delegate chaining** — Window → Container → Pane → FileList; tracing one action spans 4 classes | Arch | 3 | 2 | 5 | **5** |

> Note on "duplicated" icon sizes (`NSSize(16,16)` ×14, etc.): these are *coincidentally* equal across unrelated views, not conceptual duplication. Consolidating them into one shared constant would be false-DRY (coupling a sidebar icon to a palette icon), so they're intentionally **left as-is**.

## Phased remediation plan (rides alongside feature work)

### Phase 1 — v0.2 quick wins (do first; low effort, high leverage)
- **#1 Add CI** (GitHub Actions): on push → `swift build` + `./smoketest.sh` + `./guitest.sh`; on tag → build both DMGs and attach to the release. This directly removes the manual-release risk that just shipped a stale crashing build.
- **#2 De-flake** the cross-pane undo test (await the async transfer before asserting).
- **#9 Extract `NameCell`** to `UI/NameCell.swift`.
- **#10 Write `ARCHITECTURE.md`** (one diagram: Window → Container → Panes → views/drawers; how Actions/menus/shortcuts connect).
- Small: a `NotificationSubscriber` helper to standardize observer add/remove.

### Phase 2 — v0.2 targeted refactors (medium, contained, test-guarded)
- **#3 `SelectionModel`** — one source of truth for the active view's selection; all view modes read/write it. (Also kills the class of selection-across-view bugs.)
- **#7 `DrawerManager`** — collapse the 4 drawer state machines into one reusable component.
- **#8 `MenuBuilder`** that consumes `ActionRegistry` (auto-wires titles/shortcuts) — then delete the hand-wired menu + many of the **#11** shims and **#5** coupling.
- **#4 Gate test/demo code out of release** via a compile flag (e.g. `-D RASCAL_TESTING`) or a separate SwiftPM target, so the shipped binary drops ~3.9k lines of harness.
- **#12 `ThemeSubscriber`** base/mixin.

### Phase 3 — post-v0.2, incremental (large; do opportunistically)
- **#15/#16 Split the god objects** one extraction at a time (e.g. pull `FolderSizeManager` and the QuickLook delegate out of `FileListController`; pull `DrawerManager`/`LayoutBuilder`/`ViewModeCoordinator` out of `PaneController`), running the smoketest green between each step. Never a big-bang rewrite.
- **#17 Flatten delegate chains** with a lightweight event/command bus — only if the chains keep causing friction.

## Not debt — related v0.2 features to track separately
- "Make Rascal the default folder handler" Settings toggle (the `public.folder` Launch Services registration discussed separately) — small, shippable.
- Privacy-friendly site analytics (GoatCounter) for the launch.

## How to verify after any change
```bash
./build.sh debug && ./smoketest.sh && ./guitest.sh   # all must stay green
```
