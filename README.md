# parallel-tickets-cc-plugin

A Claude Code plugin that orchestrates parallel Claude sessions working on a DAG of tickets. Each unblocked ticket gets its own git worktree and a dedicated tmux pane with a Claude Code session; an orchestrator polls the tracker (Linear or GitHub Issues) every 2 minutes and spawns downstream sessions as blockers complete.

## Install

```bash
claude plugin marketplace add https://github.com/runner-yufeng/parallel-tickets-cc-plugin
claude plugin install parallel-tickets@parallel-tickets
```

## Usage

In any Claude Code session:

```
/parallel-tickets
```

The skill will prompt for:

1. **Tracker**: `linear` or `github`
2. **Initiative name** (short slug)
3. **Tickets**: existing IDs or specs to create
4. **Dependency DAG**: `{ "B": ["A"] }` = B depends on A
5. **Base branch** (default: repo default)
6. **Repo path** (default: cwd)

Then it:

1. Creates tickets (if needed) in the chosen tracker
2. Renders per-ticket prompts
3. Creates git worktrees
4. Spawns tmux sessions (one per unblocked ticket) with `claude` running inside
5. Launches an orchestrator that polls the tracker every 2 min and spawns downstream sessions as blockers close/complete

## Prereqs

- `tmux`
- `git` + `gh` CLI (if GitHub tracker)
- `jq`
- `claude` CLI with `--dangerously-skip-permissions` aliased or explicitly passed
- Linear MCP authenticated **or** `LINEAR_API_KEY` env var (if Linear tracker)
- `cron` or `launchd` (orchestrator runs as a periodic job)

## State

State lives at `~/.parallel-tickets-state/<initiative>/`:

- `spec.json` — tickets, deps, base branch, tracker
- `state.json` — `{ "spawned": [...] }`
- `prompts/<TICKET>.txt` — per-worker prompts

## Gotchas

- `claude --tmux=classic` deadlocks without a real TTY. Skill spawns via `tmux new-session -d` — don't call `--tmux=classic` directly.
- Worker sessions pause at brainstorming Q&A — operator must attach to each pane periodically to approve design checkpoints.
- `create-and-babysit-pr` only waits until "ready to merge"; if orchestrator should auto-detect Done, use `babysit-pr-until-merged` in the worker template.
- Sibling workers editing overlapping paths will conflict at merge time. Minimize by making each ticket's scope disjoint.

## License

MIT
