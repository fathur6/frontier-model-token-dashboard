# OpenCode Menu Bar Widget

The widget reads ChatGPT/Codex subscription quota from the OAuth session used
by Codex. It calls the authenticated `/backend-api/wham/usage` endpoint and
does not store passwords, cookies, session tokens, or response bodies.

## OpenAI quota setup

Sign in with Codex so that `~/.codex/auth.json` contains the OAuth session.
The widget polls `https://chatgpt.com/backend-api/wham/usage` every 15 minutes
using the access token and optional account ID from that file. Tokens are only
held in memory while the request is made; they are not logged or copied into
the widget cache.

If the response is `401`, re-authenticate or switch to the intended ChatGPT
account in Codex. The client classifies both returned windows by their
`limit_window_seconds` duration (`18000` = 5-hour, `604800` = weekly) rather
than by position, so it still works when the payload only carries one window
or reverses `primary_window`/`secondary_window`. A missing or malformed window
does not hide the other, and a failed refresh keeps the last known value for
each window independently.

## Local usage trends (DAF-26)

The **Usage** chart is observed local token history, not the remaining-quota
endpoint. It combines all supported clients regardless of which app is active:

- **OpenCode**: the default `~/.local/share/opencode/opencode.db`, read-only.
  V2 `session_message` and legacy V1 `message` are supported together; exact
  migrated message IDs prefer V2 without losing V1-only messages.
- **Codex**: `~/.codex/sessions` and `~/.codex/archived_sessions`, including
  fractional timestamps and model metadata from `session_meta`/`turn_context`.
  The declared `model_provider` must identify OpenAI or DeepSeek. Codex is **not**
  automatically classified as OpenAI. Unknown/custom provider aliases are not
  guessed from model names; declared non-provider proxy base URLs are excluded.
  Same-provider turns inherit the last declared base URL (including exclusions),
  URL-only changes revalidate attribution, and an explicit different-provider
  switch starts with a clean endpoint unless that turn declares a new URL.
- **Hermes**: `~/.hermes/state.db` `session_model_usage`, routed by
  `billing_provider` and, when supplied, the canonical provider base URL.

Metrics remain **DeepSeek input + cache-read + cache-write** and **OpenAI input**,
with the existing trailing three-hour mean, blue/green colors and independent
zero-based axes. The default view is 168 hours; recoverable local history is
30 days, with existing ledger retention unchanged. No new authentication,
telemetry or remote usage/billing API is involved.

### Recovery, duplicates and unavailable data

Successful reads replace source/event observations transactionally in the local
widget ledger, then reproject historical hours. Refreshes are idempotent; prior
hours are recovered even if the widget wasn't running when usage occurred.
Older overlapping refreshes cannot replace a newer source snapshot.

Codex cumulative counters use per-session deltas (including a pre-window
baseline); repeated counters, exact event replays and session/archive copies do
not add usage twice. Independent sessions are never collapsed because they share
an account or identical token values. Counter decreases without an explicit new
session are treated conservatively as replay, not invented usage after a reset.
Last-only events without request IDs can only be deduplicated as exact
session/timestamp/token replays. Across clients, only explicit matching provider
request IDs or exact Hermes session mirrors are suppressed; unidentified overlap
cannot safely be guessed.

Request-ID suppression assumes duplicate completed observations, **not** arbitrary
cumulative streaming updates with different values under one ID. It selects by
source priority (OpenCode, Codex, Hermes), then record-ID order; it does not
reconstruct the final/max streaming value. Within Codex, last-only repeats of
the same request ID keep the first matching event before that cross-client step.
Such unsupported shapes can undercount.
Replay regressions cover identical request snapshots and session cumulative
counters, not a general guarantee of request-level streaming reconciliation.

Missing optional apps do not block installed apps. An actual read/parse failure
keeps that source's last durable observations while other sources update; the
menu shows an incomplete-history warning. A failure never commits a half-read
source. A busy/locked widget ledger retains its prior projections. On the first
upgrade, old hourly totals have no source provenance: a larger opaque legacy
total is conservatively retained rather than overwritten by a smaller or partial
reconstruction. It can remain an overestimate until safely superseded; the
upgrade does not claim to repair all old accounting ambiguities.

### Important limits

- Hermes rows are **cumulative**, attributed to `last_seen`, not exact request
  times. A stable row is moved/replaced when it grows or changes hour, avoiding
  duplicate cumulative totals on repeated refresh. This can move a session's
  historical spike; it cannot reconstruct its true per-hour distribution.
- Token counts are independent of model pricing. Unpriced models still plot;
  any contributing unpriced model makes the OpenAI cost estimate **unavailable**
  rather than zero or an incomplete sum. A missing weekly reset also makes the
  quota-window estimate unavailable. No rates are invented.
- Local metadata identifies providers, **not the authenticated billing account**.
  Separate accounts, API billing and subscription usage may have different
  limits even under the same provider name. This chart is not authoritative
  account-wide quota consumption or an invoice. Remote-only activity, unknown
  aliases, custom storage paths, removed logs and clients without token metadata
  are not automatically recovered. A DeepSeek line can correctly be flat if no
  supported local DeepSeek usage falls inside the visible week.
- History readers process metadata only and never log prompts, conversations,
  credentials or payloads. Codex logs are streamed off the UI actor; a complete
  read of large histories can still take several seconds per 15-minute refresh.
