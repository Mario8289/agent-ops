# agent-ops

A control plane for running many coding agents at once: a live **inbox** that
shows which sessions need you, desktop/phone **notifications**, and shell
helpers to open, delete, and switch between sessions — all in a Zellij layout.

Works with [OpenCode](https://opencode.ai) and [Claude
Code](https://claude.com/claude-code) side by side: one inbox lists sessions
from both, with a **HARNESS** column (`OC`/`CC`) telling them apart. It reads
OpenCode state from the **server API** (not its private database, so it survives
upgrades) and Claude Code state from its per-session transcripts.

> **Why not a database?** The first version queried OpenCode's SQLite tables
> directly. That schema is private and changes. The stable surface is
> `opencode api session.list` — a documented OpenAPI operation that returns the
> same fields (status, tokens, cost, model, title, children) in ~80ms. The
> inbox is built around a small **adapter seam** so a different harness (e.g.
> [pi.dev](https://pi.dev)) can be plugged in later by reimplementing three
> functions.

## What you get

```
┌───────────────────────────────────────────────────────┐
│  ⚠2 need you · 1 RUN · $2.83/24h · DP ▓▓▓░ 88% day    │   Agent Inbox (21%)
│  # STS AGE  SESSION   PROJECT TOKENS COST             │
│  1 ASK  3m  ses_…     agent-ant  12k  $0.4            │
│  2 RUN  1m  ses_…     brain     1.2M $1.1             │
├───────────────────────────────────────────────────────┤
│  project shells where OpenCode runs (70%)             │
├───────────────────────────────────────────────────────┤
│  DOCKER · CPU/RAM/DISK/SWAP (sys, 9%)                 │
└───────────────────────────────────────────────────────┘
```

- **`agent-inbox`** — one row per recent session, worst first, with status, age,
  tokens, cost, model, git state, PR/CI state, child-session count, and title.
  Columns drop gracefully as the pane narrows.
- **`agent-limits`** — subscription meters at the end of the summary line. A
  provider with a usage API (DevPass today) gets a small bar for the window
  closest to its cap: yellow from 70%, red from 90% with the reset time. A
  provider without one just reads `ok` until a run on it fails with
  `provider.quota`, then red `LIMIT 40m ago` until a later run on it succeeds.
  `ok` means no limit seen, not confirmed headroom. `agent-limits show` prints
  every window.
- **`agent-log` plugin** — subscribes to OpenCode's event stream and appends
  durable lines to a log (the inbox uses this for *why* a run ended). Also fires
  desktop and phone notifications.
- **shell helpers** — `so`/`sd`/`sa`/`sl`/`sc`/`sn`/`znp`/`zdp` to open, delete,
  archive, list, and navigate sessions from any shell.
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
desktop popups, `docker` for the sys pane, `gh` for the PR/CI column,
`claude` for the Claude Code harness).

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
AGENT_SOURCES="opencode claude"             # harnesses to watch (space-separated)
AGENT_LOG="$HOME/agent-runs/agent_health.log"
AGENT_SESSION_LIST="$HOME/.cache/opencode-session-list"
AGENT_BUDGET=25                             # optional daily spend cap ($)
AGENT_LIMITS_TRACK="google:GG opencode-go:GO" # providers to show hatched bars for

# Tunables (all optional, showing defaults):
#AGENT_MAX_ROWS=12          # max sessions fetched/ranked (pane height caps display)
#AGENT_DEFAULT_HARNESS=opencode  # harness sn/sc use with no -o/-c flag (opencode|claude)
#AGENT_LIMIT_WARN=70        # yellow bar threshold (%)
#AGENT_LIMIT_ALERT=90       # red bar threshold (%)
#AGENT_LIMIT_HOLD=86400     # seconds a quota failure is remembered without a later success
#AGENT_LIMITS_REFRESH=60    # seconds between background agent-limits refreshes
#AGENT_LIMIT_STALE=300      # seconds before a cached limit is shown dimmed
```

`./configure` reuses your previous answers as defaults on a re-run. Answer `-`
to clear a value that has a default.

### Secrets (chmod 600, kept separate)

To keep `config` safe for public dotfiles or sharing, secrets live in their own files:

- `~/.config/agent-ops/ntfy-topic` — the random phone-push topic for ntfy.sh (chmod 600).
- `~/.config/agent-ops/devpass-key` — the DevPass gateway API key (chmod 600), only needed if `$DEVPASS_API_KEY` is not exported in your shell/Zellij environment.

## Limits line

The end of the Agent Inbox's summary line shows subscription meters, written by
`agent-limits` and read by `agent-inbox` from a cache. Add a provider with a
usage API as a `fetch_<name>` function in `bin/agent-limits` that writes
`~/.cache/agent-ops/limits/<name>.json`:

```json
{"name":"devpass","label":"DP","status":"ok","updated":1731063000,
 "plan":"lite","windows":[{"label":"day","pct":53,"resets":1731162795}]}
```

A provider that stops updating its file is shown dimmed after five minutes.

## The adapter seam

`bin/agent-inbox` is deliberately split: everything above the seam is generic
rendering; each harness is a small source adapter below it. A harness is four
functions — `<harness>_fetch`, `<harness>_sessions`, `<harness>_spend`,
`<harness>_providers` — and its name in `AGENT_SOURCES`. The `source_*`
dispatchers run every enabled harness and merge the rows, so the renderer never
knows which harness a row came from.

```sh
# one tab-separated record per session, HARNESS first:
#   harness  id  upd  busy  dir  title  tot  cost  kids  busykids  agent  model
AGENT_SOURCES="opencode claude"   # which harnesses to watch
```

- **opencode** reads `opencode api session.list`.
- **claude** calls `bin/agent-cc-sessions`, which scrapes
  `~/.claude/projects/*/*.jsonl`. Claude Code has no server to query, so this is
  the one brittle, schema-dependent part; it is kept in its own script so a
  transcript-format change only touches that file.

To target another harness, add its four functions and list it in
`AGENT_SOURCES`. Everything else — status derivation, columns, summary,
notifications, `so`/`sd` — stays put.

### Harnesses

| Harness | State source | Events / notifications | open/continue (`so`/`sc`/`sn`) | delete (`sd`) |
|---|---|---|---|---|
| OpenCode (`OC`) | server API | `agent-log` plugin | yes (with focus highlight) | yes |
| Claude Code (`CC`) | JSONL transcripts | `agent-cc-log` hook | yes (no focus highlight) | not yet |

Claude Code notes:

- **Busy/idle** comes from the `agent-cc-log` hook (wired into
  `~/.claude/settings.json`), which writes the same log the OpenCode plugin
  does. Without the hook a session's state is guessed from transcript mtime, so
  install the hook (`./configure` does it) for accurate `ASK`/`RUN`/`IDLE`.
- **Cost reads `$0` on some subscription plans** — those don't report per-call
  cost, so the 24h spend figure undercounts Claude Code usage. Not a bug.
- **Child sessions** (sub-agents) aren't counted yet; the `SUB` column shows `0`
  for Claude Code rows.
- **Open/continue works, with caveats.** `so <row>` on a `CC` row recovers the
  session's full UUID from its transcript and resumes it with `claude --resume`;
  `sn -c` / `sc -c` start/continue a Claude session. Claude Code has no server
  to poll for the new session id, so these panes get **no focus highlight** (the
  row still shows correct state). `sd` does not delete Claude sessions.

## Shell helpers

Loaded by sourcing `shell/agent-ops.zsh`. Row numbers are the ones you last saw
in the inbox (it writes the row→id map to its cache); check the number just
before you type it, since rows re-sort as states change.

| Command | What it does |
|---|---|
| `so <row\|id>` | open/focus a session (OpenCode or Claude Code — auto-detected from the id) |
| `sd [-i] <row\|id>` | delete an OpenCode session and its children (`-i` to confirm) |
| `sa <row\|id>` | archive ("I'm done") — hide it from the live inbox without deleting |
| `sa -u <row\|id>` | un-archive |
| `sl` | list the full long tail: every session in the window, uncapped, archived rows flagged — a one-shot snapshot, safe to pipe to `grep` |
| `sn [-o\|-c]` | start a new session here (`-o` OpenCode, `-c` Claude Code; no flag = `AGENT_DEFAULT_HARNESS`, default OpenCode) |
| `sc [-o\|-c]` | continue the last session here (same flags as `sn`) |
| `znp [path]` | add a project shell to the Zellij stack |
| `zdp [name]` | close a pane |

### Archiving ("done" vs "idle")

Neither harness has a "finished" flag — a session is just a conversation you can
resume, so `IDLE` means both "its turn is done" and "it's waiting for your next
prompt". When you're actually done with one, `sa <row>` marks it done and hides
it from the live inbox (the transcript is kept — this is the non-destructive
version of `sd`). Archived sessions live in `~/.config/agent-ops/archived` (one
id per line; delete the file to clear all marks).

An archived session that later needs you — goes `ASK`/`FAIL`/`DEAD` —
**reappears automatically and its mark is cleared**, so "done" can never bury
something urgent. A `STOP` (interrupted) session is the exception: an interrupt
is usually something you did on purpose, so archiving it keeps it hidden. To see
archived (and aged-out) sessions any time, run `sl`.

## How it works

- **Busy vs idle** — OpenCode exposes `time.busy` and `time.idle`; the inbox
  compares them. A session that's been busy with no update for 15 minutes is
  `DEAD`.
- **Why it ended** — OpenCode's events are ephemeral, so the `agent-log` plugin
  appends the durable reason (`WAITING`, `FAILED`, `INTERRUPTED`, `IDLE`) to the
  log. The inbox matches log lines to sessions by an ID prefix.
- **Focused-pane highlight** — `so`/`sc`/`sn` set the Zellij pane title to
  `project - ses_…`; the inbox reverses the matching row. Claude Code sessions
  get no highlight (there's no API to recover the new session id for the title).
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
