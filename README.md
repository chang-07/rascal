# Rascal

A modern, performant file explorer for macOS — Finder muscle memory, with
tabs, optional multi-pane, live filter, inline rename, async thumbnails,
themes, vim mode, batch rename, command palette, workspaces, tags, and
file-content search. Built with AppKit (NSOutlineView + NSTableView +
NSBrowser) for native performance.

## Install (recommended)

One command does it all — release build, copy to `/Applications`, install a
`ft` CLI:

```bash
./install.sh
```

After that, from anywhere:

```bash
ft                  # open at $(pwd)
ft ~/Downloads      # open at a path
ft .                # open at $PWD
```

…or Spotlight → "Rascal".

## Build (no install)

```bash
./build.sh debug      # .build/debug + build/Rascal.app
./build.sh release    # optimized
./run.sh              # build debug + launch (in place)
```

Requires Swift 5.9+ and macOS 13+. No full Xcode required — Command Line
Tools are enough.

## Performance

| Workload                                  | Rascal            | Stock FileManager  |
|-------------------------------------------|----------------------|--------------------|
| Cold launch → window on screen            | **228–244 ms**       | —                  |
| FastDirScan 5,000 files                   | **22 ms**            | ~110 ms            |
| Sync reload 5,000 files                   | **33 ms**            | ~330 ms            |
| Live filter on 5,000 files                | **50 ms**            | ~110 ms            |
| Progressive filter (extending a prefix)   | **4 ms**             | ~110 ms            |
| Generic-icon cache hit (per row)          | **95 ns**            | ~25 µs             |
| Status bar update (selection change)      | throttled to 60 Hz   | per-event          |

Measurements from the release binary on M3 MacBook Pro. All numbers verified
in the in-process test runner — run `./smoketest.sh` and they print live.

Smoothness-oriented architecture choices:

- **`FastDirScan`** (`FS/FastDirScan.swift`) — direct `opendir`/`readdir`/`lstat`
  instead of `FileManager.contentsOfDirectory` + per-URL `resourceValues`.
- **Async sort + filter** — spills to a background `userInitiated` queue once
  `rawItems ≥ 2000`. The keyboard never blocks; stale results discarded via a
  generation counter.
- **Progressive filtering** — when a new filter just extends the previous one,
  we narrow the prior result set (4 ms) instead of re-scanning rawItems (50 ms).
- **`IconCache`** (`UI/IconCache.swift`) — per-extension generic-icon cache so
  opening a folder of 5,000 `.txt` files calls `NSWorkspace.icon` once.
- **URL → row map** maintained per `reload()` — async thumbnail callbacks find
  their row in O(1) instead of O(n).
- **Cell-level thumbnail short-circuit** — only `image/pdf/video` types ever
  reach `QLThumbnailGenerator`; everything else uses the cached generic icon.
- **Thumbnail prefetch throttled** — bounds-did-change fires at most once per
  16 ms; prefetch skips when the visible center hasn't moved by ≥3 rows.
- **Status bar throttled** — selection change rebuild capped to ~60 Hz so
  arrow-key repeat over a 25 k list stays smooth.
- **Free-space TTL** — kernel `volumeAvailableCapacityForImportantUsage` is
  cached for 5 s; previously hit on every selection.
- **Theme switch no-op** when the requested theme is already active.

## Test

Two complementary test scripts. Both run silently and **never** disrupt your
foreground work — windows never appear on screen, focus is never taken.

```bash
./smoketest.sh     # in-process functional runner — 200+ assertions
./guitest.sh       # Accessibility-level structural audit — 0 failures
```

| Script | What it verifies | How |
|---|---|---|
| `smoketest.sh` | Every feature works end-to-end | Launches the binary with `FT_RUN_TESTS=1`. The in-process `TestRunner` instantiates real `BrowserWindowController`s, panes, file lists, sheets, palette, vim, etc., and asserts on their state and side-effects. **200+ assertions** cover navigation, tabs, panes, view modes, filter, sort, rename, copy/paste, drag-drop, sessions, workspaces, tags, themes, shortcuts, vim, palette, search, git status, folder sync, archive extraction, window chrome, and edge cases. |
| `guitest.sh` | Menu structure is wired correctly | Launches with `FT_HEADLESS_TESTING=1` and queries the app over Accessibility. Asserts every top-level menu, every menu item, and every keyboard shortcut is present and bound correctly. |

The functional runner is the source of truth (it can instantiate controllers
directly and assert on internal state). The AX audit is a guardrail against
menu-wiring regressions.

## Shortcuts (Finder parity + new)

| Shortcut       | Action                                       |
|----------------|----------------------------------------------|
| Cmd+N          | New window                                   |
| Cmd+T          | New tab                                      |
| Cmd+W          | Close tab (closes window if last tab)        |
| Cmd+Shift+W    | Close window                                 |
| Cmd+\          | Toggle extra pane                            |
| Cmd+Up         | Enclosing folder                             |
| Cmd+Down       | Open selection                               |
| Cmd+[ / Cmd+]  | Back / Forward                               |
| Cmd+Shift+G    | Go to folder…                                |
| Cmd+Shift+H    | Home                                         |
| Cmd+Shift+.    | Toggle hidden files                          |
| Cmd+I          | Get Info (via Finder)                        |
| Cmd+Delete     | Move to Trash                                |
| Cmd+C / Cmd+V  | Copy / Paste file URLs                       |
| Cmd+Opt+V      | Move Items Here                              |
| Cmd+D          | Duplicate selection                          |
| Cmd+Opt+1..9   | Switch to tab N                              |
| Return         | Rename selected item                         |
| Space          | Quick Look                                   |
| Type letters   | Live filter (Esc to clear)                   |
| **Cmd+Shift+P**| **Command Palette**                          |
| **Cmd+F**      | **Find Files (fuzzy filename)**              |
| **Cmd+Shift+F**| **Search File Contents (rg/grep)**           |
| **Cmd+Shift+R**| **Batch Rename…**                            |
| Cmd+Ctrl+S     | Save Workspace                               |
| Cmd+Ctrl+O     | Open Workspace                               |
| Cmd+,          | Settings (themes + vim toggle)               |
| Cmd+\`          | Toggle inline terminal panel                 |
| Cmd+Shift+E    | Toggle folder notes drawer (.ftnote.md)      |
| Cmd+K          | Connect to Server (SFTP)                     |

### Vim mode (toggle in Settings)

When the file list is focused and vim mode is on, plain letter keys are
intercepted:

| Keys     | Action                                |
|----------|---------------------------------------|
| `h`      | Enclosing folder                      |
| `j` / `k`| Move selection down / up (5j = 5×)    |
| `l`      | Open selection                        |
| `gg`     | Top of list                           |
| `G`      | Bottom of list                        |
| `gt` `gT`| Next / previous tab                   |
| `t`      | New tab                               |
| `r`      | Rename selected                       |
| `yy`     | Copy selected (yank)                  |
| `dd`     | Move-to-trash selected                |
| `p`      | Paste                                 |
| `/`      | Open filter                           |
| `:`      | Open command palette                  |
| `v`      | Visual mode (extend selection)        |
| `Esc`    | Cancel / reset                        |

Text fields and dialogs always pass keys through.

## Frontier features (1-month sprint)

| Feature | Status | What it does |
|---|---|---|
| **Archive browsing** | ✅ | Double-click a `.zip` / `.tar` / `.tar.gz` / `.tar.bz2` — sheet shows the tree; extract single entries or the whole archive. Uses system `unzip`/`tar`, zero new deps. |
| **Disk usage analyzer** | ✅ | File → *Analyze Disk Usage…* — background recursive walk, live squarified treemap, click-to-drill-down, "Reveal in Rascal". |
| **App uninstaller** | ✅ | File → *Uninstall App…* on a selected `.app` — scans `~/Library/{Application Support,Caches,Preferences,LaunchAgents,Saved Application State,Containers,Group Containers,Logs,WebKit,HTTPStorages}` for files whose name contains the bundle id. Per-leftover checkboxes; one click moves all to Trash. |
| **Per-folder notes drawer** | ✅ | Cmd+Shift+E — right-side drawer reads/writes `.ftnote.md` in the current folder. Plain text monospaced. Auto-saves on idle. Per-folder. |
| **Tags as smart folders** | ✅ | Sidebar's *Tags* section is auto-populated via Spotlight `kMDItemUserTags`. Click a tag → file list shows every tagged file across the disk. Tag colour shown as a coloured dot. |
| **Git-bound workspaces** | ✅ | Inside a git repo, FSEvents on `.git/HEAD` triggers auto-save of the current workspace under `git:<repo>:<branch>` and auto-restore of the new branch's workspace. `git checkout` switches your open tabs/panes too. |
| **Inline terminal panel** | ✅ | Cmd+\` — bottom drawer. Runs each command via `/bin/zsh -l -c` in the active pane's cwd, streams stdout (white) + stderr (red) into the scrollback. Cwd auto-syncs with the pane. `cd` handled locally. ↑/↓ arrow keys cycle through history. |
| **Folder sync (1-way visual diff)** | ✅ | File → *Sync Folder…* — pick source + destination, see the three-state diff (new / modified / only-in-dest / identical), apply src→dst with optional prune. |
| **SFTP via system `sftp`/`scp`** | ✅ | Go → *Connect to Server…* — Cmd+K — connects via the user's existing SSH config + agent (no password handling). Browser sheet lists remote entries, click to drill in, download single files. Bookmarks persist. |
| **Plugin API (JavaScriptCore)** | ✅ | Drop a `.ftplugin/` bundle in `~/Library/Application Support/FinderTwo/Plugins/` with `manifest.json` + `main.js`. Plugins declare actions; JS bridges `ft.onAction`, `ft.notify`, `ft.readFile`, `ft.writeFile`, `ft.run([cmd, args…])`, `ft.currentURL()`, `ft.selectedURLs()`. |

## Architecture

```
Sources/FinderTwo/
├── main.swift / AppDelegate.swift             # entry + menu + session
├── Model/
│   ├── Actions.swift                          # central command registry
│   ├── DirectoryModel.swift  TabState.swift   # data + nav stack
│   ├── FileItem.swift                         # row model
│   └── Workspaces.swift                       # saved layouts
├── FS/
│   ├── DirectoryWatcher.swift                 # FSEvents
│   ├── FileOps.swift                          # trash/paste/info
│   └── Tags.swift                             # Finder-compatible tag xattr
├── Input/
│   └── VimMode.swift                          # modal key handler
├── Theme/
│   └── Theme.swift                            # themes + ThemeManager
├── UI/
│   ├── SidebarController.swift                # NSOutlineView source list
│   ├── PaneController.swift                   # tabs+toolbar+hotbar+list+status
│   ├── FileListController.swift               # NSTableView (list view)
│   ├── ColumnViewController.swift             # NSBrowser (miller view)
│   ├── ToolbarView.swift                      # back/fwd/up + path + search
│   ├── TabStripView.swift                     # tab strip
│   ├── PathBarView.swift                      # clickable breadcrumb
│   ├── StatusBarView.swift                    # count + free-space
│   ├── HotbarView.swift                       # customizable action strip
│   ├── ThumbnailService.swift                 # async QL thumbs
│   ├── CommandPaletteController.swift         # Cmd+Shift+P
│   ├── SearchSheetController.swift            # find-files + grep
│   ├── BatchRenameSheetController.swift       # regex + tokens
│   └── SettingsController.swift               # theme + vim toggle
├── Window/
│   ├── BrowserWindowController.swift          # owns split: [sidebar | panes]
│   └── PanesContainerController.swift         # hosts 1..N PaneControllers
└── Tests/TestRunner.swift                     # 200+ in-process assertions
```

## Test coverage (200+ assertions)

- **Navigation**: nav-up, nav-down, back/forward, Go-to-Folder, root-edge
- **Tabs**: open, switch, close, decrement
- **Panes**: single-pane default, Cmd+\ open/close
- **View modes**: List ↔ Columns (NSBrowser)
- **Filter**: substring + fuzzy subseq, Esc clears, regex-safe input
- **Sort**: folders-first by name
- **Rename**: inline commit, empty rejected, slash rejected
- **Copy/Paste/Move/Duplicate/Trash**: all FileOps round-trips
- **Drag-drop**: pasteboard semantics
- **Session**: snapshot / restore round-trip
- **Workspaces**: save / round-trip / delete
- **Tags**: Finder xattr round-trip, individual remove
- **Themes**: switch to specific, cycle
- **Vim**: enable persist, j/k movement, G to last row
- **Actions**: 13 must-have action ids exist, shortcut labels format
- **Hotbar**: default config of 10 items all resolvable
- **Search**: `rg` or `grep` available on PATH
- **Sidebar**: Documents + Macintosh HD populated
- **Safety**: empty/slash rename ignored, empty paste no-op, special-char filter

## Themes

| Theme     | Appearance      | Notes                                |
|-----------|-----------------|--------------------------------------|
| System    | follows macOS   | default                              |
| Midnight  | dark            | blue-tinted, low light               |
| Sepia     | light           | warm, paper-tone                     |
| Hacker    | dark monospaced | green-on-black, monospaced font      |

Pick via Settings or run "Cycle Theme" from the Command Palette.

## State persistence

- Open tabs + active index per window → `UserDefaults["FinderTwo.session.v1"]`
- Named workspaces → `UserDefaults["FinderTwo.workspaces.v1"]`
- Theme choice → `UserDefaults["FinderTwo.theme"]`
- Vim enabled → `UserDefaults["FinderTwo.vimEnabled"]`
- Hotbar order → `UserDefaults["FinderTwo.hotbar.v1"]`
- Custom shortcuts → `UserDefaults["FinderTwo.shortcuts"]`

## License

[MIT](LICENSE) © 2026 chang — free and open source. No cloud, no account, no telemetry.
