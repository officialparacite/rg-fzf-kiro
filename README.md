# rg-fzf-kiro

Find a past [Kiro CLI](https://kiro.dev) conversation by what was said in it, not by its title. Type a pattern and [ripgrep](https://github.com/BurntSushi/ripgrep) searches every saved session live while [fzf](https://github.com/junegunn/fzf) shows the matching lines with a colored preview of the conversation. Press Alt-Enter to print your picks as JSON, including the command to resume each session.

Built on the same design as [rg-fzf](https://github.com/officialparacite/rg-fzf).

## Features

- Searches your prompts, Kiro's replies and compaction summaries by default
- Kiro CLI V3 sessions by default; `--v2` adds the older V2 ones
- `Alt-S` adds subagent sessions
- Regex search, with a PCRE2 toggle (`Alt-P`) for lookarounds and backreferences
- Each row shows the session's directory, so you can tell projects apart at a glance; the title is in the preview
- Who wrote each line is shown and colored in the list; the preview shows the conversation as Markdown (highlighted with bat), with a colored comment at the start of each message
- `● live` tag for sessions open in a running kiro-cli, and `Alt-L` to show only those
- `Alt-U` shows each session once; `Alt-R` shows only your messages or only Kiro's
- `Enter` prints the paths of the sessions' readable copies, so one search can feed another: `rg-fzf-kiro | rg-fzf` or `rg-fzf-kiro | rg-fzf-kiro`
- `Alt-Enter` prints the selected lines or sessions as JSON (multi-select with `Tab`), with a ready-to-run resume command
- `Ctrl-E` opens the readable copy in `$EDITOR` at the matched line
- Session filter (`Ctrl-F`) narrows results by directory, date or session id
- Fast: the index is updated incrementally, so startup is near-instant after the first run

## Requirements

| Tool | Notes | macOS | Debian/Ubuntu |
|------|-------|-------|---------------|
| kiro-cli | The sessions to search, and to resume them | | |
| ripgrep | Needs PCRE2 support for `Alt-P` (Homebrew builds include it) | `brew install ripgrep` | `apt install ripgrep` |
| fzf | 0.45 or newer | `brew install fzf` | `apt install fzf` |
| jq | Reads the session files; included with macOS 15+ | `brew install jq` | `apt install jq` |
| perl | Builds the index; included with macOS and most Linux systems | | |
| bat | Markdown highlighting in the preview | `brew install bat` | `apt install bat` |

All of these are required; rg-fzf-kiro checks for them at startup and tells you which one is missing.

Check your versions before installing:

```bash
fzf --version   # needs 0.45 or newer
rg --version    # look for +pcre2 in the features line, for Alt-P
```

Linux package managers often ship an older fzf. If `fzf --version` shows less than 0.45, install a newer one from the [fzf releases page](https://github.com/junegunn/fzf/releases) or with `git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf && ~/.fzf/install`. With an older fzf, rg-fzf-kiro starts but its keybindings fail.

## Installation

```bash
git clone https://github.com/officialparacite/rg-fzf-kiro.git
chmod +x rg-fzf-kiro/rg-fzf-kiro.sh
cp rg-fzf-kiro/rg-fzf-kiro.sh ~/.local/bin/rg-fzf-kiro   # any directory on your PATH
```

## Usage

```bash
rg-fzf-kiro
command | rg-fzf-kiro
```

Every start brings the index up to date by itself: new sessions, new messages, renamed titles and deleted sessions are all picked up, reading only what changed. The first run reads your whole history and takes a few seconds; after that, startup takes a fraction of a second.

Sessions started while the picker is open appear the next time you start it. Live tags don't wait: they are checked on every reload.

You normally won't need these options:

| Option | What it does |
|--------|--------------|
| `--v2` | Also show sessions from Kiro's older V2 store (see below). |
| `-0`, `--null` | `Enter` separates the paths with NUL instead of newlines, for `xargs -0`. |
| `--reindex` | Throw the index away and rebuild it from scratch before starting. Only for when something looks wrong; the index already rebuilds any session whose copy doesn't match. |
| `--index-only` | Update the index and exit without opening the picker, e.g. from a scheduled job. |

### V3 and V2 sessions

Kiro CLI 3.0 keeps sessions in a new store (`~/.kiro/sessions/<workspace>/<id>/`); older sessions stay in the V2 store (`~/.kiro/sessions/cli/`). rg-fzf-kiro reads both and never changes either. It shows V3 sessions by default; `--v2` adds the V2 ones. When you resume a V2 session under V3, Kiro copies it into the V3 store (as `cli_<V2 id>_<suffix>`, with its whole history) and continues there; rg-fzf-kiro then shows only that copy, so it never appears twice. The resume command in the JSON says `--v3` or `--v2` to match where the session lives.

### Chaining

`Enter` prints the full paths of the readable copies of the sessions you selected, one per line. They are plain Markdown files, so any tool can read them, and rg-fzf-kiro knows which session each one is:

```bash
rg-fzf-kiro | rg-fzf          # pick sessions, then search their text as files
rg-fzf-kiro | rg-fzf-kiro     # sessions that mention one thing, then search those for another
rg-fzf-kiro | rg-fzf | rg-fzf-kiro   # back again: rg-fzf prints the copies you picked
```

Piped in, the list can be one entry per line or NUL-separated. Each entry is a readable copy, a session id, or one of Kiro's files or folders for the session (`~/.kiro/sessions/cli/<id>.jsonl`, `~/.kiro/sessions/<workspace>/<id>/`). A V2 session that now has a V3 copy is found by its V2 id too. Duplicates are dropped and unknown entries are skipped with a warning; an empty list is an error. Subagent sessions in the list are searched even with `Alt-S` off, since you named them. In `rg-fzf-kiro | rg-fzf-kiro`, the second one starts only after you finish with the first.

## Keybindings

| Key | Action |
|-----|--------|
| `Ctrl-E` | Open the readable copy of the conversation in `$EDITOR` at the selected line |
| `Ctrl-F` | Switch between chat search and the session filter |
| `Alt-L` | Toggle showing only live sessions (off by default) |
| `Alt-S` | Toggle including subagent sessions (off by default) |
| `Alt-P` | Toggle PCRE2, for lookarounds and backreferences (off by default) |
| `Alt-U` | Toggle one result per session: each session once, at its first match (off by default) |
| `Alt-R` | Show messages by everyone, only you, or only Kiro (its replies and summaries); each press moves to the next |
| `Tab` / `Shift-Tab` | Toggle selection of a line and move to the next / previous line |
| `Ctrl-A` / `Ctrl-Z` | Select all / deselect all |
| `Enter` | Print the paths of the readable copies of the selected lines' sessions (or the current line's), each once, and exit |
| `Ctrl-O` | Print the selected lines as shown and exit |
| `Alt-Enter` | Print the selected lines as JSON with each session's details and resume command |
| `Ctrl-P` | Toggle the preview window |
| `Ctrl-D` / `Ctrl-U` | Scroll the preview down / up |
| `Alt-W` | Toggle wrapping of long lines in the preview, so you see each line in full (off by default) |
| `Alt-N` | Toggle line numbers in the preview (on by default) |
| `Alt-/` or `F1` | Open the list of keybindings, read-only, in `$EDITOR`; close it to return |
| `Esc` | Exit |

The prompt shows how your text is matched: `Chat (regex)`, `Chat (pcre2)` while PCRE2 is on, or `Sessions (fuzzy)`. Active toggles appear after it: `[L]` live only, `[S]` subagent sessions, `[U]` one result per session, and `[P]` in the session filter while PCRE2 is on. `[R:you]` or `[R:kiro]` shows whose messages are listed.

## What you see

Each row is `<directory>/<date started> #<short id>`, then the line number, column and matched text:

```
~/Repos/rg-fzf/2026-09-30 #1f2e3d4c.chat:837:7:kiro│ Use a canary stage first, then promote.
```

`~` is your home folder. After the column comes who wrote the line, in its own color:

| Label | Color | What it is |
|-------|-------|------------|
| `you│` | cyan | your prompts |
| `kiro│` | green | Kiro's replies |
| `summary│` | magenta | Kiro's summary when a long conversation was compacted |
| `agent│` | blue | in a subagent session (`Alt-S`), the instructions the main Kiro gave it |

With an empty search box, you get one row per session with when it was last updated, most recent first.

The label is added for display only. The readable copy itself is plain Markdown: each message starts with a comment saying who wrote it and which line of Kiro's session file (the record) it came from, then the message, then a blank line:

```markdown
<!-- you · 12 -->
how do we roll out the deploy?

<!-- kiro · 13 -->
Use a **canary** stage first, then promote.
```

The preview shows the session's title, full id, directory, when it started and was last updated, whether it is live (and its process id), then the copy with line numbers. Each message's comment is colored by who wrote it. The selected line is marked with `>`, and the text around it (up to 300 lines before and 700 after) is highlighted as Markdown by bat; the rest is shown plain so large sessions still preview quickly. Searches never match the comments themselves.

## JSON output

`Alt-Enter` prints every selected line (or the current one) as JSON. Each result includes the session's details and a `resume` command you can paste:

```json
{
  "query": "canary",
  "results": [
    {
      "session_id": "1f2e3d4c-5b6a-4789-8abc-def012345678",
      "title": "help me set up a canary deploy",
      "directory": "/Users/you/Repos/rg-fzf",
      "store": "v2",
      "resume": "cd '/Users/you/Repos/rg-fzf' && kiro-cli chat --v2 --resume-id '1f2e3d4c-5b6a-4789-8abc-def012345678'",
      "live": false,
      "pid": null,
      "subagent": false,
      "started": "2026-09-30 16:42",
      "updated": "2026-10-16 06:45",
      "updated_at": "2026-10-16T01:15:04.732967Z",
      "session_file": "/Users/you/.kiro/sessions/cli/1f2e3d4c-5b6a-4789-8abc-def012345678.jsonl",
      "copy": "/Users/you/.cache/rg-fzf-kiro/text/~/Repos/rg-fzf/2026-09-30 #1f2e3d4c.chat",
      "line": 1128,
      "column": 9,
      "record": 354,
      "role": "kiro",
      "text": "Use a **canary** stage first, then promote."
    }
  ]
}
```

- `live` and `pid` say whether the session is open in a running kiro-cli right now; resuming a live session opens it a second time.
- `line` and `column` are in the readable `copy` (`column` counts bytes). `record` is the line of `session_file` the message came from, and `text` is the full line, however long.
- From the session list (empty search box), results have the session details only, without `copy`, `line`, `column`, `record`, `role` or `text`.
- From the session filter, `query` is your search and `session_filter` is the filter text.
- Several lines from one session give one result each, so each result is complete on its own.

## How it works

- **Index:** Kiro saves each V3 session as `session.json` (title, directory, timestamps) and `messages.jsonl` (the conversation) in `~/.kiro/sessions/<workspace>/<id>/`, and each V2 session as `<id>.json` and `<id>.jsonl` in `~/.kiro/sessions/cli/`. rg-fzf-kiro turns each session into a plain-text copy in `~/.cache/rg-fzf-kiro/text/`, in folders that mirror the session's directory. Only what you and Kiro said is kept: your prompts (including ones you sent while Kiro was working), Kiro's replies and its compaction summaries. Kiro's hidden reasoning, tool calls and their output, and its internal notes are never indexed. In V3, the copies of earlier messages Kiro re-adds after a compaction are skipped, so nothing appears twice.
- **Incremental updates:** Kiro only ever adds to the end of a session's conversation file, so the index remembers how far it read each one and next time reads only what was added, using one pass per session and all CPU cores. A record Kiro is still writing is left for the next run. If a file got shorter, its start or the last part read changed, or an index file was changed outside the tool, that session is rebuilt from scratch. Only one copy of rg-fzf-kiro updates the index at a time; others wait.
- **One result per session (`Alt-U`) and roles (`Alt-R`):** ripgrep finds every match as usual; then each row's role is looked up, rows from other roles are dropped, and with `Alt-U` only a session's first remaining row is kept. Doing this after the search, rather than stopping ripgrep at each file's first match, means a message's comment line can never stand in for the session's first match.
- **Session filter (`Ctrl-F`):** fuzzy-filters by the row name, i.e. directory, start date or short id (e.g. `proj`, `#3abe`). Switching back keeps the filter, the same way filename mode works in rg-fzf.
- **Live sessions:** Kiro keeps a lock file with the process id of the kiro-cli using a session. Every time the list reloads (a keystroke, a toggle, `Alt-L`), the lock files are read again, so a session you open in another terminal shows up as live straight away. A session is live only if that process is still running and is kiro-cli, so locks left by a crash don't count, even if their process id has since been reused by another program. If the process exists but its command can't be read (some sandboxes block this), it is treated as live. The list of sessions and their text is read when the tool starts, so a brand-new session appears after a restart.
- **Subagent sessions** are sessions another session started for a helper agent. You never typed in them, so they are hidden unless you press `Alt-S`, and their prompts are labelled `agent│`. Sessions created by `/rewind` are your own and always shown.
- **Editing the copy (`Ctrl-E`):** opens the readable copy, not Kiro's session file, so nothing you change there affects the session. The index notices the change and replaces the copy on the next start.

Set `KIRO_HOME` (Kiro's folder, default `~/.kiro`), `KIRO_SESSIONS_DIR` (default `$KIRO_HOME/sessions`) or `RG_FZF_KIRO_CACHE` to use other locations. The index holds the full text of your conversations, so it is as sensitive as the session files themselves; it is created in your home directory with your normal permissions.

## Tests

```bash
python3 tests/test_rg_fzf_kiro.py
```

Builds a throwaway sessions folder and drives the real tool in a pseudo-terminal, with stand-in kiro-cli processes and a fake `$EDITOR`. It never touches your real sessions or index. Takes about six minutes.

## Limitations

- Patterns can't match across lines.
- Lines longer than 500 characters are shortened in the results list; they are still searched in full and shown in full in the preview.
- Searching is always case-insensitive.
- An edit in the middle of a session file, with its start, its end and the index all unchanged, is not detected. Kiro never does this; `--reindex` rebuilds everything if needed.
- A text line that looks exactly like a message comment (`<!-- kiro · 12 -->`) gets a leading space in the copy, so it isn't mistaken for one.

## License

MIT. See [LICENSE](LICENSE).
