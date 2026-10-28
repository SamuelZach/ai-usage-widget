# AI Usage — desktop widget for Claude, Codex, Cursor, Grok Bot and OpenCode Go

A small native macOS app (Swift/SwiftUI, no Xcode project needed) that shows how much of
your Claude, ChatGPT/Codex, Cursor, Grok Bot and OpenCode Go allowance you've used, when each window resets,
and whether you should burn it or go easy.

- **Desktop panel** — a frosted card that lives on the wallpaper (behind windows, like a
  classic desktop widget). Drag it anywhere; position is remembered.
- **Menu bar** — compact weekly % for each service (`72%·5%·40%·🔒`), color-coded by hours
  under/over pace (no “over”/“under” words); click for the full breakdown and settings.
- **Advice** — compares budget left vs. time left in the window:
  under pace → "use it up", ahead of pace → "go easy", plus lock / throttle warnings and a
  "best bet right now" pick.

## Where the numbers come from

| Service | Endpoint | Credential (read only, never stored) |
|---|---|---|
| Claude | `api.anthropic.com/api/oauth/usage` | Claude Code's Keychain item `Claude Code-credentials` |
| Codex / ChatGPT | `chatgpt.com/backend-api/wham/usage` | `~/.codex/auth.json` |
| Cursor | `api2.cursor.sh/.../GetCurrentPeriodUsage` | Cursor IDE `state.vscdb` (`cursorAuth/accessToken`) |
| Grok Bot | `api2.cursor.sh/.../GetSandUsageStatus` | Same signed-in Cursor account (`cursorAuth/accessToken`) |
| OpenCode Go | `opencode.ai/zen/go/v1/usage` | Keychain item `opencode-go-api-key` |

Newer Cursor versions encrypt their saved access token. The widget reads that format
using the `Cursor Safe Storage` Keychain entry, decrypts only the access token in memory,
and uses it for the Cursor and Grok Bot usage requests. It does not change Cursor's
database or save a decrypted token. If macOS asks for Keychain access, allow it to
read that entry so the counters can refresh.

Tokens are refreshed by Claude Code / Codex / Cursor themselves; if one expires the card says so
("Login expired — open Claude Code once") and keeps the last good numbers marked *stale*.

Grok Bot shows the separate weekly Bot allowance for the account signed in to Cursor,
using the same usage query as the Grok Bot desktop app. Cursor's own counter remains
separate. The order in the menu bar is Claude, Codex, Cursor, Grok Bot, OpenCode Go.
If Grok Bot is signed into a different account, sign Cursor into that linked account
for these counters to match. Shared enterprise allowances without an individual
percentage are shown as unavailable rather than as 0%.

## Build / run

```bash
./build.sh install   # build → /Applications/AI Usage.app → launch
./build.sh run       # build and launch from ./build
./build.sh           # build only
```

Requires macOS 14+ and Xcode command-line tools. The app is ad-hoc signed.
Use **Launch at login** in the menu-bar menu to keep it running.

## Usage history

Every sample (all services, all windows, every 2 minutes) is logged to
`~/Library/Application Support/AI Usage/history.sqlite`. From that the app derives *consumption*:
the sum of increases in the weekly level (drops = resets, ignored). This is shown as

- a line under each service in the panel — "26% in last 5 h · 32% today" — with a 24-hour
  sparkline of hourly use;
- **Usage history…** (⌘H) in the menu-bar menu: a window with bar charts per service for the
  last 24 hours / 7 days / 30 days;
- **Export history as CSV…** for your own analysis.

Numbers are *percent of the plan's allowance*, not tokens or money — that is all the APIs expose.
History only exists from the moment the app first ran; nothing can be backfilled, because the
APIs report the current level only, never a history.

Sampling pauses whenever the Mac sleeps, so gaps of tens of minutes are routine and don't mean
usage was missed. Totals count every rise in the level. For the charts, a rise first seen after a
gap is spread evenly across the hours that gap covers, rather than spiking the bucket where the
Mac happened to wake up.

## Menu options

- Refresh now (⌘R) — otherwise it polls every 2 minutes.
- Usage history… (⌘H) / Export history as CSV…
- Show desktop panel — hide/show the card.
- Keep panel on top of windows — floating mode instead of desktop mode.
- Reset panel position.
- Launch at login.

## Debug

`"/Applications/AI Usage.app/Contents/MacOS/AI Usage" --snapshot out.png` renders the panel
to a PNG and quits. `--snapshot-history out.png` does the same for the history window.
`AIUSAGE_LEVEL=<int>` overrides the window level if the desktop level ever misbehaves on a
new macOS; `AIUSAGE_DB=<path>` points the app at a different history database (handy for
testing with seeded data).
