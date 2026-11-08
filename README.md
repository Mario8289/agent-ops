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

### Manual steps

Some things can't be automated:

1. **Restart OpenCode** so the `agent-log` plugin loads:
   `opencode service restart`
2. **Phone notifications** (if enabled): install the [ntfy](https://ntfy.sh)
   app, subscribe to the topic `configure` printed, and leave the server as
   `ntfy.sh`.
3. **Zellij**: open the layout with `zellij --layout agent-ops` (or set it as
   your default layout in `config.kdl`).
4. **Shell helpers**: `configure` can append the `source` line to `~/.zshrc`;
   otherwise add it yourself.

## Configuration

`~/.config/agent-ops/config` (written by `configure`, sourced by the scripts):

| Variable | Meaning |
|---|---|
| `AGENT_SOURCE` | session source: `opencode` today, `pi` is a planned second |
| `AGENT_LOG` | where the plugin writes events (default `~/agent-runs/agent_health.log`) |
| `AGENT_SESSION_LIST` | the row→ID cache the inbox writes for `sd`/`so` |
| `AGENT_BUDGET_FILE` | path to the optional daily budget file |

Optional files:

- `~/.config/agent-ops/ntfy-topic` — the phone-push topic (chmod 600, not in git).
  Its existence is the on/off switch: no file, no phone push.
- `~/.config/agent-ops/budget` — a dollar amount; the summary's spend turns red
  once it's reached.
- `~/.config/agent-ops/devpass-key` — the DevPass gateway key (chmod 600, not in
  git), for when the pane does not inherit `$DEVPASS_API_KEY` from your shell.
- `~/.config/agent-ops/limits-providers` — providers to track with a hatched bar,
  one `providerID LABEL` per line (e.g. `google GG`, `opencode-go GO`). A
  provider that hits `provider.quota` is shown even if it is not listed.

## The adapter seam

`bin/agent-inbox` is deliberately split: everything above this line is generic
rendering; the three functions below are the only harness-specific part.

```sh
source_fetch()    # fetch raw session data (opencode api session.list)
source_sessions() # -> id upd busy dir title tot cost kids busykids agent model (TSV)
source_spend()    # -> rolling 24h spend
```

To target another harness, reimplement those three. Everything else — status
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
