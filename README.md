# opencode-deepseek-minimax-macwidget

macOS menu bar app that tracks DeepSeek and MiniMax API usage in real time. Shows balance, credit, and token usage at a glance.

## Credits

- **minimax-usage-checker** by [AungMyoKyaw](https://github.com/AungMyoKyaw/minimax-usage-checker) — original inspiration and reference implementation
- **Lobe Icons** by [lobehub](https://github.com/lobehub/lobe-icons) — DeepSeek and MiniMax brand icons

## Features

- Menu bar icons showing DeepSeek and MiniMax balances
- Auto-fetches from DeepSeek balance API and MiniMax credit API
- Manual credit entry with save/cancel
- 15-minute auto-refresh
- B&W monochrome design
- DeepSeek remaining history: a 168-hour view with up to 30 days of local hourly snapshots. Green bars are top-ups, gray bars are balance reductions, and left/right controls move both charts together by one day.
- Remaining Quota: a scrollable 168-hour view with up to 30 days of local hourly snapshots. Blue is the DeepSeek balance in USD (left axis); green is the OpenAI remaining percent (right axis, 0/50/100%).
- Durable 12-month ledger: every hourly quota snapshot is stored in a local SQLite database and survives app rebuilds and restarts. The Quota chart history is seeded from this ledger each refresh.
- Month-end report: on the last calendar day of each month, a summary plus the month's snapshot data is emailed and archived locally.

## Example

### DeepSeek + MiniMax

The original version keeps both providers visible in a compact menu-bar panel. Each card shows the provider balance and status at a glance, while the Refresh and Quit actions remain available below the cards.

![DeepSeek and MiniMax macOS menu bar widget](https://i.postimg.cc/ncKXx3fs/widget.png)

*Example of the DeepSeek + MiniMax widget layout.*

### DeepSeek + MiniMax + ChatGPT Plus

The expanded version adds a ChatGPT Plus quota card below the DeepSeek and MiniMax balances. It shows the remaining subscription percentage and the next quota reset date in the same compact menu-bar panel.

![DeepSeek, MiniMax, and ChatGPT Plus macOS menu bar widget](https://i.postimg.cc/76TLWVN8/Screenshot-2026-07-16-at-9-34-59-PM.png)

*Example of the DeepSeek + MiniMax + ChatGPT Plus widget layout.*

### Latest Iteration: Usage + Remaining Quota Charts

The current widget adds two navigable charts below the balance cards.

The **Input usage** chart is a 168-hour smoothed input-token chart showing
OpenAI in green and DeepSeek in blue, with calendar dates and month labels on
the x-axis.

The **Quota** chart plots the DeepSeek balance in USD (blue, left axis) and
the OpenAI remaining percent (green, right axis) on a shared 168-hour window.
Local hourly snapshots are retained for up to 30 days, and the left/right
controls move both charts together by one day.

![OpenCode widget with usage and remaining quota charts](https://i.postimg.cc/JhBRcjhx/Opencode-Widget-Quota-Usage.png)

*Latest iteration with OpenAI quota, provider balances, the two-line usage chart, and the dual-axis remaining quota chart.*

### v1.3.0: 5-Hour + Weekly OpenAI Quota

The OpenAI card now shows both subscription windows as separate rows — a
**5h** bar directly above the existing **Weekly** bar. Each row has its own
remaining percentage, monochrome usage bar with a server-anchored elapsed
marker, and reset time. The estimated weekly cost stays anchored to the
168-hour window.

Both windows come from the same authenticated `/backend-api/wham/usage`
request and are classified by their `limit_window_seconds` duration
(`18000` = 5h, `604800` = weekly), so a reversed or reordered payload cannot
mislabel them. If one window is missing or malformed, the other is still
shown, and a failed refresh keeps the last known value for each window
independently. The new 5-hour readings are stored additively in the existing
local SQLite ledger; old rows and the DeepSeek/OpenAI usage and cost history
are preserved.

See [docs/releases/v1.3.0.md](docs/releases/v1.3.0.md) for release notes.

### v1.4.0: Legible OpenAI usage line

In the **Usage** chart, DeepSeek keeps the visible leading y-axis while OpenAI
is plotted on a hidden second y-axis with its own zero-based auto-max. OpenAI's
peak reaches the top of the plot and its shape stays proportional to its own
maximum, so small OpenAI token usage stays readable beside DeepSeek's much
larger spikes. Accessibility values still report real token counts.

See [docs/releases/v1.4.0.md](docs/releases/v1.4.0.md) for release notes.

### v1.5.0: Native Provider Settings

The menu footer now includes **Settings** between Refresh and Quit, opening a
single native macOS Providers Settings scene. Configure which provider cards are
visible, set up DeepSeek and MiniMax credentials with validation before a
Keychain save, and view the availability of the existing Codex session for
ChatGPT Plus. Card visibility changes only the presentation: refreshes, charts,
cache, and the local ledger continue to run unchanged.

See [docs/releases/v1.5.0.md](docs/releases/v1.5.0.md) for release notes.

### v1.5.1: Shared-client usage trends restored

The Usage chart plots observed local token history again after the OpenCode data
store moved to `session_message`. Usage is now combined across **OpenCode, Codex
and Hermes** regardless of which app is in front, since all three can consume the
same DeepSeek and OpenAI accounts. Tokens are counted independently of model
pricing (unpriced models still plot, and the cost estimate reports
**unavailable**), and recovered historical hours are written back idempotently
so gaps appear after the next refresh.

See [docs/releases/v1.5.1.md](docs/releases/v1.5.1.md) for release notes.

### v1.5.2: In-app update prompt

The menu now tells you when a newer release exists. Once a day the app fetches
`version.json` from this repository, compares it with the running bundle, and
shows a compact **vX.Y.Z available** row that opens the GitHub release page.
Dismissing a version hides it until an even newer one appears. Checks are
silent, run off the UI thread, and never touch quota, usage or cached history;
malformed manifests and non-HTTPS/non-GitHub links are ignored.

See [docs/releases/v1.5.2.md](docs/releases/v1.5.2.md) for release notes.

## Publishing a release

1. Bump `CFBundleShortVersionString` / `CFBundleVersion` in
   `opencode-widget/project.yml`, `opencode-widget/OpencodeWidgetApp/Info.plist`
   and `OpencodeWidgetApp.xcodeproj/project.pbxproj` (never lower the build).
2. Run `swift test`, then a Release build, then `opencode-widget/package-dmg.sh`.
3. Update `version.json` at the repository root with the new `latest`, `build`,
   GitHub release `url` and a one-line `notes` summary. Commit it with the code.
4. Tag `vX.Y.Z`, push, and publish the GitHub release with the DMG attached.
5. Existing installs see the prompt within a day (or on the next launch after
   that interval) and can update from the release page.


## API Approach

### DeepSeek — `/user/balance`

```
GET https://api.deepseek.com/user/balance
Authorization: Bearer <api-key>
```

Returns `balance_infos[].total_balance` as a USD string. This is a public, undocumented endpoint used by the DeepSeek web console. Works with any valid API key.

### MiniMax — `/account/query_balance`

```
GET https://platform.minimax.io/account/query_balance
Authorization: Bearer <api-key>
```

Returns `available_amount` as a USD string. This is the web console's internal balance API. Unlike the documented `/coding_plan/remains` (prompt counts), this returns actual dollar credit. Works with the same API key used for chat/completion.

Both endpoints were discovered by inspecting network requests from their respective web consoles. Neither is documented in official API references.

### Auth

API keys are read from OpenCode's auth config at `~/.local/share/opencode/auth.json`:

```json
{
  "deepseek": {"type": "api", "key": "sk-..."},
  "minimax": {"type": "api", "key": "sk-..."}
}
```

## Build

```bash
cd opencode-widget
xcodegen generate
xcodebuild -scheme OpencodeWidgetApp -configuration Debug build
```

Requires macOS 14+ and Xcode 16+.
