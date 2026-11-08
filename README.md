# agent-ops

A control plane for running many coding agents at once: a live **inbox** that
shows which sessions need you, desktop/phone **notifications**, and shell
helpers to open, delete, and switch between sessions — all in a Zellij layout.

Built on top of [OpenCode](https://opencode.ai). It reads session state from the
**OpenCode server API**, not its private database, so it doesn't break on every
OpenCode upgrade.

> **Why not a database?** The first version queried OpenCode's SQLite tables
> directly. That schema is private and changes. The stable surface is
> `opencode api session.list` — a documented OpenAPI operation that returns the
> same fields (status, tokens, cost, model, title, children) in ~80ms. The
> inbox is built around a small **adapter seam** so a different harness (e.g.
> [pi.dev](https://pi.dev)) can be plugged in later by reimplementing three
> functions.

## What you get

```
┌─────────────────────────────────────────────┐
│  ⚠2 need you · 1 RUN · $2.83/24h           │   Agent Inbox (21%)
│  DP ▓▓▓▓░░░░ 53% day  GG ▒▒▒▒▒▒▒▒ ok       │
│  # STS AGE  SESSION   PROJECT TOKENS COST   │
│  1 ASK  3m  ses_…     agent-ant  12k  $0.4  │
│  2 RUN  1m  ses_…     brain     1.2M $1.1  │
├─────────────────────────────────────────────┤
│  project shells where OpenCode runs (70%)   │
├─────────────────────────────────────────────┤
│  DOCKER · CPU/RAM/DISK/SWAP (sys, 9%)       │
└─────────────────────────────────────────────┘
```

- **`agent-inbox`** — one row per recent session, worst first, with status, age,
  tokens, cost, model, git state, PR/CI state, child-session count, and title.
  Columns drop gracefully as the pane narrows.
- **`agent-limits`** — subscription meters for the line under the summary. A
  provider with a usage API (DevPass today) gets a filled bar for the window
  closest to its cap: yellow from 70%, red from 90% with the reset time. A
  provider without one gets a hatched bar: `ok` until a run on it fails with
  `provider.quota`, then red `LIMIT 40m ago` until a later run on it succeeds.
  Hatched `ok` means no limit seen, not confirmed headroom. `agent-limits show`
  prints every window.
- **`agent-log` plugin** — subscribes to OpenCode's event stream and appends
  durable lines to a log (the inbox uses this for *why* a run ended). Also fires
  desktop and phone notifications.
- **shell helpers** — `so`/`sd`/`sc`/`sn`/`znp`/`zdp` to open, delete, and
  navigate sessions from any shell.
- **`sys`** — a compact Docker/CPU/RAM/disk/swap dashboard.

## Status legend

| Status | Meaning |
|---|---|
| `ASK`  | a permission request is pending — the agent is blocked on you |
| `RUN`  | the agent is working |
| `IDLE` | the agent has gone idle and waits for you |
| `FAIL` | the log recorded a failure for the run |
| `DEAD` | still busy but no update for 15 minutes — died mid-run |
| `STOP` | the log recorded an interrupted run |

`ASK`/`FAIL`/`STOP` come from the log; `RUN`/`IDLE`/`DEAD` are derived from the
session's busy/idle timestamps.

## Install

Dependencies: `jq`, `zellij`, `git`, `curl`, `opencode` (and `notify-send` for
desktop popups, `docker` for the sys pane, `gh` for the PR/CI column).

```sh
git clone https://github.com/Mario8289/agent-ops.git
cd agent-ops
./install.sh      # symlinks bin/ plugin/ layout/ into place
./configure       # interactive: paths, notifications, budget, layout, .zshrc
```

`install.sh` symlinks (doesn't copy), so `git pull` in the repo updates your
setup immediately.

### First-time setup

After `install.sh` and `configure`:

1. **Restart OpenCode** so the `agent-log` plugin loads:
   `opencode service restart`
2. **Subscription limits** (optional, see [Limits line](#limits-line)):
   - DevPass: make `DEVPASS_API_KEY` visible to the process that starts Zellij,
     or put the key in `~/.config/agent-ops/devpass-key` (`chmod 600`).
   - Google, OpenCode Go and others without a usage API: configured via
     `./configure` or `AGENT_LIMITS_TRACK="google:GG opencode-go:GO"` in `~/.config/agent-ops/config`.
     Provider IDs are the ones OpenCode uses; list them with
     `opencode api provider.list | jq -r '.. | .id? // empty'` or look at the
     `model.providerID` of `opencode api session.list`.
   - Check it works: `agent-limits refresh && agent-limits show`
3. **Phone notifications** (if enabled): install the [ntfy](https://ntfy.sh)
   app, subscribe to the topic `configure` printed, and leave the server as
   `ntfy.sh`.
4. **Shell helpers**: `configure` can append the `source` line to `~/.zshrc`;
   otherwise add it yourself, then open a new shell.
5. **Start it**: `zellij --layout agent-ops` (or make it your default layout in
   `config.kdl`). Layout sizes only apply when a Zellij session is created; a
   running session keeps its old pane sizes.

## Configuration

All non-secret configuration lives in a single file: `~/.config/agent-ops/config`.
It is plain shell syntax, written by `./configure` and sourced by the scripts:

```sh
# ~/.config/agent-ops/config
AGENT_SOURCE=opencode
AGENT_LOG="$HOME/agent-runs/agent_health.log"
AGENT_SESSION_LIST="$HOME/.cache/opencode-session-list"
AGENT_BUDGET=25                             # optional daily spend cap ($)
AGENT_LIMITS_TRACK="google:GG opencode-go:GO" # providers to show hatched bars for

# Tunables (all optional, showing defaults):
#AGENT_LIMIT_WARN=70        # yellow bar threshold (%)
#AGENT_LIMIT_ALERT=90       # red bar threshold (%)
#AGENT_LIMIT_HOLD=86400     # seconds a quota failure is remembered without a later success
#AGENT_LIMITS_REFRESH=60    # seconds between background agent-limits refreshes
#AGENT_LIMIT_STALE=300      # seconds before a cached limit is shown dimmed
```

### Secrets (chmod 600, kept separate)

To keep `config` safe for public dotfiles or sharing, secrets live in their own files:

- `~/.config/agent-ops/ntfy-topic` — the random phone-push topic for ntfy.sh (chmod 600).
- `~/.config/agent-ops/devpass-key` — the DevPass gateway API key (chmod 600), only needed if `$DEVPASS_API_KEY` is not exported in your shell/Zellij environment.

## Limits line

The second line of the Agent Inbox shows subscription meters, written by
`agent-limits` and read by `agent-inbox` from a cache. Add a provider with a
usage API as a `fetch_<name>` function in `bin/agent-limits` that writes
`~/.cache/agent-ops/limits/<name>.json`:

```json
{"name":"devpass","label":"DP","status":"ok","updated":1731063000,
 "plan":"lite","windows":[{"label":"day","pct":53,"resets":1731162795}]}
```

A provider that stops updating its file is shown dimmed after five minutes.

## The adapter seam

`bin/agent-inbox` is deliberately split: everything above this line is generic
rendering; the four functions below are the only harness-specific part.

```sh
source_fetch()    # fetch raw session data (opencode api session.list)
source_sessions() # -> id upd busy dir title tot cost kids busykids agent model (TSV)
source_spend()    # -> rolling 24h spend
source_providers() # -> session id and provider ID, for every session (TSV)
```

To target another harness, reimplement those four. Everything else — status
derivation, columns, summary, notifications, `so`/`sd` — stays put.

## How it works

- **Busy vs idle** — OpenCode exposes `time.busy` and `time.idle`; the inbox
  compares them. A session that's been busy with no update for 15 minutes is
  `DEAD`.
- **Why it ended** — OpenCode's events are ephemeral, so the `agent-log` plugin
  appends the durable reason (`WAITING`, `FAILED`, `INTERRUPTED`, `IDLE`) to the
  log. The inbox matches log lines to sessions by an ID prefix.
- **Focused-pane highlight** — `so`/`sc`/`sn` set the Zellij pane title to
  `project - ses_…`; the inbox reverses the matching row.
- **Notifications** — the plugin sends desktop popups and ntfy phone pushes for
  `ASK`/`FAIL`/`IDLE`/`STOP`, suppresses them while you're looking at that
  pane, throttles to one per 30s, and re-pings the phone every 30 minutes (up to
  4×) for things still waiting on you.

## Caveats

- Built against the current OpenCode v2 API. Pin/document the version you run.
- The PR/CI column uses `gh` (GitHub only for now; `glab` can be added for
  GitLab) and is checked at most once per minute per project.
- The **24h spend** figure sums per-session cost for sessions updated in the last
  day (the API exposes session totals, not per-message), so it's an
  approximation, not an invoice.
- The inbox no longer shows **context size** (`CTX`) or a distinct **STALLED**
  state — those came from per-message data the API doesn't expose.

## License

MIT — see [LICENSE](LICENSE).
