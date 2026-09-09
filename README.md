# Rascal

![Rascal, a keyboard-first Finder replacement for macOS](media/rascal-banner.png)

[![Stars](https://img.shields.io/github/stars/chang-07/rascal?color=ff8635&label=stars)](https://github.com/chang-07/rascal/stargazers) [![Downloads](https://img.shields.io/github/downloads/chang-07/rascal/total?color=ff8635&label=downloads)](https://github.com/chang-07/rascal/releases) [![Ko-fi](https://img.shields.io/badge/Ko--fi-support-ff8635?logo=kofi&logoColor=white)](https://ko-fi.com/chang07)

Rascal is a Finder replacement for macOS, built for people who'd rather not reach for the mouse. It has dual panes, a fuzzy command palette, vim keys, a live disk treemap, real Finder tags, and an inline terminal. It's plain AppKit, it launches fast, and it runs entirely on your Mac.

Free and open source. macOS 13 or later, Apple Silicon or Intel.

[Download](https://github.com/chang-07/rascal/releases/latest) · [Keymap](HOTKEYS.md) · [User guide](https://chang-07.github.io/rascal/guide.html) · [Customize](https://chang-07.github.io/rascal/customize.html)

---

## Download

Grab the latest DMG from the [releases page](https://github.com/chang-07/rascal/releases/latest), pick Apple Silicon or Intel, and drag Rascal into Applications.

The build is ad-hoc signed, so the first launch needs a right-click on Rascal.app → Open. If macOS still refuses (or calls it "damaged"), clear the quarantine flag and try again:

```bash
xattr -cr /Applications/Rascal.app
```

You can also install it with Homebrew:

```bash
brew install --cask chang-07/tap/rascal
```

Or build it yourself — see below.

## Features

- A command palette on `⌘⇧P` and real vim navigation (`hjkl`, `/`, `dd`, `gg`, `gt`). Most things are reachable without the mouse.
- Dual and multi-pane layouts, tabs, and four view modes: List, Icon, Column, and Gallery.
- A live disk treemap. It's a colour-coded map of whatever folder you're in; click a tile to go deeper.
- Reads and writes the same Finder tags Finder does (`kMDItemUserTags`), and you can pin saved searches to the sidebar as smart folders.
- An inline terminal drawer (`` ⌘` ``) that stays in sync with the active pane's directory.
- 17 themes out of the box, plus your own if you want to write one in JSON.
- It stays quick on large folders. There are some numbers further down if you care about that sort of thing.

## Build from source

You'll need macOS 13+ and a Swift 5.9+ toolchain. The Command Line Tools (`xcode-select --install`) are enough; full Xcode isn't required. It's a plain SwiftPM package with no `.xcodeproj`.

```bash
git clone https://github.com/chang-07/rascal.git
cd rascal

./run.sh                 # build (debug) + launch in place
# or
./build.sh debug         # → build/Rascal.app
./build.sh release       # optimized build
./install.sh             # release build → /Applications + a `ft` CLI
```

After `./install.sh`, open Rascal from anywhere:

```bash
ft                       # open the current directory
ft ~/Downloads           # open a path
```

## Essential shortcuts

| Shortcut | Action |
|---|---|
| `⌘⇧P` | Command palette |
| `⌘F` / `⌘⇧F` | Find files (fuzzy) / search file contents |
| `⌘\` | Toggle extra pane |
| `⌘T` / `⌘W` | New / close tab |
| `⌘↑` / `⌘↓` | Enclosing folder / open selection |
| `Return` / `Space` | Rename / Quick Look |
| type letters | Live filter (`Esc` clears) |
| `` ⌘` `` | Inline terminal |
| `⌘,` | Settings (themes, vim, shortcuts) |

Vim mode (toggle in Settings) maps `h j k l`, `gg`, `G`, `gt`/`gT`, `dd`, `yy`, `p`, `r`, `/`, `:`, and more when the file list is focused. The **full keymap** is in [HOTKEYS.md](HOTKEYS.md).

## Testing

Two scripts, both of which run off-screen, so no window appears and focus is never taken.

```bash
./smoketest.sh           # in-process functional runner — 200+ assertions
./guitest.sh             # Accessibility audit of menus + shortcuts
```

`smoketest.sh` launches the binary with `FT_RUN_TESTS=1`; the in-process `TestRunner` builds real controllers, panes, sheets, the palette, and vim, then asserts on their state — it is the source of truth. `guitest.sh` (`FT_HEADLESS_TESTING=1`) is a guardrail that every menu item and shortcut stays wired.

## Project layout

```
Sources/FinderTwo/                 # the Swift target is named FinderTwo (historical); the product is Rascal
├── main.swift / AppDelegate.swift # entry, menu bar, session restore
├── Model/      Actions.swift (command registry), DirectoryModel, FileItem, Workspaces
├── FS/         FastDirScan, FileOps, Tags, DirectoryWatcher (FSEvents)
├── Input/      VimMode.swift
├── Theme/      ThemeStore.swift (17 themes) + ThemeManager
├── UI/         PaneController, FileListController, ColumnViewController, CommandPalette,
│               SearchSheet, BatchRename, TreemapView, Settings, … (most of the app)
├── Window/     BrowserWindowController (sidebar | panes split), PanesContainerController
├── DemoShot.swift                 # off-screen capture harness for the website media
└── Tests/TestRunner.swift         # 200+ in-process assertions
```

`Package.swift` links only system frameworks (AppKit, NetFS, Security); there are no third-party Swift dependencies.

## Contributing

Pull requests are welcome: bug fixes, features, themes, and docs. A few things keep Rascal coherent — please keep them in mind.

### Principles

- Local-first and private. No telemetry, no analytics, nothing phoning home. A change that ships user data off the machine won't be merged.
- Native and fast. AppKit only, no Electron or web views for the core UI. Keep UI work on the main thread and push heavy work off it.
- Few dependencies. There are currently zero third-party Swift packages; the app leans on system frameworks and a handful of CLI tools (`unzip`, `tar`, `rg`/`grep`, `sftp`, `git`). A new dependency needs a good reason.
- Keyboard-first. A new feature should be usable without the mouse. Register it as an Action and the palette and menus pick it up for free.

### Set up

```bash
git clone https://github.com/chang-07/rascal.git
cd rascal
./run.sh            # build + launch
```

macOS 13+ and a Swift 5.9+ toolchain (Command Line Tools are enough). Edit in any editor; `swift build` works directly.

### Before you open a PR

1. `./build.sh debug` compiles clean — fix any new warnings.
2. `./smoketest.sh` passes (200+ assertions).
3. `./guitest.sh` passes (menu/shortcut audit).
4. Add assertions for new behaviour to `Sources/FinderTwo/Tests/TestRunner.swift`.

**Headless-testing rule:** tests and any off-screen rendering must never open a visible window or take focus. The harness parks windows far off every display (`FT_HEADLESS_TESTING=1`) and snapshots them with `CGWindowList`. If you add a capture or demo, follow the off-screen pattern in `DemoShot.swift` — never `makeKeyAndOrderFront` onto a real screen.

### How things are wired

- **Commands are data.** Add new actions to `Model/Actions.swift` (id, title, default shortcut); they appear in the command palette and menu bar automatically, then handle them in the relevant controller.
- **Preferences** live under the `FinderTwo.*` `UserDefaults` namespace — keep the prefix.
- **Themes:** add a `ThemeSpec` to `Theme/ThemeStore.swift` (id, name, appearance, hex colours). Users can also drop a JSON theme in the Themes folder with no rebuild.
- **Don't change** `CFBundleIdentifier` (`dev.chang.FinderTwo`) or the `~/Library/Application Support/FinderTwo` paths — they are load-bearing for granted permissions and existing users' data.

### Style

- Match the surrounding code: 4-space indent, early returns, descriptive names.
- Comment the *why* for non-obvious AppKit workarounds — the codebase favours that.
- Avoid force-unwraps in fallible runtime paths.

### Commits & PRs

- Branch off `main`; keep each PR focused on one thing.
- Commit subjects in the imperative, no trailing period — e.g. `Fix column-view icon caching`.
- In the PR, say what changed, why, and how you tested it. For visual changes, attach an off-screen `DemoShot` capture rather than a live screenshot.

### Where help is wanted

- Git-status overlay polish, a custom keyboard-shortcut editor, 1M-item virtualized scrolling, and inline-preview improvements are all open.
- New **themes** are low-risk and always welcome.

## Performance

| Workload | Rascal |
|---|---|
| Cold launch → window on screen | ~230 ms |
| Scan 5,000 files (`FastDirScan`) | ~22 ms |
| Sync reload 5,000 files | ~33 ms |
| Live filter, 5,000 files | ~50 ms |
| Progressive filter (extend a prefix) | ~4 ms |

Measured on an M3 MacBook Pro from the release binary; the same numbers print live from `./smoketest.sh`. The wins come from direct `opendir`/`readdir`/`lstat` scanning, async sort/filter that spills to a background queue past ~2,000 items, progressive filtering, a per-extension icon cache, and a throttled status bar. The reasoning lives in the source comments of `FS/FastDirScan.swift` and `Model/DirectoryModel.swift`.

## Themes

Seventeen built-in: Rascal Light & Dark, Midnight, Sepia, Hacker, Nord, Dracula, Solarized (light & dark), High Contrast, Ocean, Cyberpunk, Gruvbox, Sage, Tokyo Night, Rose Pine, and Catppuccin Mocha — plus a System option that follows macOS. Switch in Settings (`⌘,`) or via the palette, or write your own JSON theme.

## License

[MIT](LICENSE) © 2026 chang. Free and open source, with no cloud or account in the loop.
