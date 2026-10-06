#!/usr/bin/env bash
#
# run-agents.sh — launch several opencode agents from a task manifest.
#
# Works with the workspace produced by scripts/build_workspace.py:
#   tasks/ARCHITECTURE.md   shared context given to every agent
#   tasks/NN-slug.md        one spec per task
#   tasks/manifest.tsv      id|slug|category|depends|file
#
# Typical use:
#   ./run-agents.sh serve-start                 # headless opencode server on this host
#   ./run-agents.sh run --mode parallel -j 3    # agents attach to that server
#   ./run-agents.sh run --mode sequential
#   ./run-agents.sh run --server http://srv:4096 --remote-dir /srv/app   # from a client
#
# Requires bash >= 4 and the `opencode` CLI.

# Example:
# ./run-agents.sh run --dry-run --mode parallel -j 3 --worktrees   # prints the commands only
# ./run-agents.sh serve-start --host 0.0.0.0 --port 4096           # server on the host
# ./run-agents.sh run --mode parallel -j 3 --worktrees

set -o pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo "error: bash >= 4 required (macOS: brew install bash)" >&2
  exit 1
fi

# ---------- defaults (override with flags or env) ----------
PROJECT_DIR="${AGENTS_PROJECT_DIR:-$PWD}"
MANIFEST="${AGENTS_MANIFEST:-}"
ARCH_FILE="${AGENTS_ARCH_FILE:-}"
STATE_DIR="${AGENTS_STATE_DIR:-}"
HOST="${AGENTS_HOST:-127.0.0.1}"
PORT="${AGENTS_PORT:-4096}"
SERVER_URL=""
REMOTE_DIR=""
STANDALONE=0
MODE=parallel
MAX_PARALLEL=3
MODEL=""
AGENT=""
USE_WORKTREES=0
IGNORE_DEPS=0
DRY_RUN=0
FORCE=0
ONLY=""
WT_ROOT=""

SELF=$(basename "$0")

die() { echo "error: $*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

usage() {
  cat <<EOF
Usage: $SELF <command> [options]

Commands:
  serve-start      start a headless 'opencode serve' (background, pid file in state dir)
  serve-stop       stop that server
  serve-status     tell whether the server port answers
  run              launch the agents described in the manifest
  status           show per-task status
  logs <id>        follow the log of one task
  merge            merge agent/<slug> branches (worktree mode) into the current branch
  clean            remove worktrees and branches created by --worktrees

Options for 'serve-*':
  --host H         bind address (default $HOST; use 0.0.0.0 so remote agents can connect)
  --port P         port (default $PORT)
  (set OPENCODE_SERVER_PASSWORD to protect a server reachable from the network)

Options for 'run':
  --mode M         parallel | sequential            (default $MODE)
  -j, --max-parallel N   max concurrent agents      (default $MAX_PARALLEL; ignored if sequential)
  --server URL     attach agents to this server (default http://127.0.0.1:PORT, auto-started if local)
  --remote-dir D   project path ON THE SERVER (when the script runs on a client machine)
  --standalone     no server: each agent is a plain 'opencode run'
  --model P/M      model, e.g. anthropic/claude-sonnet-4-6
  --agent NAME     opencode agent profile
  --worktrees      one git worktree + branch per task (safe parallel edits, then use 'merge')
  --only 1,3,5     run only these task ids
  --no-deps        ignore the 'depends' column
  --force          re-run tasks already marked done
  --dry-run        print the opencode commands without running them

Common options:
  --project DIR    project root (default: current dir)
  --manifest FILE  default: <project>/tasks/manifest.tsv
  --state DIR      default: <project>/.agents
EOF
}

# ---------- argument parsing ----------
CMD="${1:-}"
[[ -z $CMD || $CMD == -h || $CMD == --help ]] && { usage; exit 0; }
shift
LOG_ARG=""
if [[ $CMD == logs ]]; then LOG_ARG="${1:-}"; [[ -n $LOG_ARG ]] && shift; fi

while (( $# )); do
  case $1 in
    --mode)            MODE=$2; shift 2 ;;
    -j|--max-parallel) MAX_PARALLEL=$2; shift 2 ;;
    --server)          SERVER_URL=$2; shift 2 ;;
    --remote-dir)      REMOTE_DIR=$2; shift 2 ;;
    --standalone)      STANDALONE=1; shift ;;
    --model)           MODEL=$2; shift 2 ;;
    --agent)           AGENT=$2; shift 2 ;;
    --worktrees)       USE_WORKTREES=1; shift ;;
    --only)            ONLY=$2; shift 2 ;;
    --no-deps)         IGNORE_DEPS=1; shift ;;
    --force)           FORCE=1; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --host)            HOST=$2; shift 2 ;;
    --port)            PORT=$2; shift 2 ;;
    --project)         PROJECT_DIR=$2; shift 2 ;;
    --manifest)        MANIFEST=$2; shift 2 ;;
    --state)           STATE_DIR=$2; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[[ $MODE == parallel || $MODE == sequential ]] || die "--mode must be parallel or sequential"
[[ $MAX_PARALLEL =~ ^[0-9]+$ && $MAX_PARALLEL -ge 1 ]] || die "--max-parallel must be a positive integer"

PROJECT_DIR=$(cd "$PROJECT_DIR" 2>/dev/null && pwd) || die "project dir not found"
: "${MANIFEST:=$PROJECT_DIR/tasks/manifest.tsv}"
: "${ARCH_FILE:=$PROJECT_DIR/tasks/ARCHITECTURE.md}"
: "${STATE_DIR:=$PROJECT_DIR/.agents}"
: "${WT_ROOT:=$(dirname "$PROJECT_DIR")/.agent-worktrees/$(basename "$PROJECT_DIR")}"
LOG_DIR="$STATE_DIR/logs"
STATUS_DIR="$STATE_DIR/status"
(( DRY_RUN )) && STATUS_DIR="$STATE_DIR/status-dry"   # a dry run must not mark tasks as done

# ---------- manifest ----------
declare -a ORDER=()
declare -A SLUG=() CAT=() DEPS=() TFILE=() SELECTED_SET=()
declare -a SELECTED=()

trim() { local s=$1; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

load_manifest() {
  [[ -f $MANIFEST ]] || die "manifest not found: $MANIFEST (run build_workspace.py first)"
  local mdir line id slug cat deps file
  mdir=$(cd "$(dirname "$MANIFEST")" && pwd)
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    [[ -z "${line//[[:space:]]/}" ]] && continue
    IFS='|' read -r id slug cat deps file <<<"$line"
    id=$(trim "$id"); slug=$(trim "$slug"); cat=$(trim "$cat")
    deps=$(trim "$deps"); file=$(trim "$file")
    [[ $deps == "-" ]] && deps=""
    deps=${deps//[[:space:]]/}
    [[ -n $id && -n $slug && -n $file ]] || die "bad manifest line: $line"
    [[ $file == /* ]] || file="$mdir/$file"
    [[ -f $file ]] || die "task file missing for $id: $file"
    ORDER+=("$id"); SLUG[$id]=$slug; CAT[$id]=$cat; DEPS[$id]=$deps; TFILE[$id]=$file
  done <"$MANIFEST"
  (( ${#ORDER[@]} )) || die "manifest is empty"
  local d
  for id in "${ORDER[@]}"; do
    IFS=, read -ra _ds <<<"${DEPS[$id]}"
    for d in "${_ds[@]}"; do
      [[ -z $d ]] && continue
      [[ -n ${SLUG[$d]+x} ]] || die "task $id depends on unknown task $d"
    done
  done
  if [[ -n $ONLY ]]; then
    IFS=, read -ra _only <<<"$ONLY"
    for id in "${ORDER[@]}"; do
      for d in "${_only[@]}"; do
        # accept "3" for id "03"
        if [[ $id == "$d" || $((10#$id)) == $((10#$d)) ]]; then SELECTED+=("$id"); fi
      done
    done
  else
    SELECTED=("${ORDER[@]}")
  fi
  (( ${#SELECTED[@]} )) || die "no task selected"
  for id in "${SELECTED[@]}"; do SELECTED_SET[$id]=1; done
}

# ---------- status files ----------
get_status() { local f="$STATUS_DIR/$1"; [[ -f $f ]] && cat "$f" || echo none; }
set_status() { mkdir -p "$STATUS_DIR"; echo "$2" >"$STATUS_DIR/$1"; }

# ---------- server ----------
reachable() {
  local url=$1 hp h p
  hp=${url#*://}; hp=${hp%%/*}
  h=${hp%%:*}; p=${hp##*:}
  if [[ $p == "$hp" ]]; then [[ $url == https://* ]] && p=443 || p=80; fi
  (exec 3<>"/dev/tcp/$h/$p") 2>/dev/null
}

serve_start() {
  mkdir -p "$STATE_DIR"
  if reachable "http://127.0.0.1:$PORT"; then log "server already answering on port $PORT"; return 0; fi
  command -v opencode >/dev/null || die "opencode not found in PATH"
  if [[ $HOST != 127.0.0.1 && $HOST != localhost && -z ${OPENCODE_SERVER_PASSWORD:-} ]]; then
    echo "warning: server exposed on $HOST without OPENCODE_SERVER_PASSWORD — anyone who can reach it can run agents" >&2
  fi
  (cd "$PROJECT_DIR" && nohup opencode serve --hostname "$HOST" --port "$PORT" >"$STATE_DIR/server.log" 2>&1 & echo $! >"$STATE_DIR/server.pid")
  local i
  for i in $(seq 1 40); do
    reachable "http://127.0.0.1:$PORT" && { log "server up on $HOST:$PORT (pid $(cat "$STATE_DIR/server.pid"))"; return 0; }
    sleep 0.5
  done
  die "server did not come up, see $STATE_DIR/server.log"
}

serve_stop() {
  local f="$STATE_DIR/server.pid"
  [[ -f $f ]] || { log "no pid file, nothing to stop"; return 0; }
  kill "$(cat "$f")" 2>/dev/null && log "server stopped" || log "server was not running"
  rm -f "$f"
}

# ---------- git worktrees ----------
LOCKDIR="$STATE_DIR/.git-lock"
with_lock() {
  mkdir -p "$STATE_DIR"
  until mkdir "$LOCKDIR" 2>/dev/null; do sleep 0.2; done
  "$@"; local rc=$?
  rmdir "$LOCKDIR"; return $rc
}

_make_worktree() {
  local slug=$1 wt="$WT_ROOT/$1" branch="agent/$1"
  [[ -d $wt ]] && return 0
  mkdir -p "$WT_ROOT"
  if git -C "$PROJECT_DIR" rev-parse --verify -q "$branch" >/dev/null; then
    git -C "$PROJECT_DIR" worktree add "$wt" "$branch" >/dev/null 2>&1
  else
    git -C "$PROJECT_DIR" worktree add -b "$branch" "$wt" HEAD >/dev/null 2>&1
  fi
}

prepare_worktree() {
  local id=$1 wt="$WT_ROOT/${SLUG[$id]}" d
  with_lock _make_worktree "${SLUG[$id]}" || return 1
  IFS=, read -ra _ds <<<"${DEPS[$id]}"
  for d in "${_ds[@]}"; do
    [[ -z $d ]] && continue
    git -C "$wt" merge --no-edit "agent/${SLUG[$d]}" >/dev/null 2>&1 || {
      git -C "$wt" merge --abort >/dev/null 2>&1
      echo "cannot merge dependency $d into worktree of $id" >&2; return 1; }
  done
  echo "$wt"
}

autocommit() {
  local wt=$1 id=$2
  if [[ -n $(git -C "$wt" status --porcelain 2>/dev/null) ]]; then
    git -C "$wt" add -A && git -C "$wt" commit -q -m "task $id: ${SLUG[$id]}" 2>/dev/null
  fi
}

# ---------- prompt & command ----------
build_prompt() {
  local id=$1
  {
    echo "You are an autonomous coding agent responsible for ONE task (#$id, ${SLUG[$id]}) of a larger application."
    echo "Other agents implement the other tasks, possibly at the same time: stay inside the scope and files of your task,"
    echo "follow the shared architecture and contracts below exactly, and do not refactor unrelated code."
    if (( USE_WORKTREES )); then
      echo "You work in your own git worktree: commit your work when the acceptance criteria are met."
    else
      echo "Do not run git commit: the orchestrator handles version control."
    fi
    echo "Finish by checking each acceptance criterion and summarising what you did and anything left open."
    if [[ -f $ARCH_FILE ]]; then echo; echo "# SHARED ARCHITECTURE"; cat "$ARCH_FILE"; fi
    echo; echo "# YOUR TASK"; cat "${TFILE[$id]}"
  }
}

build_cmd() { # sets global CMD_ARR
  local id=$1 dir=$2
  CMD_ARR=(opencode run)
  [[ -n $SERVER_URL ]] && CMD_ARR+=(--attach "$SERVER_URL")
  [[ -n $MODEL ]] && CMD_ARR+=(--model "$MODEL")
  [[ -n $AGENT ]] && CMD_ARR+=(--agent "$AGENT")
  CMD_ARR+=(--title "task-$id-${SLUG[$id]}" --dir "$dir")
}

run_task() {
  local id=$1 slug=${SLUG[$1]} logf="$LOG_DIR/$1-${SLUG[$1]}.log" dir rc
  mkdir -p "$LOG_DIR"
  set_status "$id" running
  if [[ -n $REMOTE_DIR ]]; then dir=$REMOTE_DIR
  elif (( USE_WORKTREES )); then dir=$(prepare_worktree "$id") || { set_status "$id" failed; return 1; }
  else dir=$PROJECT_DIR; fi
  build_cmd "$id" "$dir"
  if (( DRY_RUN )); then
    printf '[dry-run] task %s:' "$id"; printf ' %q' "${CMD_ARR[@]}"; printf ' "<prompt: architecture + %s>"\n' "${TFILE[$id]}"
    set_status "$id" done; return 0
  fi
  "${CMD_ARR[@]}" "$(build_prompt "$id")" >"$logf" 2>&1
  rc=$?
  (( USE_WORKTREES )) && [[ -z $REMOTE_DIR ]] && autocommit "$dir" "$id"
  if (( rc == 0 )); then set_status "$id" done; else set_status "$id" failed; fi
  return $rc
}

# ---------- scheduler ----------
deps_state() { # ready | wait | blocked
  local id=$1 d st res=ready
  (( IGNORE_DEPS )) && { echo ready; return; }
  IFS=, read -ra _ds <<<"${DEPS[$id]}"
  for d in "${_ds[@]}"; do
    [[ -z $d ]] && continue
    st=$(get_status "$d")
    if [[ $st == done ]]; then continue; fi
    if [[ -z ${SELECTED_SET[$d]+x} || $st == failed || $st == blocked ]]; then echo blocked; return; fi
    res=wait
  done
  echo $res
}

CHILD_PIDS=()
on_interrupt() {
  echo; log "interrupted — stopping agents"
  local p; for p in "${CHILD_PIDS[@]}"; do kill "$p" 2>/dev/null; done
  local id; for id in "${SELECTED[@]}"; do [[ $(get_status "$id") == running ]] && set_status "$id" interrupted; done
  exit 130
}

schedule() {
  local max=$MAX_PARALLEL; [[ $MODE == sequential ]] && max=1
  local -A running=()
  local -a pending=() still=()
  local id rc launched n_fail=0
  for id in "${SELECTED[@]}"; do
    if [[ $(get_status "$id") == done && $FORCE -eq 0 ]]; then log "skip $id ${SLUG[$id]} (already done)"
    else pending+=("$id"); set_status "$id" pending; fi
  done
  trap on_interrupt INT TERM
  log "mode=$MODE max_parallel=$max server=${SERVER_URL:-none} tasks=${#pending[@]}"

  while (( ${#pending[@]} > 0 || ${#running[@]} > 0 )); do
    for id in "${!running[@]}"; do
      if ! kill -0 "${running[$id]}" 2>/dev/null; then
        wait "${running[$id]}"; rc=$?
        if (( rc == 0 )); then log "done    $id ${SLUG[$id]}"; else log "FAILED  $id ${SLUG[$id]} (rc=$rc, log: $LOG_DIR/$id-${SLUG[$id]}.log)"; n_fail=$((n_fail+1)); fi
        unset "running[$id]"
      fi
    done
    launched=0; still=()
    for id in "${pending[@]}"; do
      case $(deps_state "$id") in
        blocked) set_status "$id" blocked; log "BLOCKED $id ${SLUG[$id]} (dependency failed or not selected)"; n_fail=$((n_fail+1)) ;;
        ready)
          if (( ${#running[@]} < max )); then
            log "launch  $id ${SLUG[$id]} [${CAT[$id]}]"
            run_task "$id" & running[$id]=$!; CHILD_PIDS+=($!); launched=1
          else still+=("$id"); fi ;;
        *) still+=("$id") ;;
      esac
    done
    pending=("${still[@]}")
    if (( launched == 0 && ${#running[@]} == 0 && ${#pending[@]} > 0 )); then
      for id in "${pending[@]}"; do set_status "$id" blocked; log "BLOCKED $id (dependency cycle?)"; n_fail=$((n_fail+1)); done
      pending=()
    fi
    (( ${#pending[@]} > 0 || ${#running[@]} > 0 )) && sleep 1
  done
  trap - INT TERM
  show_status
  (( n_fail == 0 )) || { log "$n_fail task(s) failed or blocked"; return 1; }
  log "all tasks done"
  (( USE_WORKTREES )) && log "next: $SELF merge"
  return 0
}

# ---------- commands ----------
show_status() {
  local id
  printf '%-5s %-28s %-14s %-12s %s\n' ID SLUG CATEGORY DEPENDS STATUS
  for id in "${ORDER[@]}"; do
    printf '%-5s %-28s %-14s %-12s %s\n' "$id" "${SLUG[$id]}" "${CAT[$id]}" "${DEPS[$id]:--}" "$(get_status "$id")"
  done
}

cmd_run() {
  command -v opencode >/dev/null || (( DRY_RUN )) || die "opencode not found in PATH"
  if (( USE_WORKTREES )); then
    [[ -n $REMOTE_DIR ]] && die "--worktrees needs the script to run on the host that holds the repo (drop --remote-dir)"
    git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 || die "--worktrees needs a git repository"
    [[ -n $(git -C "$PROJECT_DIR" log -1 --format=%H 2>/dev/null) ]] || die "--worktrees needs at least one commit"
  fi
  if (( ! STANDALONE )); then
    if [[ -z $SERVER_URL ]]; then
      SERVER_URL="http://127.0.0.1:$PORT"
      (( DRY_RUN )) || serve_start
    else
      (( DRY_RUN )) || reachable "$SERVER_URL" || die "server not reachable: $SERVER_URL"
    fi
  else
    SERVER_URL=""
  fi
  [[ -n $REMOTE_DIR && $STANDALONE -eq 1 ]] && die "--remote-dir only makes sense with a server"
  schedule
}

cmd_merge() {
  local id branch
  for id in "${SELECTED[@]}"; do
    branch="agent/${SLUG[$id]}"
    git -C "$PROJECT_DIR" rev-parse --verify -q "$branch" >/dev/null || { log "no branch $branch, skipped"; continue; }
    if git -C "$PROJECT_DIR" merge --no-ff --no-edit "$branch"; then log "merged $branch"
    else die "conflict while merging $branch — resolve it, commit, then re-run 'merge'"; fi
  done
}

cmd_clean() {
  local id wt
  for id in "${ORDER[@]}"; do
    wt="$WT_ROOT/${SLUG[$id]}"
    [[ -d $wt ]] && git -C "$PROJECT_DIR" worktree remove --force "$wt" && log "removed worktree $wt"
    git -C "$PROJECT_DIR" branch -D "agent/${SLUG[$id]}" >/dev/null 2>&1 && log "deleted branch agent/${SLUG[$id]}"
  done
  rm -rf "$STATUS_DIR"
}

case $CMD in
  serve-start)  serve_start ;;
  serve-stop)   serve_stop ;;
  serve-status) reachable "http://127.0.0.1:$PORT" && echo "up (port $PORT)" || { echo "down"; exit 1; } ;;
  run)          load_manifest; cmd_run ;;
  status)       load_manifest; show_status ;;
  logs)         load_manifest
                [[ -n $LOG_ARG ]] || die "usage: $SELF logs <id>"
                tail -n 100 -f "$LOG_DIR/$LOG_ARG-"*.log ;;
  merge)        load_manifest; cmd_merge ;;
  clean)        load_manifest; cmd_clean ;;
  *)            usage; exit 1 ;;
esac
