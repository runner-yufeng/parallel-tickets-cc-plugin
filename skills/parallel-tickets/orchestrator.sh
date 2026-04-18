#!/usr/bin/env bash
# parallel-tickets orchestrator — deterministic replacement for a Claude /loop session.
# Invoked by cron or launchd every ~2 min with the initiative name as arg.
#
# Responsibilities:
# - For each ticket in spec.tickets not yet in state.spawned:
#   - Query the tracker (github or linear) for every dep's status
#   - If all deps are Done/Closed, create the worktree + tmux session + join pane into orch session
#   - Mark ticket spawned
# - Self-remove its cron entry once every ticket is spawned
#
# State layout under $HOME/.parallel-tickets-state/<initiative>/:
#   spec.json       { tracker, repo, base_branch, tickets: {id: {slug, title, deps, url}} }
#   state.json      { "spawned": [...] }
#   prompts/        per-ticket pre-rendered prompts
#   orchestrator.sh copy of this script (stable path for cron)
#   .env            optional: LINEAR_API_KEY for linear tracker, chmod 600
#   orch.log        all iterations appended here
#   .lock           flock to prevent overlapping runs

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# macOS cron inherits an unusable cwd (getcwd() returns EPERM under the cron
# sandbox). `git` calls getcwd() during setup even with `-C <path>`, so we
# must cd to a readable directory before any git invocation.
cd "$HOME" 2>/dev/null || cd /

INITIATIVE="${1:-}"
if [[ -z "$INITIATIVE" ]]; then
  echo "usage: $0 <initiative>" >&2
  exit 2
fi

STATE_DIR="$HOME/.parallel-tickets-state/$INITIATIVE"
SPEC="$STATE_DIR/spec.json"
STATE="$STATE_DIR/state.json"
LOG="$STATE_DIR/orch.log"
LOCK_DIR="$STATE_DIR/.lock.d"
ENV_FILE="$STATE_DIR/.env"

# Single-instance lock (mkdir is atomic on every POSIX FS — works on macOS
# where flock isn't installed by default). Bail silently if a prior run is still going.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

# Route all output to the log
exec >> "$LOG" 2>&1

echo "[$(date -u +%FT%TZ)] --- iteration ---"

# Load secrets (LINEAR_API_KEY) if present
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

if [[ ! -f "$SPEC" ]] || [[ ! -f "$STATE" ]]; then
  echo "ERROR: missing $SPEC or $STATE"
  exit 1
fi

TRACKER=$(jq -r '.tracker' "$SPEC")
REPO=$(jq -r '.repo' "$SPEC")
BASE=$(jq -r '.base_branch' "$SPEC")
ORCH_SESSION="${INITIATIVE}-orch"

check_dep_status() {
  local dep="$1"
  case "$TRACKER" in
    github)
      gh issue view "$dep" --json state --jq .state 2>/dev/null
      ;;
    linear)
      curl -s -X POST https://api.linear.app/graphql \
        -H "Authorization: ${LINEAR_API_KEY:-}" \
        -H "Content-Type: application/json" \
        -d "{\"query\":\"query { issue(id: \\\"$dep\\\") { state { name } } }\"}" \
        | jq -r '.data.issue.state.name // empty'
      ;;
  esac
}

dep_is_done() {
  local status="$1"
  case "$TRACKER" in
    github) [[ "$status" == "CLOSED" ]] ;;
    linear) [[ "$status" == "Done" ]] ;;
  esac
}

spawned_this_run=0

for ticket in $(jq -r '.tickets | keys[]' "$SPEC"); do
  if jq -e --arg t "$ticket" '.spawned | index($t)' "$STATE" > /dev/null; then
    continue
  fi

  deps=$(jq -r --arg t "$ticket" '.tickets[$t].deps[]?' "$SPEC")
  all_done=true
  for dep in $deps; do
    status=$(check_dep_status "$dep")
    if ! dep_is_done "$status"; then
      echo "  $ticket blocked by $dep (status=${status:-unknown})"
      all_done=false
      break
    fi
  done

  [[ "$all_done" != "true" ]] && continue

  slug=$(jq -r --arg t "$ticket" '.tickets[$t].slug' "$SPEC")
  worktree="$REPO/.claude/worktrees/$slug"

  if [[ -d "$worktree" ]]; then
    echo "  skip $ticket: worktree $worktree already exists"
    continue
  fi

  echo "  spawning $ticket ($slug)"

  if ! git -C "$REPO" fetch origin "$BASE" --quiet; then
    echo "  ERROR: fetch origin $BASE failed for $ticket"
    continue
  fi

  if ! git -C "$REPO" worktree add -b "worktree-$slug" "$worktree" "origin/$BASE" --quiet; then
    echo "  ERROR: worktree add failed for $ticket"
    continue
  fi

  tmux new-session -d -s "$slug" -c "$worktree" \
    "claude --dangerously-skip-permissions \"\$(cat $STATE_DIR/prompts/$ticket.txt)\""

  if ! tmux has-session -t "$slug" 2>/dev/null; then
    echo "  ERROR: tmux spawn failed for $ticket"
    continue
  fi

  if tmux has-session -t "$ORCH_SESSION" 2>/dev/null; then
    tmux join-pane -s "$slug" -t "$ORCH_SESSION" 2>/dev/null || echo "  warn: join-pane failed"
    # Store ticket label in a pane user option so Claude's TUI can't overwrite it.
    # pane-border-format renders #{@ticket}.
    title=$(jq -r --arg t "$ticket" '.tickets[$t].title' "$SPEC")
    tmux set-option -p -t "$ORCH_SESSION" @ticket "$ticket | $title" 2>/dev/null
    tmux select-layout -t "$ORCH_SESSION" tiled 2>/dev/null
  fi

  jq --arg t "$ticket" '.spawned += [$t]' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  spawned_this_run=$((spawned_this_run + 1))
  echo "  ✓ spawned $ticket"
done

total=$(jq '.tickets | length' "$SPEC")
count=$(jq '.spawned | length' "$STATE")
if [[ "$total" == "$count" ]]; then
  echo "[$(date -u +%FT%TZ)] all $total tickets spawned — removing cron entry"
  (crontab -l 2>/dev/null | grep -v "parallel-tickets-state/$INITIATIVE/orchestrator.sh") | crontab -
fi

echo "[$(date -u +%FT%TZ)] --- end (spawned_this_run=$spawned_this_run) ---"
