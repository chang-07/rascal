# FinderTwo — Hotkeys & Options Guide

Everything FinderTwo can do, where to find it, and how to drive it from the
keyboard. Every shortcut below is also discoverable in the menu bar and the
**Command Palette** (`⌘⇧P`).

---

## Navigation

| Shortcut | Action | Notes |
|---|---|---|
| `⌘↑` | Enclosing folder | Go to parent dir |
| `⌘↓` | Open selection | Folder → enter; file → open; archive → browse sheet |
| `⌘[` | Back | History back |
| `⌘]` | Forward | History forward |
| `⌘⇧G` | Go to Folder… | Type any path, `~` expands |
| `⌘⇧H` | Home | Jump to your home folder |
| `⌘K` | Connect to Server… | SFTP (uses your existing SSH keys/agent) |
| `⌘⌃R` | Jump to Project Root | walks up to `.git`/`package.json`/`Cargo.toml`/… |
| `⌘⇧O` | Open in Editor | opens the project root in Cursor / VS Code / Zed / Sublime |
| double-click | Open | Same as `⌘↓` |
| click breadcrumb | Jump to that path segment | In the path bar |

## Tabs

| Shortcut | Action |
|---|---|
| `⌘T` | New tab |
| `⌘W` | Close tab (closes the window if it's the last tab) |
| `⌘⇧W` | Close window |
| `⌘⇧]` | Next tab (wraps around) |
| `⌘⇧[` | Previous tab (wraps around) |
| `⌘⌃]` | Move current tab right |
| `⌘⌃[` | Move current tab left |
| `⌘1`…`⌘8` | Jump to tab N |
| `⌘9` | Jump to the last tab |

The tab strip only appears when you have 2+ tabs. Hover a tab to see its full
path; click the `×` to close it, or drag to reorder. Tab-switching and the
numbered jumps also live in the **Window** menu.

## Panes

| Shortcut | Action |
|---|---|
| `⌘\` | Toggle extra pane (single-pane by default; opens a second pane) |
| `⌘⌥→` | Focus the next pane |
| `⌘⌥←` | Focus the previous pane |
| click a pane | Make it the active pane (accent border shows which is active) |

Drag files between panes to copy/move them.

## Files & editing

| Shortcut | Action | Notes |
|---|---|---|
| `Return` | Rename selected item | Finder-style; base name is preselected |
| `Space` | Quick Look | Preview selected file(s) |
| `⌘C` | Copy | File URLs to clipboard |
| `⌘V` | Paste | Copy here |
| `⌘⌥V` | Move Items Here | Paste with move semantics |
| `⌘D` | Duplicate | Adds " copy", " copy 2", … |
| `⌘⌫` | Move to Trash | Recoverable |
| `⌘⌥⌫` | Delete Immediately… | Bypasses the Trash (confirmation required) |
| `⌘⇧⌫` | Empty Trash… | |
| `⌘⇧N` | New Folder | |
| `⌃⌘N` | New Folder with Selection | Groups the selected items into a new folder |
| `⌥⌘N` | New Smart Folder… | Save a search as a sidebar entry (see Sidebar) |
| `⌘I` | Get Info | Native inspector: size, kind, dates, owner, permissions |
| `⌘⌥C` | Copy Path | Full POSIX path(s), one per line |
| `⌘⌥T` | Open in Terminal | iTerm if running, else Terminal.app, at the folder |

Also available from the File / context menus: **Compress** (zip the
selection), **Extract** (unarchive in place), **Make Alias** (symlink),
and **New File**. Drag a file onto a folder and pause to **spring-load** it
open (toggle in Settings ▸ General ▸ Dragging). Multi-item and folder
copies/moves show a cancellable **progress sheet**.

## Search & filter

| Shortcut | Action | Notes |
|---|---|---|
| *(type letters)* | Live filter | Just start typing in the file list; `Esc` clears |
| `⌘F` | Find Files… | Fuzzy filename search across the current folder tree |
| `⌘⇧F` | Search File Contents… | Full-text grep (`rg` if installed, else `grep`) |
| `⌘⇧P` | Command Palette | Fuzzy launcher over every action, favorite, tab, theme |

In the palette / search sheets: `↑`/`↓` move, `Return` activates, `Esc` closes.

## View

| Shortcut | Action |
|---|---|
| `⌥⌘1` | Icon view |
| `⌥⌘2` | List view |
| `⌥⌘3` | Column (Miller) view |
| `⌥⌘P` | Toggle the preview / inspector drawer |
| `⌥⌘S` | Show/Hide the sidebar |
| `⌘⇧.` | Toggle hidden files |
| `⌥⌘B` | Show/Hide the hotbar (the quick-action button row) |
| *(View menu)* | Show/Hide the window title bar, status bar, path bar |
| *(View menu)* | Arrange By… (name, kind, date, size) |
| *(View menu)* | Calculate all folder sizes · Type-to-select |
| *(palette)* | Cycle Theme |

> **Window chrome.** FinderTwo ships chromeless by default: the **hotbar** and
> the **window title bar** are hidden, while the navigation toolbar (back/forward/up
> + path field + search) stays visible. Toggle the hotbar with `⌥⌘B` (View ▸ Show
> Hotbar) and the title bar from View ▸ Show Title Bar. Both choices persist. The
> active view mode and hidden-files state are check-marked in the View menu.

## Panels & tools

| Shortcut | Action | Notes |
|---|---|---|
| `` ⌘` `` | Toggle terminal panel | Bottom drawer; runs commands in the pane's cwd |
| `⌘⇧E` | Toggle notes drawer | Right-side `.ftnote.md` editor for the current folder |
| `⌘⇧R` | Batch Rename… | Regex + tokens, live preview |
| *(File menu)* | Browse Archive… | Or just open a `.zip`/`.tar*` |
| *(File menu)* | Sync Folder… | 1-way visual diff + apply |
| *(File menu)* | Analyze Disk Usage… | Treemap of the selected folder |
| *(File menu)* | Uninstall App… | Select a `.app`, scans `~/Library` leftovers |

## Workspaces

| Shortcut | Action |
|---|---|
| `⌘⌃S` | Save Workspace… (names the current tabs + pane layout) |
| `⌘⌃O` | Open Workspace… (restore a saved layout) |

**Git-bound workspaces** are automatic: inside a git repo, switching branches
(`git checkout …`) auto-saves your current tabs under `git:<repo>:<branch>` and
restores whatever you had open on the branch you switched to.

## App

| Shortcut | Action |
|---|---|
| `⌘,` | Settings (General · Appearance · Keyboard · Hotbar · Advanced) |
| `⌘N` | New window |
| `⌘M` | Minimize |
| `⌘H` | Hide FinderTwo |
| `⌘Q` | Quit |

---

## Vim mode

Enable in **Settings (`⌘,`)** → "Enable Vim navigation". When on, plain letter
keys are intercepted **from anywhere in the window** (file list, sidebar, or no
focus). Text fields, rename, search, terminal, and the path bar always receive
keys normally — Vim never eats your typing there.

| Keys | Action |
|---|---|
| `h` | Enclosing folder (go up) |
| `j` / `k` | Move selection down / up (prefix a count, e.g. `5j`) |
| `l` | Open selection |
| `gg` | Jump to top |
| `G` | Jump to bottom |
| `gt` / `gT` | Next / previous tab |
| `t` | New tab |
| `r` | Rename selection |
| `yy` | Yank (copy) selection |
| `dd` | Move selection to Trash |
| `p` | Paste |
| `/` | Focus the live filter |
| `:` | Open the command palette |
| `v` | Visual mode (extend selection with `j`/`k`) |
| `Esc` | Cancel pending sequence / leave visual mode |

Pressing a Vim motion while the sidebar is focused pulls focus back to the file
list so the selection is visible.

---

## Sidebar

- **Favorites** — Recents (recently-modified files via Spotlight), Home,
  Desktop, Documents, Downloads, Movies, Music, Pictures, Applications (only
  those that exist), plus any folders you've added.
- **Locations** — mounted local volumes (`Macintosh HD`, external drives).
- **Smart Folders** — your saved searches (File ▸ New Smart Folder…, `⌥⌘N`).
  Each re-runs its query (filename and/or content, optionally scoped to a
  folder) on click. Right-click ▸ Delete Smart Folder to remove one.
- **Tags** — every macOS tag in use (via Spotlight). Click a tag to see every
  file with it, anywhere on disk. The coloured dot matches the Finder tag color.

Click any entry to navigate the active pane there; right-click for Open in New
Tab / New Window, Eject, or Remove from Sidebar.

---

## Settings (`⌘,`)

A System-Settings-style window with five sections:

- **General** — where new windows open (last session / Home / Desktop / Documents / Downloads), restore-session-on-launch toggle, show-hidden-by-default, type-to-filter toggle, default view (List / Columns).
- **Appearance** — theme, accent color (9 choices + System), density (Compact / Comfortable / Spacious → row height), font size (−1…+4 pt), with a **live preview** strip that reflects every change instantly.
- **Keyboard** — every action with a click-to-record shortcut field. Recording captures the next combo (needs ⌘/⌃/⌥); `⌫` clears, `Esc` cancels. **Conflicts are detected** — reassigning a combo prompts to steal it from the other action. Per-row **Reset** and **Restore All Defaults**. Changes rebuild the menu **live**.
- **Hotbar** — choose which actions appear in each pane's hotbar; reorder by drag or ↑/↓, add from a popup, remove, or reset.
- **Advanced** — Vim toggle, reveal/reload the plugins folder, reset General & Appearance.

All preferences are plain `UserDefaults` — no account, no cloud.

## Themes

Pick in Settings (`⌘,`) → Appearance, or run "Theme: …" from the palette.

| Theme | Look |
|---|---|
| System | Follows macOS light/dark |
| Midnight | Dark, blue-tinted |
| Sepia | Warm, light, paper tone |
| Hacker | Green-on-black, monospaced |

Accent color, density, and font size layer on top of any theme.

---

## Developer features

FinderTwo is git- and project-aware:

- **Git status badges** — inside any git repo, each row shows a colored letter:
  `M` (orange, modified/renamed), `A`/`U` (green, added/untracked),
  `D`/`!` (red, deleted/conflicted). A folder containing changes shows `M`.
  The window subtitle shows the current branch (`⎇ main`).
- **Jump to Project Root** (`⌘⌃R`) — walks up from the current folder to the
  nearest `.git`, `package.json`, `Cargo.toml`, `go.mod`, `pyproject.toml`,
  `Package.swift`, `pom.xml`, `build.gradle`, etc. and navigates there.
- **Open in Editor** (`⌘⇧O`, or right-click → Open in Editor ▸) — opens the
  detected project root in your editor. Detected automatically: Cursor,
  VS Code, Zed, Sublime Text, Xcode (whichever are installed).

Badges recompute automatically as files change (FSEvents) and never block the
UI — `git status` runs on a background queue.

## SFTP (Connect to Server)

`⌘K` → enter user / host / port / path → **Test** to verify, **Save Bookmark**
to keep it, or **Connect** to browse. Authentication uses your existing SSH
config and agent — FinderTwo never handles passwords itself. In the browser:
double-click a folder to drill in, **Up** to go back, **Download…** to fetch a
file into the active pane's folder.

---

## Plugins

Drop a `<name>.ftplugin/` folder in
`~/Library/Application Support/FinderTwo/Plugins/` containing `manifest.json`
and `main.js`. Declared actions appear in the Command Palette. The JS bridge
exposes: `ft.onAction(id, fn)`, `ft.notify(msg)`, `ft.readFile(path)`,
`ft.writeFile(path, text)`, `ft.run([cmd, args…])`, `ft.currentURL()`,
`ft.selectedURLs()`.

---

## Where settings live

All preferences are plain `UserDefaults` (no account, no cloud):

| Key | What |
|---|---|
| `FinderTwo.session.v1` | Open windows/tabs (restored on launch) |
| `FinderTwo.workspaces.v1` | Named + git-bound workspaces |
| `FinderTwo.theme` | Active theme |
| `FinderTwo.vimEnabled` | Vim mode on/off |
| `FinderTwo.hotbar.v1` | Hotbar button order |
| `FinderTwo.shortcuts` | Custom keyboard shortcut overrides |
| `FinderTwo.sftp.v1` | Saved SFTP bookmarks |

To reset everything: `defaults delete dev.chang.FinderTwo`
