# A run of the flow gate

The real replies of `.claude/hooks/flow_gate.rb` to the hook events of one
feature, [issue #42](issue.md), in a throwaway repo. Regenerate it with
`ruby examples/hook_run.rb > examples/hook-run.md`.

**Session starts:** on `main`

```text
Flow: no flow on branch 'main'. Files can't be changed until the maintainer types 'start feature #<issue>' or 'start fix <name>'. Don't try to start one yourself.
```

**Builder:** edits `app/models/invoice.rb`

```text
DENIED: No changes on main. The maintainer starts a flow by typing 'start feature #<issue>'. If a block names a way forward, take it and note the block in the PR notes. Otherwise stop and tell the maintainer. Never work around a block.
```

**Maintainer types:** `start feature overdue-invoices #42`

```text
Flow started by the maintainer. Flow: feature 'overdue-invoices' for issue #42, branch feature/overdue-invoices. approve spec: not recorded (needed only to write db/migrate/**/*, docs/architecture/**/*). approve draft: not yet. Last review: none yet. If a block names a way forward, take it and note the block in the PR notes. Otherwise stop and tell the maintainer. Never work around a block.
```

**Builder:** writes `db/migrate/20261112_add_due_on_to_invoices.rb`

```text
DENIED: db/migrate/20261112_add_due_on_to_invoices.rb changes stored data or an ADR: run the architecture check against the ADRs in docs/architecture/, put the proposed shape in the issue, and wait for the maintainer to type 'approve spec'. If a block names a way forward, take it and note the block in the PR notes. Otherwise stop and tell the maintainer. Never work around a block.
```

**Builder:** edits `CLAUDE.md`

```text
DENIED: CLAUDE.md can't be changed by agents. If a block names a way forward, take it and note the block in the PR notes. Otherwise stop and tell the maintainer. Never work around a block.
```

**Builder:** edits `app/models/invoice.rb`

```text
(allowed)
```

**Builder:** runs `git commit -m "Overdue scope"`

```text
DENIED: Only the main session commits, after the reviewer returns ready. If a block names a way forward, take it and note the block in the PR notes. Otherwise stop and tell the maintainer. Never work around a block.
```

**Builder:** runs `bin/kamal deploy`

```text
DENIED: kamal isn't allowed for agents. If a block names a way forward, take it and note the block in the PR notes. Otherwise stop and tell the maintainer. Never work around a block.
```

**Reviewer:** edits `app/models/invoice.rb`

```text
DENIED: The reviewer never changes files. If a block names a way forward, take it and note the block in the PR notes. Otherwise stop and tell the maintainer. Never work around a block.
```

**Coordinator:** runs `git commit -m "Overdue scope"`

```text
(allowed)
```

**Coordinator:** runs `git push origin HEAD:main`

```text
DENIED: No pushes to main or master. If a block names a way forward, take it and note the block in the PR notes. Otherwise stop and tell the maintainer. Never work around a block.
```

**Coordinator:** runs `git push -u origin HEAD`

```text
(allowed)
```

**Coordinator:** opens a draft PR (`create_pull_request`, `draft: true`)

```text
(allowed)
```

**Coordinator:** marks the PR ready (`update_pull_request`, `draft: false`)

```text
DENIED: Marking the PR ready needs a ready 'full diff' review that covers the pushed commit: run the reviewer with the Agent tool on the pushed files, then try again. If a block names a way forward, take it and note the block in the PR notes. Otherwise stop and tell the maintainer. Never work around a block.
```

**Reviewer returns:** `Verdict: ready` / `Checked: full diff` on the pushed commit; the coordinator marks the PR ready again

```text
(allowed)
```

**Coordinator:** merges (`merge_pull_request`)

```text
DENIED: Merging and approving are the maintainer's steps; agents never do them. If a block names a way forward, take it and note the block in the PR notes. Otherwise stop and tell the maintainer. Never work around a block.
```

