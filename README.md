**Personal fork of [Ghostty](https://github.com/ghostty-org/ghostty)** with a sidebar tab system and a built-in git panel for macOS. For the official Ghostty terminal, visit [ghostty.org](https://ghostty.org). All credit goes to them.

🧪 **Experimental**  
Please note that this is experimental and I built it for my own use. It works fine for me, but feel free and try to break it.

🐛 **Known bugs**  
~~- Unread indicator does not clear correctly, and might re-appear when switching tabs~~

<img width="1125" height="749" alt="ghostty-sidebar" src="https://github.com/user-attachments/assets/919a9220-4e07-4b2e-b491-c9d385b6585f" />


## Sidebar

Replaces the native tab bar with a left sidebar showing rich tab cards:

- **Title, directory, git branch** — git branch detected automatically, no setup needed
- **Custom status entries** — show ports, environments, or any metadata via CLI
- **Attention indicators** — orange dot on tabs with notifications or bell
- **Drag-and-drop** — reorder tabs by dragging
- **Theme-aware** — colors derived from your terminal theme

### Config

```
# Choose which fields to show (default: all)
sidebar-fields = title,directory,git-branch,status
```

### CLI

Install: symlink `cli/ghosttyctl` to somewhere on your PATH (e.g. `~/.local/bin/ghosttyctl`).

```bash
ghosttyctl rename "My Tab"                                    # rename tab
ghosttyctl notify --title "Done" --body "Build finished"      # send notification
ghosttyctl set-status server "localhost:3000" --icon network  # add status entry
ghosttyctl clear-status server                                # remove it
ghosttyctl list                                               # list all tabs
ghosttyctl current                                            # current tab info
```

### Claude Code

Add to your `~/.claude/CLAUDE.md` so Claude Code can name its tabs and set status:

```markdown
- Rename the workspace using: `ghosttyctl rename "Claude: <name>"`. Name it after the work being done.
- Set sidebar status entries using `ghosttyctl set-status <key> <value> [--icon <sf-symbol>]` and clear with `ghosttyctl clear-status <key>`.
```

## Git panel

A small git panel pinned to the bottom of the sidebar, scoped to the selected tab's repo:

- **Branch + sync** — current branch, ahead/behind, and inline checkout / commit / push / pull
- **Changes** — pending files with colour-coded status (`M` modified, `A` added, `D` deleted, `?` untracked, `U` conflict)
- **Click to open** — click a file to open it in your editor via `$VISUAL`/`$EDITOR` (e.g. Cursor, VS Code)

This one is especially personal, built around how I work day to day. If it's not for you, turn it off:

```
sidebar-git = false
```

---
