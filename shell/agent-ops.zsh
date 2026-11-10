# Agent Ops — shell helpers for the "Agent Ops" workflow.
# Source this from ~/.zshrc:  [[ -f ~/.local/share/agent-ops/shell/agent-ops.zsh ]] && source ...
#
#   so <row|id>  open a session (focus its pane, or create one)
#   sd <row|id>  delete a session
#   sa <row|id>  archive (mark done) — hides it from the live inbox; -u to undo
#   sl           list the full long tail (uncapped, archived rows flagged)
#   sc [-o|-c]   continue the last session here (-o OpenCode, -c Claude)
#   sn [-o|-c]   start a new session here (-o OpenCode, -c Claude)
#   znp [path]   add a project shell to the Zellij stack
#   zdp [name]   close a pane
#
# Row numbers are what you last saw in the Agent Inbox; the inbox writes its row
# order to the session-list cache so `sd 3` means row 3. Check the number just
# before you type it — rows re-sort as agent states change.

# Machine-specific config written by `configure` (paths, source).
[[ -r "${AGENT_OPS_CONFIG:-$HOME/.config/agent-ops/config}" ]] && source "${AGENT_OPS_CONFIG:-$HOME/.config/agent-ops/config}"

_SESSION_LIST_CACHE="${AGENT_SESSION_LIST:-${XDG_CACHE_HOME:-$HOME/.cache}/opencode-session-list}"
_ARCHIVED_FILE="${AGENT_ARCHIVED_FILE:-$HOME/.config/agent-ops/archived}"

# _session_ref <cmd> <number|session-id> [allow_cc] — print the session ID for
# an Agent Inbox row number (via the cache file) or pass a full ID through.
# Claude Code rows (ids prefixed "cc_") are rejected unless the caller passes a
# non-empty third arg (so handles them; sd/sa do not control them from here).
_session_ref() {
  local cmd=$1 ref=$2 allow_cc=${3:-} id
  if [[ $ref == <-> ]]; then
    id=$(sed -n "${ref}p" "$_SESSION_LIST_CACHE" 2>/dev/null)
    if [[ -z $id ]]; then
      print -u2 "$cmd: no row $ref in the Agent Inbox"
      return 1
    fi
  else
    id=$ref
  fi
  if [[ $id == cc_* && -z $allow_cc ]]; then
    print -u2 "$cmd: '$id' is a Claude Code session — not supported by $cmd yet"
    return 1
  fi
  print -r -- "$id"
}

# sd [-i] <number|session-id> — delete a session.
#   ses_  OpenCode: deletes the session and its children via the API.
#   cc_   Claude Code: removes the session transcript (Claude Code keeps no
#         other state). This is irreversible but, like OpenCode, deletes without
#         prompting; pass -i to confirm first.
# Either way the id is also dropped from the archive file, so a deleted session
# never leaves a dangling "done" mark behind.
sd() {
  local confirm=0 id label reply
  if [[ $1 == -i || $1 == --interactive ]]; then confirm=1; shift; fi
  if [[ -z $1 ]]; then
    print -u2 "usage: sd [-i] <number|session-id>   (numbers are Agent Inbox rows)"
    return 1
  fi
  id=$(_session_ref sd "$1" allow_cc) || return 1

  if [[ $id == cc_* ]]; then
    local ccbin ccfile
    ccbin=$(command -v agent-cc-sessions 2>/dev/null)
    if [[ -z $ccbin ]]; then
      print -u2 "sd: agent-cc-sessions not found on PATH (can't delete a Claude Code session)"
      return 1
    fi
    ccfile=$("$ccbin" path "$id" 2>/dev/null)
    if [[ -z $ccfile || ! -f $ccfile ]]; then
      print -u2 "sd: no Claude Code transcript for $id"
      return 1
    fi
    label=$(_session_label "$id")
    print -r -- "Claude Code session $id"
    print -r -- "  ${label:-(no title)}"
    print -r -- "  file:  $ccfile"
    if (( confirm )); then
      read -r "reply?Delete this session's transcript? This cannot be undone. [y/N] "
      [[ $reply == [yY] ]] || { print -r -- "aborted"; return 1 }
    fi
    rm -f -- "$ccfile" || { print -u2 "sd: could not remove $ccfile"; return 1 }
    _sd_unarchive "$id"
    print -r -- "deleted $id"
    return 0
  fi

  local info title dir
  info=$(opencode api session.get --param "sessionID=$id" 2>/dev/null)
  if [[ -z $(print -r -- "$info" | jq -r '.data.id // empty' 2>/dev/null) ]]; then
    print -u2 "sd: no session with id $id"
    return 1
  fi
  title=$(print -r -- "$info" | jq -r '.data.title // "(untitled)"')
  dir=$(print -r -- "$info" | jq -r '.data.location.directory // "?"')
  print -r -- "session $id"
  print -r -- "  title: $title"
  print -r -- "  dir:   $dir"
  if (( confirm )); then
    read -r "reply?Delete this session and its child sessions? [y/N] "
    [[ $reply == [yY] ]] || { print -r -- "aborted"; return 1 }
  fi
  opencode session delete "$id"
  _sd_unarchive "$id"
}

# _sd_unarchive <id> — drop an id from the archive file after it is deleted, so
# no stale "done" mark lingers. No-op if the file or id is absent.
_sd_unarchive() {
  local id=$1 tmp
  [[ -r $_ARCHIVED_FILE ]] || return 0
  grep -qxF -- "$id" "$_ARCHIVED_FILE" 2>/dev/null || return 0
  tmp=$(mktemp "${_ARCHIVED_FILE}.XXXXXX") || return 0
  grep -vxF -- "$id" "$_ARCHIVED_FILE" > "$tmp" 2>/dev/null
  mv -f "$tmp" "$_ARCHIVED_FILE"
}

# _session_label <id> — a short "title (project)" for an id, for confirming
# which session a command is about to act on (rows re-sort, so the number you
# typed may not be what you saw). Best-effort: OpenCode via the API, Claude Code
# via its transcript dir. Prints nothing if it can't resolve.
_session_label() {
  local id=$1 title dir
  if [[ $id == cc_* ]]; then
    local ccbin out
    ccbin=$(command -v agent-cc-sessions 2>/dev/null) || return
    out=$("$ccbin" resolve "$id" 2>/dev/null)
    dir=${out#*$'\t'}; [[ $dir == "$out" ]] && dir=
  else
    local info
    info=$(opencode api session.get --param "sessionID=$id" 2>/dev/null)
    title=$(print -r -- "$info" | jq -r '.data.title // empty' 2>/dev/null)
    dir=$(print -r -- "$info" | jq -r '.data.location.directory // empty' 2>/dev/null)
  fi
  local out=
  [[ -n $title ]] && out=$title
  [[ -n $dir ]] && out="${out:+$out }(${dir:t})"
  [[ -n $out ]] && print -r -- "$out"
}

# sa [-u] <number|session-id> — archive a session ("I'm done with this"), hiding
# it from the live Agent Inbox without deleting its transcript. -u un-archives.
# Works for both OpenCode (ses_) and Claude Code (cc_) rows — archiving is just
# a mark on your side, harness-agnostic. The inbox auto-unarchives a session
# that later goes ASK/FAIL/DEAD, so "done" can never bury something urgent.
# Browse archived (and aged-out) sessions any time with `sl`. Prints the
# session's title/project so you can catch a row-number mismatch (rows re-sort).
sa() {
  local undo=0 id tmp label
  if [[ $1 == -u || $1 == --undo ]]; then undo=1; shift; fi
  if [[ -z $1 ]]; then
    print -u2 "usage: sa [-u] <number|session-id>   (numbers are Agent Inbox rows)"
    return 1
  fi
  id=$(_session_ref sa "$1" allow_cc) || return 1
  label=$(_session_label "$id")
  mkdir -p "${_ARCHIVED_FILE:h}" 2>/dev/null
  touch "$_ARCHIVED_FILE" 2>/dev/null
  if (( undo )); then
    tmp=$(mktemp "${_ARCHIVED_FILE}.XXXXXX") || return 1
    grep -vxF -- "$id" "$_ARCHIVED_FILE" > "$tmp" 2>/dev/null
    mv -f "$tmp" "$_ARCHIVED_FILE"
    print -r -- "un-archived $id${label:+  — $label}"
  else
    if grep -qxF -- "$id" "$_ARCHIVED_FILE" 2>/dev/null; then
      print -r -- "already archived: $id${label:+  — $label}"
      return 0
    fi
    print -r -- "$id" >> "$_ARCHIVED_FILE"
    print -r -- "archived $id${label:+  — $label}"
    print -r -- "  (hidden from the live inbox; sa -u to undo, sl to list)"
  fi
}

# sl — list the full long tail: every session in the window, uncapped and with
# archived rows shown and flagged. A one-shot snapshot (not the live pane), so
# it's safe to scroll and pipe to grep. Does not disturb the live inbox's row
# numbering. Honours COLUMNS for width.
sl() {
  local bin
  bin=$(command -v agent-inbox 2>/dev/null)
  if [[ -z $bin ]]; then
    print -u2 "sl: agent-inbox not found on PATH"
    return 1
  fi
  "$bin" --all "$@"
}

# so <number|session-id> — open a session in OpenCode, from anywhere.
# In Zellij: if the session is already open in a pane, focus that pane; else
# open it in a new stacked pane named after the project, in the project's
# directory (you get a shell there when OpenCode quits). Outside Zellij, or with
# extra arguments, it runs OpenCode here in the project directory; extra
# arguments go to opencode.
so() {
  local id dir
  if [[ -z $1 ]]; then
    print -u2 "usage: so <number|session-id>   (numbers are Agent Inbox rows)"
    return 1
  fi
  id=$(_session_ref so "$1" allow_cc) || return 1

  # Claude Code row: recover the full UUID + cwd from its transcript and resume
  # it with `claude --resume`. No pane-title watcher (see _cc_run).
  if [[ $id == cc_* ]]; then
    _cc_open "$id" "${@:2}"
    return
  fi

  if [[ ! $id =~ ^ses_[A-Za-z0-9]+$ ]]; then
    print -u2 "so: '$id' is not a session ID"
    return 1
  fi
  dir=$(opencode api session.get --param "sessionID=$id" 2>/dev/null |
        jq -r '.data.location.directory // empty' 2>/dev/null)
  if [[ -z $dir ]]; then
    print -u2 "so: no session with id $id"
    return 1
  fi
  if [[ ! -d $dir ]]; then
    print -u2 "so: the session's directory no longer exists: $dir"
    return 1
  fi
  if [[ -n ${ZELLIJ:-} && $# -eq 1 ]]; then
    local name=${dir:t} panes running idle busy
    panes=$(zellij action list-panes --json 2>/dev/null)
    running=$(print -r -- "$panes" | jq -r --arg id "$id" \
      '[.[] | select((.is_plugin | not) and (.title | contains($id))) | .id][0] // empty' 2>/dev/null)
    if [[ -n $running ]]; then
      zellij action focus-pane-id "terminal_$running"
      return
    fi
    local tab_sel='($cur | tonumber) as $c | ([.[] | select((.is_plugin | not) and .id == $c) | .tab_id][0]) as $tab'
    idle=$(print -r -- "$panes" | jq -r --arg name "$name" --arg cur "${ZELLIJ_PANE_ID:-0}" \
      "$tab_sel | [.[] | select((.is_plugin | not) and .tab_id == \$tab and .title == \$name) | .id][0] // empty" 2>/dev/null)
    if [[ -n $idle ]]; then
      zellij action focus-pane-id "terminal_$idle"
      zellij action write-chars --pane-id "terminal_$idle" "(cd ${(q)dir} && _oc_run -s ${(q)id})"
      zellij action write --pane-id "terminal_$idle" 13
      return
    fi
    busy=$(print -r -- "$panes" | jq -r --arg name "$name" --arg cur "${ZELLIJ_PANE_ID:-0}" \
      "$tab_sel | [.[] | select((.is_plugin | not) and .tab_id == \$tab and (.title | startswith(\$name + \" - \"))) | .id][0] // empty" 2>/dev/null)
    if [[ -n $busy ]]; then
      zellij action focus-pane-id "terminal_$busy"
      print -u2 "so: the '$name' pane is already running another session; quit it there first"
      return 1
    fi
    zellij action new-pane --stacked --name "$name" --cwd "$dir" -- \
      zsh -ic "_oc_run -s ${(q)id}; exec zsh" >/dev/null
    return
  fi
  ( cd "$dir" && _oc_run -s "$id" "${@:2}" )
}

# _cc_open <cc_id> [extra args] — re-open a Claude Code session by its inbox id.
# Resolves the truncated "cc_" id back to the full UUID and cwd via
# agent-cc-sessions, then (in Zellij) focuses an existing/idle pane or opens a
# new one running `claude --resume <uuid>`. No pane-title watcher (see _cc_run).
_cc_open() {
  local id=$1 ccbin out uuid dir
  ccbin=$(command -v agent-cc-sessions 2>/dev/null)
  if [[ -z $ccbin ]]; then
    print -u2 "so: agent-cc-sessions not found — cannot re-open Claude sessions"
    return 1
  fi
  out=$("$ccbin" resolve "$id" 2>/dev/null)
  uuid=${out%%$'\t'*}
  dir=${out#*$'\t'}
  if [[ -z $uuid || $uuid == "$out" ]]; then
    print -u2 "so: could not find a Claude Code transcript for '$id'"
    return 1
  fi
  if [[ -z $dir || ! -d $dir ]]; then
    print -u2 "so: the session's directory no longer exists: ${dir:-?}"
    return 1
  fi
  if ! command -v claude >/dev/null 2>&1; then
    print -u2 "so: claude not found — install Claude Code to re-open its sessions"
    return 1
  fi
  if [[ -n ${ZELLIJ:-} && $# -eq 1 ]]; then
    local name=${dir:t} panes idle busy tab_sel
    panes=$(zellij action list-panes --json 2>/dev/null)
    # No reliable per-pane id to match a running Claude session on (no watcher),
    # so reuse an idle project pane if there is one, else open a new pane.
    tab_sel='($cur | tonumber) as $c | ([.[] | select((.is_plugin | not) and .id == $c) | .tab_id][0]) as $tab'
    idle=$(print -r -- "$panes" | jq -r --arg name "$name" --arg cur "${ZELLIJ_PANE_ID:-0}" \
      "$tab_sel | [.[] | select((.is_plugin | not) and .tab_id == \$tab and .title == \$name) | .id][0] // empty" 2>/dev/null)
    if [[ -n $idle ]]; then
      zellij action focus-pane-id "terminal_$idle"
      zellij action write-chars --pane-id "terminal_$idle" "(cd ${(q)dir} && claude --resume ${(q)uuid})"
      zellij action write --pane-id "terminal_$idle" 13
      return
    fi
    zellij action new-pane --stacked --name "$name" --cwd "$dir" -- \
      zsh -ic "claude --resume ${(q)uuid}; exec zsh" >/dev/null
    return
  fi
  ( cd "$dir" && command claude --resume "$uuid" "${@:2}" )
}

# _default_harness — print the harness sn/sc use with no -o/-c flag. Reads
# AGENT_DEFAULT_HARNESS (config); opencode is the fallback for unset/invalid.
_default_harness() {
  case ${AGENT_DEFAULT_HARNESS:-opencode} in
    claude)   print -r -- claude ;;
    *)        print -r -- opencode ;;   # opencode is the fallback for unset/invalid
  esac
}

# sc [-o|-c] — continue the last session in this directory.
#   sc      the default harness (AGENT_DEFAULT_HARNESS, default opencode)
#   sc -o   OpenCode (opencode --continue)
#   sc -c   Claude Code (claude --continue)
sc() {
  local h
  case $1 in
    -o) shift; h=opencode ;;
    -c) shift; h=claude ;;
    *)  h=$(_default_harness) ;;
  esac
  if [[ $h == claude ]]; then _cc_run --continue "$@"; else _oc_run --continue "$@"; fi
}

# sn [-o|-c] — start a new session in this directory.
#   sn      the default harness (AGENT_DEFAULT_HARNESS, default opencode)
#   sn -o   OpenCode (opencode)
#   sn -c   Claude Code (claude)
sn() {
  local h
  case $1 in
    -o) shift; h=opencode ;;
    -c) shift; h=claude ;;
    *)  h=$(_default_harness) ;;
  esac
  if [[ $h == claude ]]; then _cc_run "$@"; else _oc_run "$@"; fi
}

# _cc_run [...] — run Claude Code in this directory. Unlike _oc_run there is no
# pane-title watcher: Claude Code has no API to poll for the new session id, so
# the inbox cannot reverse-highlight the focused Claude row (the session still
# appears with correct RUN/IDLE/ASK state via the transcript reader and the
# agent-cc-log hook). Outside Zellij this is just `claude`.
_cc_run() {
  if ! command -v claude >/dev/null 2>&1; then
    print -u2 "claude: not found — install Claude Code to use the -c flag"
    return 1
  fi
  command claude "$@"
}

# _oc_run [...] — run opencode and keep the Zellij pane title on the session:
#   brain - ses_e5488e86cffevKupGMvanwumSA
# With -s/--session the title is exact from the start. Without it (sc, sn) the
# title follows whichever session in this directory is busy or was viewed last,
# so a new session shows up a couple of seconds after it exists. The Agent
# Inbox uses this title to highlight the row for the focused pane.
# Outside Zellij this is just `opencode`.
_oc_run() {
  if [[ -z ${ZELLIJ:-} || -z ${ZELLIJ_PANE_ID:-} ]]; then
    command opencode "$@"
    return
  fi

  local pane=$ZELLIJ_PANE_ID dir=$PWD base=${PWD:t} id= arg prev=
  for arg in "$@"; do
    case $arg in
      --session=*) id=${arg#*=} ;;
      *) [[ $prev == -s || $prev == --session ]] && id=$arg ;;
    esac
    prev=$arg
  done

  local orig watcher=
  orig=$(zellij action list-panes --json 2>/dev/null |
         jq -r --arg p "$pane" '.[] | select((.is_plugin|not) and (.id|tostring) == $p) | .title' 2>/dev/null |
         head -n 1)
  [[ -n $orig ]] || orig=$base

  if [[ -n $id ]]; then
    zellij action rename-pane -p "$pane" "$base - $id" >/dev/null 2>&1
  else
    (
      start=$(( $(date +%s) * 1000 )) last=
      while sleep 2; do
        cur=$(opencode api session.list 2>/dev/null | jq -r --arg dir "$dir" --argjson start "$start" '
          [ .data[]
            | select((.parentID // null) == null)
            | select(.location.directory == $dir)
            | select((.time.updated // 0) > $start or (.time.viewed // 0) > $start)
          ]
          | sort_by([ (if (.time.busy // 0) > (.time.idle // 0) then 0 else 1 end),
                      -((.time.viewed // 0)), -((.time.updated // 0)) ])
          | .[0].id // empty
        ' 2>/dev/null)
        [[ -z $cur || $cur == $last ]] && continue
        last=$cur
        zellij action rename-pane -p "$pane" "$base - $cur" >/dev/null 2>&1
      done
    ) >/dev/null 2>&1 &
    watcher=$!
  fi

  command opencode "$@"
  local rc=$?

  [[ -n $watcher ]] && kill "$watcher" 2>/dev/null
  zellij action rename-pane -p "$pane" "$orig" >/dev/null 2>&1
  return $rc
}

# znp [path] — add a project shell to the Zellij "Agent Ops" stack.
# If a pane for that project already exists in this tab, focus it instead.
znp() {
  if [[ -z ${ZELLIJ:-} ]]; then
    print -u2 "znp: run this inside zellij"
    return 1
  fi
  local dir name panes tab id
  if (( $# == 0 )); then
    dir=$HOME
    name=home
  else
    dir=$1
    if [[ $dir == "~" ]]; then
      dir=$HOME
    elif [[ $dir == "~/"* ]]; then
      dir=${dir/#\~/$HOME}
    elif [[ $dir != /* ]]; then
      dir=$HOME/$dir
    fi
    dir=${dir:A}
    name=${dir:t}
  fi
  if [[ ! -d $dir ]]; then
    print -u2 "znp: no such directory: $dir"
    return 1
  fi
  panes=$(zellij action list-panes --json 2>/dev/null)
  # is_focused is true once per tab, so find our own pane's tab instead.
  tab=$(print -r -- "$panes" | jq -r --arg cur "${ZELLIJ_PANE_ID:-}" '
    [.[] | select((.is_plugin | not) and (.id | tostring) == $cur) | .tab_id][0] // empty
  ')
  id=$(print -r -- "$panes" | jq -r --arg name "$name" --argjson tab "${tab:-0}" '
    [.[] | select(.is_plugin == false
                  and .tab_id == $tab
                  and (.title == $name or (.title | startswith($name + " - "))))]
    | .[0].id // empty
  ')
  if [[ -n $id ]]; then
    zellij action focus-pane-id "terminal_$id"
    return
  fi
  # Zellij 0.45 ignores --cwd unless an explicit command is given, so name the
  # shell rather than relying on the default one.
  zellij action new-pane --stacked --name "$name" --cwd "$dir" -- "${SHELL:-zsh}"
}

# zdp [name] — close a pane in the current Zellij tab.
zdp() {
  if [[ -z ${ZELLIJ:-} ]]; then
    print -u2 "zdp: run this inside zellij"
    return 1
  fi
  if (( $# == 0 )); then
    zellij action close-pane
    return
  fi
  local name=$1 panes tab id
  panes=$(zellij action list-panes --json 2>/dev/null) || {
    print -u2 "zdp: could not list panes"
    return 1
  }
  tab=$(print -r -- "$panes" | jq -r --arg cur "${ZELLIJ_PANE_ID:-}" '
    [.[] | select((.is_plugin | not) and (.id | tostring) == $cur) | .tab_id][0] // empty
  ')
  id=$(print -r -- "$panes" | jq -r --arg name "$name" --argjson tab "${tab:-0}" '
    [.[] | select(.is_plugin == false and .title == $name and .tab_id == $tab)] | .[0].id // empty
  ')
  if [[ -z $id ]]; then
    print -u2 "zdp: no pane named '$name' in this tab"
    return 1
  fi
  zellij action close-pane --pane-id "terminal_$id"
}
