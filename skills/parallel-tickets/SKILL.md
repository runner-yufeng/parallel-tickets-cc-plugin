---
name: parallel-tickets
description: Orchestrate parallel Claude Code sessions working on a DAG of tickets. Each unblocked ticket gets a dedicated tmux pane with its own git worktree and claude session; an orchestrator polls the tracker (Linear or GitHub Issues) and spawns downstream sessions as blockers complete. Use when the user asks to work multiple tickets in parallel, spawn parallel sessions, or describes a ticket DAG to execute.
---

# Parallel Ticket Orchestrator

Spin up one Claude session per unblocked ticket, each in its own tmux pane + git worktree. An orchestrator auto-spawns downstream sessions as blockers complete.

## When to use

- 3+ tickets that can be parallelized
- At least some have dependencies (ticket DAG)
- User wants isolated sessions/worktrees, not one session doing everything serially

## When NOT to use

- Single ticket (overkill)
- Tickets touch heavily overlapping files (merge conflicts dominate)
- Short (<30 min) tasks where worktree setup overhead exceeds the work

## Prereqs (verify first, don't assume)

- `tmux` installed (`which tmux`)
- `claude` CLI with `--dangerously-skip-permissions` aliased OR explicitly passed
- If tracker=linear: Linear MCP authenticated (`mcp__linear-server__list_teams` works)
- If tracker=github: `gh auth status` clean

## Inputs to collect

Ask the user:

1. **Tracker**: `linear` or `github`
2. **Initiative name** (short slug for state dir + orchestrator session name)
3. **Tickets**: existing IDs/numbers, OR specs to create (title + body + labels for each)
4. **Dependency edges**: `{ "B": ["A"] }` = B depends on A. Validate: no cycles, no unknown IDs.
5. **Base branch** (default: repo default; in this repo's CLAUDE.md it may be `dogfood` not `main`)
6. **Repo path** (default: `git rev-parse --show-toplevel` from cwd)

## Execution

### 1. Create tickets (if needed)

- **Linear**: use `mcp__linear-server__save_issue`, one per ticket. Pass `team`, `title`, `description`, optional `parentId`, `labels`, `priority`. Record the returned `id`/`url`.
- **GitHub**: `gh issue create --title "..." --body-file /tmp/body.md --label "..." --json number,url` (use heredoc for body to preserve formatting).

### 2. Set up state directory

```
~/.parallel-tickets-state/<initiative>/
├── spec.json       # { tracker, base_branch, repo, tickets: {id: {slug, title, deps, url}} }
├── state.json      # { "spawned": [] }
├── prompts/        # one <TICKET>.txt per ticket
├── worker-template.md
└── orchestrator-prompt.md
```

Copy `worker-template.md` and `orchestrator-template.md` from this skill's directory; substitute tracker-specific polling block into orchestrator-prompt.md (see §Tracker blocks).

### 3. Render per-ticket worker prompts

For each ticket, sed-substitute `{TICKET}`, `{URL}` into `worker-template.md`, write to `prompts/<TICKET>.txt`.

### 4. Spawn initial workers (tickets with `deps: []`)

For each, run this block (substitute `REPO`, `SLUG`, `TICKET`, `BASE`, `INIT`):

```bash
git -C "$REPO" fetch origin "$BASE"
git -C "$REPO" worktree add -b "worktree-$SLUG" "$REPO/.claude/worktrees/$SLUG" "origin/$BASE"
tmux new-session -d -s "$SLUG" \
  -c "$REPO/.claude/worktrees/$SLUG" \
  "claude --dangerously-skip-permissions \"\$(cat ~/.parallel-tickets-state/$INIT/prompts/$TICKET.txt)\""
tmux has-session -t "$SLUG" && echo "spawned $TICKET"
```

Critical: **always spawn via `tmux new-session -d`**, never via `claude --tmux=classic` directly — the latter deadlocks without a TTY when invoked from non-interactive contexts.

Append each successfully-spawned ticket to `state.spawned`.

### 5. Launch orchestrator

```bash
tmux new-session -d -s "${INIT}-orch" -c "$REPO" \
  "claude --dangerously-skip-permissions \"\$(cat ~/.parallel-tickets-state/$INIT/orchestrator-prompt.md)\""
```

### 6. Report to user

- Print tmux session list
- Offer to merge into one session: `tmux join-pane -s <slug> -t ${INIT}-orch` for each worker + `tmux select-layout -t ${INIT}-orch tiled`
- Print attach command: `tmux attach -t ${INIT}-orch`
- Print how to kill everything if needed: `tmux kill-server` (nuclear) or per-session

## Tracker blocks (for orchestrator-prompt.md)

### Linear

Check if a dep is Done:
```
Use Linear MCP `mcp__linear-server__get_issue(id=<dep>)`. If issue.state.name != "Done", dep is not ready.
```

Worker status updates (document in worker prompt): use `mcp__linear-server__save_issue(id, state: "In Progress"|"In Review"|"Done")`.

### GitHub

Check if a dep is Done:
```
Run Bash: `gh issue view <dep_num> --json state --jq .state`. If output != "CLOSED", dep is not ready.
```

Workers use labels for intermediate states (`gh issue edit <num> --add-label "status:in-progress"`) and `gh issue close <num>` on merge.

## Gotchas

- `claude --tmux=classic` deadlocks without a real TTY. Always use `tmux new-session -d`.
- Workers pause at `/superpowers:brainstorming` checkpoints awaiting human input — operator must attach periodically.
- `create-and-babysit-pr` only waits until "ready to merge"; use `babysit-pr-until-merged` if the orchestrator must see Done autonomously.
- Sibling workers editing overlapping paths will conflict at merge time. Minimize by giving each ticket a disjoint scope.
- Orchestrator running `/loop` indefinitely costs tokens; auto-terminates after all tickets spawned, but consider setting a hard max via `--max-budget-usd`.

## Files bundled with this skill

- `worker-template.md` — minimal per-worker prompt
- `orchestrator-template.md` — /loop prompt with `{TRACKER_CHECK_BLOCK}` placeholder
