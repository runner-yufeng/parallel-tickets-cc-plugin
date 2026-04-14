/loop

You orchestrate parallel work for initiative `{INITIATIVE}`.

State dir: `~/.parallel-tickets-state/{INITIATIVE}/`
- `spec.json` — tracker, base branch, repo path, tickets { id: { slug, title, deps, url } }
- `state.json` — `{ "spawned": [...] }`
- `prompts/<TICKET>.txt` — per-worker prompts

## Each iteration

1. Read `state.json` and `spec.json`.
2. For every ticket in spec.tickets NOT in state.spawned:
   a. For each dep in `spec.tickets[ticket].deps`, check its status:
      {TRACKER_CHECK_BLOCK}
   b. If ALL deps are Done, spawn the worker:
      ```bash
      REPO={REPO}; INIT={INITIATIVE}; BASE={BASE_BRANCH}
      TICKET=<ticket>; SLUG=<spec.tickets[ticket].slug>
      git -C "$REPO" fetch origin "$BASE"
      git -C "$REPO" worktree add -b "worktree-$SLUG" "$REPO/.claude/worktrees/$SLUG" "origin/$BASE"
      tmux new-session -d -s "$SLUG" \
        -c "$REPO/.claude/worktrees/$SLUG" \
        "claude --dangerously-skip-permissions \"\$(cat ~/.parallel-tickets-state/$INIT/prompts/$TICKET.txt)\""
      tmux has-session -t "$SLUG" && echo "spawned $TICKET" || echo "FAILED $TICKET"
      ```
   c. Only on verified-spawn: append `<ticket>` to `state.spawned` and write `state.json`.
3. If every ticket is in state.spawned: print `"Orchestration complete"` and exit the loop.
4. Otherwise: use ScheduleWakeup — `1500–1800s` if no spawns this iteration, `300–600s` if you just spawned (downstream may unblock soon).

## Guardrails

- NEVER spawn a ticket already in state.spawned.
- Do NOT touch running worker sessions.
- If spawn fails (tmux session didn't start), leave ticket out of state.spawned; retry next iteration. Report the error.
- If state.json or spec.json is malformed, stop and report — do not guess.
- Treat any dep state other than exactly "Done" (Linear) / "CLOSED" (GitHub) as not-ready — including ambiguous states like "In Review", "Canceled", etc.

## First iteration

Do one full pass now. Report:
- Which deps you checked and their statuses
- Which tickets you spawned (or why nothing was spawnable)
- When you'll wake up next
