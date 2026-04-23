---
name: parallel-tickets
description: Orchestrate parallel Claude Code sessions working on a DAG of tickets. Each unblocked ticket gets a dedicated tmux pane with its own git worktree and claude session; a cron-driven bash script polls the tracker (Linear or GitHub Issues) every 2 minutes and spawns downstream sessions as blockers complete. Use when the user asks to work multiple tickets in parallel, spawn parallel sessions, or describes a ticket DAG to execute.
---

# Parallel Ticket Orchestrator

Spin up one Claude session per unblocked ticket, each in its own tmux pane + git worktree. A deterministic bash script (not a Claude session) polls the tracker every 2 min and spawns downstream sessions as blockers complete.

## When to use

- Dependency DAG of 3+ tickets. **The count of initially unblocked tickets doesn't matter** — the orchestrator spawns downstream sessions as blockers complete, so a DAG rooted at a single seed ticket (narrow start, fan-out later) is a valid target. Do not decline the skill on the grounds that "only one ticket is unblocked right now."
- User wants isolated sessions/worktrees + auto-progression through the DAG so the operator doesn't have to manually kick off each next ticket as its blockers land.
- DAG has at least some fan-out (at some point ≥2 tickets run concurrently). If the graph is a pure serial chain with no parallelism ever, the value is only auto-progression, which is still useful but weaker — weigh against the scheduler overhead.

## When NOT to use

- A single ticket with no downstream work (overkill — run `claude` directly in a worktree). This is distinct from "a DAG whose first layer contains a single ticket," which **is** a valid use case.
- Tickets touch heavily overlapping files so that merge conflicts dominate. Split into disjoint vertical slices first, then use this skill on the restructured DAG.
- Short (<30 min) tasks where worktree setup overhead exceeds the work.
- The operator needs to make architectural decisions at every checkpoint anyway. If HITL babysitting is unavoidable across every ticket, the parallelism benefit collapses — run the affected slices interactively and use the skill for the downstream AFK batch.

## Prereqs (verify first, don't assume)

- `tmux`, `git`, `jq`, `curl` installed
- `claude` CLI with `--dangerously-skip-permissions` aliased OR explicitly passed
- `cron` reachable (macOS: may need Full Disk Access for `cron`) OR user prefers `launchd`
- If tracker=linear: `LINEAR_API_KEY` — check in order: `$STATE_DIR/.env`, `~/.zshrc` (grep for `export LINEAR_API_KEY=`), current env. If missing from all, ask the user. Orchestrator has a built-in `.zshrc` fallback so a one-time `export LINEAR_API_KEY=...` in `~/.zshrc` works across every future initiative.
- If tracker=github: `gh auth status` clean

## Inputs to collect

Ask the user:

1. **Tracker**: `linear` or `github`
2. **Initiative name** (short slug; used for state dir, orchestrator session name, cron entry grep pattern)
3. **Tickets**: existing IDs/numbers, OR specs to create (title + body + labels)
4. **Dependency edges**: `{ "B": ["A"] }` = B depends on A. Validate: no cycles, no unknown IDs.
5. **Base branch** (default: repo default; e.g. `dogfood` not `main` in some repos)
6. **Repo path** (default: `git rev-parse --show-toplevel`)
7. **Linear API key** (linear only) — check `~/.zshrc` first (`grep -E '^export LINEAR_API_KEY='`). If present, skip asking; the orchestrator reads it from there automatically. Otherwise ask the user and write to `$STATE_DIR/.env` chmod 600.

## Execution

### 1. Create tickets (if needed)

- **Linear**: use `mcp__linear-server__save_issue`; record `id` + `url`.
- **GitHub**: `gh issue create --title "..." --body-file /tmp/body.md --label "..." --json number,url`.

### 2. Set up state directory

Create `~/.parallel-tickets-state/<INIT>/` with:

```
spec.json          # { tracker, repo, base_branch, tickets: {id: {slug, title, deps, url}} }
state.json         # { "spawned": [] }
prompts/           # populated in step 3
orchestrator.sh    # copied from $CLAUDE_PLUGIN_ROOT/skills/parallel-tickets/orchestrator.sh
orch.log           # touch (cron appends here)
.env               # linear only: LINEAR_API_KEY=... , chmod 600
```

```bash
STATE_DIR="$HOME/.parallel-tickets-state/$INIT"
mkdir -p "$STATE_DIR/prompts"
touch "$STATE_DIR/orch.log"
cp "$CLAUDE_PLUGIN_ROOT/skills/parallel-tickets/orchestrator.sh" "$STATE_DIR/orchestrator.sh"
chmod +x "$STATE_DIR/orchestrator.sh"
# If linear AND key is NOT already in ~/.zshrc:
#   echo "LINEAR_API_KEY=..." > "$STATE_DIR/.env" && chmod 600 "$STATE_DIR/.env"
# (orchestrator.sh falls back to parsing ~/.zshrc when $STATE_DIR/.env is missing.)
```

Write `spec.json` and initial `state.json` (with `"spawned": []`).

### 3. Pre-render ALL per-ticket prompts

Not just the initial unblocked ones — render every ticket upfront so the script doesn't need to render at runtime.

```bash
for TICKET in $(jq -r '.tickets | keys[]' "$STATE_DIR/spec.json"); do
  URL=$(jq -r --arg t "$TICKET" '.tickets[$t].url' "$STATE_DIR/spec.json")
  sed -e "s|{TICKET}|$TICKET|g" -e "s|{URL}|$URL|g" \
    "$CLAUDE_PLUGIN_ROOT/skills/parallel-tickets/worker-template.md" \
    > "$STATE_DIR/prompts/$TICKET.txt"
done
```

### 4. Create orchestrator tmux session (log tail)

The orch session isn't a Claude process — it's a `tail -f` of the script's log, so the user can watch the cron-driven script's output live alongside the worker panes.

```bash
tmux new-session -d -s "${INIT}-orch" "tail -f $STATE_DIR/orch.log"
tmux set-option -t "${INIT}-orch" mouse on
tmux setw -t "${INIT}-orch" pane-border-status top
# Use the @ticket user option (not #{pane_title}) because Claude's TUI
# overwrites pane_title with its activity string.
tmux setw -t "${INIT}-orch" pane-border-format ' #{?pane_active,#[fg=brightmagenta]#[bold]#{@ticket}#[default],#[fg=brightcyan]#{@ticket}#[default]} '
# Magenta borders make orchestration panes visually distinct from vanilla
# Claude Code sessions (which don't use magenta in their TUI).
tmux set-option -t "${INIT}-orch" pane-border-style "fg=brightcyan"
tmux set-option -t "${INIT}-orch" pane-active-border-style "fg=brightmagenta,bold"
tmux set-option -p -t "${INIT}-orch:0.0" @ticket "orchestrator log"
```

### 5. Spawn initial workers (tickets with `deps: []`) and merge into the orch session

```bash
for TICKET in $(jq -r '[.tickets | to_entries[] | select(.value.deps | length == 0) | .key][]' "$STATE_DIR/spec.json"); do
  SLUG=$(jq -r --arg t "$TICKET" '.tickets[$t].slug' "$STATE_DIR/spec.json")
  git -C "$REPO" fetch origin "$BASE" --quiet
  git -C "$REPO" worktree add -b "worktree-$SLUG" "$REPO/.claude/worktrees/$SLUG" "origin/$BASE" --quiet

  tmux new-session -d -s "$SLUG" \
    -c "$REPO/.claude/worktrees/$SLUG" \
    "claude --dangerously-skip-permissions \"\$(cat $STATE_DIR/prompts/$TICKET.txt)\""

  if tmux has-session -t "$SLUG" 2>/dev/null; then
    tmux join-pane -s "$SLUG" -t "${INIT}-orch"
    TITLE=$(jq -r --arg t "$TICKET" '.tickets[$t].title' "$STATE_DIR/spec.json")
    tmux set-option -p -t "${INIT}-orch" @ticket "$TICKET | $TITLE"
    jq --arg t "$TICKET" '.spawned += [$t]' "$STATE_DIR/state.json" > "$STATE_DIR/state.json.tmp" \
      && mv "$STATE_DIR/state.json.tmp" "$STATE_DIR/state.json"
  fi
done
tmux select-layout -t "${INIT}-orch" tiled
```

**Critical:** always spawn via `tmux new-session -d`, never via `claude --tmux=classic` — that flag deadlocks without a real TTY.

### 6. Install periodic runner

**On macOS: use a detached tmux driver session.** Both `cron` and `launchd` on recent macOS run inside TCC sandboxes that deny filesystem access to user directories — every `git fetch` hits `fatal: Unable to read current working directory: Operation not permitted`. A tmux-owned shell runs in the user's session and isn't sandboxed.

**On Linux: cron is fine** (no TCC sandbox).

**macOS (tmux driver)**:

```bash
tmux new-session -d -s "parallel-tickets-driver-${INIT}" \
  "while true; do ${STATE_DIR}/orchestrator.sh ${INIT}; sleep 120; done"
```

The driver is a headless tmux session (never attached to) that re-runs the orchestrator every 120 s. No panes are joined into this session — it's a process host only. The script self-terminates by killing this driver session once all tickets are spawned.

**Tradeoff**: the driver dies when the tmux server exits (reboot, `tmux kill-server`). Restart with the same command above. Cron survives reboot; the driver doesn't.

**Linux (cron)**:

```bash
(crontab -l 2>/dev/null; echo "*/2 * * * * $STATE_DIR/orchestrator.sh $INIT") | crontab -
```

The orchestrator's self-teardown handles both: kills the tmux driver AND removes the cron entry once every ticket is spawned.

### 7. Report to user

- Attach: `tmux attach -t ${INIT}-orch`
- Mouse click/scroll works; `Ctrl+b o` cycles panes; `Ctrl+b d` detaches
- Tail the script directly: `tail -f $STATE_DIR/orch.log`
- Kill everything: `tmux kill-session -t ${INIT}-orch` + remove the cron line (the script keeps all workers alive through the cron; killing the tmux session kills worker panes since they were joined in)
- Re-install the cron entry if you accidentally remove it

## Gotchas

- `claude --tmux=classic` deadlocks without a real TTY. Always use `tmux new-session -d`.
- Workers pause at `/superpowers:brainstorming` checkpoints awaiting human input — operator must attach periodically.
- `create-and-babysit-pr` only waits until "ready to merge"; if operator wants orchestrator to self-advance to Done autonomously, use `babysit-pr-until-merged` in the worker template.
- Sibling workers editing overlapping paths will conflict at merge time. Minimize by giving each ticket a disjoint scope.
- When a worker PR merges, the *worker* session must update the tracker (close GH issue / set Linear state to Done). The script polls but doesn't write.
- The orch tmux session merges worker panes INTO itself via `join-pane`. `tmux kill-session -t <init>-orch` therefore kills all worker panes too. To teardown selectively: `tmux break-pane` first, then kill.
- Cron runs with a minimal env. Don't assume `$HOME` or PATH; the script exports a safe PATH and reads `$HOME` from inheritance — verify with `env` if things break.

## Files bundled

- `worker-template.md` — minimal per-worker prompt (`/superpowers:brainstorming` + ticket URL + orchestrator note)
- `orchestrator.sh` — the cron-driven bash orchestrator. Copied into each initiative's state dir at setup.
