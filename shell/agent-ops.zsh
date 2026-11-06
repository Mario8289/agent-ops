# Agent Ops — shell helpers for the "Agent Ops" workflow.
# Source this from ~/.zshrc:  [[ -f ~/.local/share/agent-ops/shell/agent-ops.zsh ]] && source ...
#
#   so <row|id>  open a session (focus its pane, or create one)
#   sd <row|id>  delete a session
#   sc           continue the last session in this directory
#   sn           start a new session in this directory
#   znp [path]   add a project shell to the Zellij stack
#   zdp [name]   close a pane
#
# Row numbers are what you last saw in the Agent Inbox; the inbox writes its row
# order to the session-list cache so `sd 3` means row 3. Check the number just
# before you type it — rows re-sort as agent states change.

# Machine-specific config written by `configure` (paths, source).
[[ -r "${AGENT_OPS_CONFIG:-$HOME/.config/agent-ops/config}" ]] && source "${AGENT_OPS_CONFIG:-$HOME/.config/agent-ops/config}"

_SESSION_LIST_CACHE="${AGENT_SESSION_LIST:-${XDG_CACHE_HOME:-$HOME/.cache}/opencode-session-list}"

# _session_ref <cmd> <number|session-id> — print the session ID for an Agent
# Inbox row number (via the cache file) or pass a full ID through.
_session_ref() {
  local cmd=$1 ref=$2 id
  if [[ $ref == <-> ]]; then
    id=$(sed -n "${ref}p" "$_SESSION_LIST_CACHE" 2>/dev/null)
    if [[ -z $id ]]; then
      print -u2 "$cmd: no row $ref in the Agent Inbox"
      return 1
    fi
  else
    id=$ref
  fi
  print -r -- "$id"
}

# sd [-i] <number|session-id> — delete an OpenCode session (and its children).
sd() {
  local confirm=0 id info title dir reply
  if [[ $1 == -i || $1 == --interactive ]]; then confirm=1; shift; fi
  if [[ -z $1 ]]; then
    print -u2 "usage: sd [-i] <number|session-id>   (numbers are Agent Inbox rows)"
    return 1
  fi
  id=$(_session_ref sd "$1") || return 1
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
  id=$(_session_ref so "$1") || return 1
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

# sc — continue the last session in this directory (opencode --continue).
sc() { _oc_run --continue "$@" }

# sn — start a new session in this directory.
sn() { _oc_run "$@" }

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
znp() {
  if [[ -z ${ZELLIJ:-} ]]; then
    print -u2 "znp: run this inside zellij"
    return 1
  fi
  local dir name
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
  zellij action new-pane --stacked --name "$name" --cwd "$dir"
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
  tab=$(print -r -- "$panes" | jq -r '.[] | select(.is_focused) | .tab_id' | head -n1)
  id=$(print -r -- "$panes" | jq -r --arg name "$name" --argjson tab "${tab:-0}" '
    [.[] | select(.is_plugin == false and .title == $name and .tab_id == $tab)] | .[0].id // empty
  ')
  if [[ -z $id ]]; then
    print -u2 "zdp: no pane named '$name' in this tab"
    return 1
  fi
  zellij action close-pane --pane-id "terminal_$id"
}
