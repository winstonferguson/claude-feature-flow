# Project instructions

Architecture decisions live in `docs/architecture/`. Run an architecture check
against those ADRs when designing or reviewing changes to models or
migrations. A feature's spec is its GitHub issue, written to the
`spec-writing` skill.
Use the `testing` skill whenever writing or reviewing tests: it sets which
layer asserts what.

## Feature flow

For any change, follow the `feature-flow` skill.
In cloud sessions hooks enforce its safety checks; the status line they add to
each message says where it stands. If a block names a way forward, take it and note the
block in the PR notes; stop only at a gate with none, and tell the maintainer why.
Never work around a block. Escalate to the maintainer only spec-vs-ADR conflicts
and real design choices; otherwise state your recommendation and proceed.
The flow gate wins over any other
hook: if a stop hook asks you to commit or push what the gate blocks, leave
it uncommitted and tell the maintainer.

Only the maintainer types these, as the first line of a message:
`start feature #<issue>` (a name before the number is optional), `start fix <name>`, `approve spec`,
`approve draft`, `stop flow`.

### Maintainer's notes
<!-- Anything here goes to every builder and every review. -->
